defmodule Ssm.Repo.Migrations.AddMctlContractTables do
  @moduledoc """
  Tables of the shared `mctl_contract` library (contract v1 §6):
  `mctl_tokens` (`ssm_` service tokens, SHA-256 only), `mctl_jobs`
  (`POST /hosts` jobs) and `mctl_idempotency`. New tables only, so fresh and
  adopted Diesel-/Alembic-era databases behave the same; `down` drops them.
  """

  use Ecto.Migration

  def up, do: MctlContract.Migrations.up(version: 1)
  def down, do: MctlContract.Migrations.down(version: 1)
end
