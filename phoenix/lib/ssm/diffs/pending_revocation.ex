defmodule Ssm.Diffs.PendingRevocation do
  @moduledoc """
  A host whose access was reduced (a reconcile removed `authorization`
  rows) and that no successful sync has reached since (table
  `pending_revocations`, one row per host, deleted with the host).
  See `Ssm.Diffs.Revocations`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "pending_revocations" do
    belongs_to :host, Ssm.Hosts.Host, primary_key: true
    field :reason, :string
    field :inserted_at, :utc_datetime_usec
  end
end
