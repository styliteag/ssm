defmodule MctlContract.Tokens.Token do
  @moduledoc """
  A contract token (table `mctl_tokens`). Only the SHA-256 of the secret
  is stored; `prefix` (first characters) identifies it in lists. `scopes`
  is a comma separated string (portable across databases).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias MctlContract.TokenStore

  schema "mctl_tokens" do
    field :name, :string
    field :prefix, :string
    field :secret_hash, :string, redact: true
    field :scopes, :string
    field :binding, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :last_used_ip, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Scopes as a list."
  @spec scope_list(t()) :: [String.t()]
  def scope_list(%__MODULE__{scopes: scopes}), do: String.split(scopes || "", ",", trim: true)

  @doc "Changeset of a new or rotated token; scopes come as a list."
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:name, :prefix, :secret_hash, :binding, :expires_at, :revoked_at])
    |> put_scopes(attrs)
    |> validate_required([:name, :prefix, :secret_hash, :scopes])
    |> validate_length(:name, max: 100)
    |> unique_constraint(:name)
    |> unique_constraint(:secret_hash)
  end

  defp put_scopes(cs, attrs) do
    case Map.get(attrs, :scopes) do
      nil ->
        cs

      scopes when is_list(scopes) ->
        unknown = Enum.reject(scopes, &(&1 in TokenStore.scopes()))

        cond do
          scopes == [] -> add_error(cs, :scopes, "choose at least one scope")
          unknown != [] -> add_error(cs, :scopes, "unknown scope #{Enum.join(unknown, ", ")}")
          true -> put_change(cs, :scopes, scopes |> Enum.uniq() |> Enum.join(","))
        end
    end
  end

  @doc "`:active`, `:revoked` or `:expired` at `now`."
  def status(%__MODULE__{revoked_at: %DateTime{}}, _now), do: :revoked

  def status(%__MODULE__{expires_at: %DateTime{} = at}, now),
    do: if(DateTime.compare(at, now) == :gt, do: :active, else: :expired)

  def status(%__MODULE__{}, _now), do: :active
end
