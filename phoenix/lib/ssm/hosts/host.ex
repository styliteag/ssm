defmodule Ssm.Hosts.Host do
  @moduledoc """
  A managed SSH host. Table name is singular (`host`) — Diesel parity kept
  through the python stack and adopted unchanged here.

  `disabled` blocks every SSH operation (non-negotiable rule: each SSH code
  path checks it first). `jump_via` points at another host used as a jump
  host; chains are allowed (jump host may itself have a jump host), loops
  and chains longer than `Ssm.Ssh.Target.max_hops/0` are refused by
  `Ssm.Hosts.create_host/1` / `update_host/2`.

  Host-key pinning (ADR-0008): `key_fingerprint` is the pin every connect is
  verified against (`<type> SHA256:<base64>`, or a bare legacy `SHA256:…`);
  operators may pre-seed it. `host_key` is the full public key, set only by
  `Ssm.Hosts.HostKeys` from a probe (`key_changeset/2`), never cast from
  user input.

  mctl contract v1: a host belongs to at most one customer and any number of
  groups (`host_groups`), assigned only through `Ssm.Hosts.update_membership/2`.

  `machine_id` is the identity-claims-v1 HMAC of the machine's raw id, set
  only by `Ssm.Hosts.MachineId` (`machine_id_changeset/2`), never cast from
  user input.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Ssm.ControlChars
  alias Ssm.Hosts.SshFields
  alias Ssm.Ssh.HostKey

  schema "host" do
    field :name, :string
    field :username, :string
    field :address, :string
    field :port, :integer
    field :key_fingerprint, :string
    field :host_key, :string
    field :host_key_observed_at, :utc_datetime
    field :machine_id, :string
    field :disabled, :boolean, default: false
    field :comment, :string

    belongs_to :jump_host, __MODULE__, foreign_key: :jump_via
    belongs_to :customer, Ssm.Customers.Customer

    many_to_many :groups, Ssm.Groups.Group,
      join_through: "host_groups",
      on_replace: :delete

    has_many :authorizations, Ssm.Authorizations.Authorization, foreign_key: :host_id

    timestamps(type: :utc_datetime)
  end

  def changeset(host, attrs) do
    host
    |> cast(attrs, [
      :name,
      :username,
      :address,
      :port,
      :key_fingerprint,
      :jump_via,
      :disabled,
      :comment
    ])
    |> validate_required([:name, :username, :address, :port])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> validate_length(:comment, max: 1024)
    |> ControlChars.validate([:name, :username, :comment])
    # Both reach the local ssh command line (jump chains): no option-like or
    # separator characters (see Ssm.Hosts.SshFields).
    |> validate_change(:username, &ssh_field(&1, &2, SshFields.valid_username?(&2)))
    |> validate_change(:address, &ssh_field(&1, &2, SshFields.valid_address?(&2)))
    # ecto_sqlite3 derives the constraint name as <table>_<cols>_index from
    # SQLite's error text (the CONSTRAINT name is not reported), so we rely on
    # Ecto's default naming rather than the DDL constraint names.
    |> unique_constraint(:name)
    |> unique_constraint([:address, :port])
    |> foreign_key_constraint(:jump_via)
    |> normalize_fingerprint()
    |> drop_stale_host_key()
  end

  defp ssh_field(_field, _value, true), do: []

  defp ssh_field(:username, _value, false),
    do: [username: "must be a login name (letters, digits, . _ -; not starting with -)"]

  defp ssh_field(:address, _value, false),
    do: [address: "must be a hostname or an IP address"]

  @doc "Store a probed host key (both columns); programmatic only."
  def key_changeset(host, %{public_key: public_key, fingerprint: fingerprint}) do
    change(host,
      host_key: public_key,
      key_fingerprint: fingerprint,
      host_key_observed_at: DateTime.utc_now(:second)
    )
  end

  @doc "Store a learned machine-id HMAC; programmatic only."
  def machine_id_changeset(host, machine_id) when is_binary(machine_id),
    do: change(host, machine_id: machine_id)

  defp normalize_fingerprint(changeset) do
    case fetch_change(changeset, :key_fingerprint) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "" do
          put_change(changeset, :key_fingerprint, nil)
        else
          case HostKey.normalize_fingerprint(value) do
            {:ok, normalized} ->
              put_change(changeset, :key_fingerprint, normalized)

            {:error, _} ->
              add_error(
                changeset,
                :key_fingerprint,
                "must be an SSH SHA256 fingerprint (e.g. ssh-ed25519 SHA256:...)"
              )
          end
        end

      _ ->
        changeset
    end
  end

  # A pin changed by hand invalidates the stored public key unless it still
  # belongs to the new fingerprint.
  defp drop_stale_host_key(changeset) do
    with {:ok, pinned} <- fetch_change(changeset, :key_fingerprint),
         key when is_binary(key) <- get_field(changeset, :host_key),
         {:ok, fingerprint} <- HostKey.fingerprint(key),
         true <- HostKey.matches?(pinned, fingerprint) do
      changeset
    else
      :error -> changeset
      _ -> change(changeset, host_key: nil, host_key_observed_at: nil)
    end
  end
end
