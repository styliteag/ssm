defmodule MctlContract.Idempotency.Record do
  @moduledoc "A stored `Idempotency-Key` and its response (table `mctl_idempotency`)."
  use Ecto.Schema

  schema "mctl_idempotency" do
    field :token_id, :string
    field :key, :string
    field :request_hash, :string
    # nil while the first request still runs
    field :status, :integer
    field :response, :string
    field :inserted_at, :utc_datetime
  end
end
