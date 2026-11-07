defmodule Ssm.Repo.Migrations.AddOperatorVerifiedEmail do
  @moduledoc """
  Offboarding by e-mail (mctl `people`, US-ADM-09) must not trust the
  `email` claim: the IdP user can change it at every login. `email_verified`
  is the claim of the last login; `verified_email` is the e-mail of the
  first login that carried `email_verified: true` and never changes after
  that – only it is used to match SSH users and keys to the operator.

  `operators` was created by 20261106120000, after the baseline, so fresh
  and adopted Diesel-/Alembic-era databases add the columns alike.
  """

  use Ecto.Migration

  def change do
    alter table(:operators) do
      add :email_verified, :boolean, null: false, default: false
      add :verified_email, :text
    end

    create index(:operators, [:verified_email])
  end
end
