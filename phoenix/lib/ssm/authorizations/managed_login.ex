defmodule Ssm.Authorizations.ManagedLogin do
  @moduledoc """
  A remote login on a host that ssm manages: it held a grant at some point
  (table `managed_logins`, unique per host and login, deleted with the
  host). Rows are written whenever a grant is created or moved and are never
  removed by ssm, so a sync keeps rewriting the file of a login whose last
  grant is gone (then empty) — revocation reaches the host.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "managed_logins" do
    field :login, :string
    field :inserted_at, :utc_datetime

    belongs_to :host, Ssm.Hosts.Host
  end
end
