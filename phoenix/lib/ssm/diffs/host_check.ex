defmodule Ssm.Diffs.HostCheck do
  @moduledoc """
  The persisted result of the last key check of a host (table
  `host_checks`, one row per host, deleted with the host).

    * `state` – `"synced"`, `"drift"` or `"error"`
    * `logins` – how many logins were compared
    * `drift` – per user and login, `%{"user" => name | nil, "login" => …,
      "missing" => [label], "extra" => [label]}`; a label is key type,
      SHA256 fingerprint and comment, never key material (`nil` user: a key
      no ssm user owns)
    * `error_code` / `error` – a fixed, address-free sentence
      (`Ssm.Ssh.ErrorCode`), set for `"error"`
    * `checked_at` – when the check ran; `changed_at` – when the result
      last differed from the one before
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:host_id, :id, autogenerate: false}
  schema "host_checks" do
    field :state, :string
    field :logins, :integer, default: 0
    field :drift, Ssm.Diffs.DriftType, default: []
    field :error_code, :string
    field :error, :string
    field :checked_at, :utc_datetime
    field :changed_at, :utc_datetime
  end

  @states ~w(synced drift error)

  @doc "The valid states."
  def states, do: @states
end
