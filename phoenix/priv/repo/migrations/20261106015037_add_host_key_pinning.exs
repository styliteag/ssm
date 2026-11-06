defmodule Ssm.Repo.Migrations.AddHostKeyPinning do
  @moduledoc """
  ADR-0008: `host.host_key` holds the full public host key (`<type>
  <base64>`) next to the existing `key_fingerprint`. OpenSSH needs the full
  key to verify jump hops; Erlang verifies against the fingerprint.
  `host_key_observed_at` records when ssm last saw that key itself (the
  mctl `identity.observed_at`).

  Additive and nullable, so it works on fresh and on adopted Diesel-/
  Alembic-era databases alike. Existing `key_fingerprint` values (bare
  `SHA256:…` from the Rust era) stay and are honoured as pins.
  """

  use Ecto.Migration

  def change do
    alter table(:host) do
      add :host_key, :text
      add :host_key_observed_at, :utc_datetime
    end
  end
end
