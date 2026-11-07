defmodule MctlContract.Jobs.Job do
  @moduledoc """
  A long-running contract job (table `mctl_jobs`). `result` and `error`
  are JSON text (portable); `MctlContract.Jobs.Ecto.to_map/1` decodes them.
  """
  use Ecto.Schema

  schema "mctl_jobs" do
    field :kind, :string
    field :state, :string, default: "queued"
    field :host_id, :string
    field :progress, :string
    field :result, :string
    field :error, :string
    field :inserted_at, :utc_datetime
    field :finished_at, :utc_datetime
  end

  @type t :: %__MODULE__{}
end
