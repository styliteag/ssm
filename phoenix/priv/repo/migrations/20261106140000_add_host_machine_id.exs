defmodule Ssm.Repo.Migrations.AddHostMachineId do
  @moduledoc """
  identity-claims-v1 §1: `host.machine_id` holds the HMAC-SHA256 derivative
  of the machine's raw id (`/etc/machine-id`, FreeBSD `kern.hostuuid`),
  read over SSH. Only the HMAC is stored, never the raw id.

  Additive and nullable (NULL = not learned yet), so it works on fresh and
  on adopted Diesel-/Alembic-era databases alike.
  """

  use Ecto.Migration

  def change do
    alter table(:host) do
      add :machine_id, :string
    end
  end
end
