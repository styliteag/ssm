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

  @doc """
  The kind of a failed check, for filtering (`Ssm.Ssh.ErrorCode` codes):
  `:auth` (the host refused ssm's key), `:unreachable` (refused, timed out,
  no route), `:dns`, `:other`; `nil` for a check that did not fail.
  """
  @spec kind(t() | nil) :: :auth | :unreachable | :dns | :other | nil
  def kind(%__MODULE__{state: "error", error_code: code}), do: code_kind(code)
  def kind(_check), do: nil

  defp code_kind("auth_failed"), do: :auth
  defp code_kind(code) when code in ~w(unreachable timeout connect_refused), do: :unreachable
  defp code_kind("dns_error"), do: :dns
  defp code_kind(_code), do: :other
end
