defmodule Ssm.Diffs.RevocationMarksTest do
  @moduledoc """
  ADR-0012 §6 state machine (`Ssm.Diffs.Revocations`): every operation that
  takes access away marks each affected host "revocation pending", inside
  the domain function, so no caller (LiveView, `/api/v2`, mctl) can skip
  it. One row per access-reducing operation; a new one belongs here.

  Fixture: alice holds a manual row on `h1` and, through a grant on
  customer acme, a grant row on `hg`; bob holds a manual row on `h2`.
  """

  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Diffs.{PendingRevocation, Revocations}
  alias Ssm.Users.BulkOps
  alias Ssm.{Authorizations, Customers, Grants, Hosts, People, Repo, Scope, Users}

  @admin %{role: "admin", scope: Scope.global(), actor: "admin"}

  setup do
    {:ok, acme} = Customers.create_customer(%{slug: "acme", name: "Acme"})
    h1 = host_fixture()
    h2 = host_fixture()
    h3 = host_fixture()
    {:ok, hg} = Hosts.update_membership(host_fixture(), %{customer: "acme"})

    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    alice_key = key_fixture(alice)
    alice_key2 = key_fixture(alice)
    bob_key = key_fixture(bob)

    manual = authorization_fixture(alice, h1, %{login: "deploy"})
    authorization_fixture(bob, h2, %{login: "deploy"})

    {:ok, grant} =
      Grants.create_grant(@admin, %{ssh_user_id: alice.id, customer_id: acme.id, login: "deploy"})

    Repo.delete_all(PendingRevocation)

    %{
      h1: h1,
      h2: h2,
      h3: h3,
      hg: hg,
      alice: alice,
      bob: bob,
      alice_key: alice_key,
      alice_key2: alice_key2,
      bob_key: bob_key,
      manual: manual,
      grant: grant
    }
  end

  # {operation, hosts that must be marked, hosts that must stay unmarked}
  @cases [
    {"manual authorization deleted", [:h1], [:h2, :hg]},
    {"manual authorization moved to another host", [:h1], [:h2, :hg]},
    {"manual authorization moved to another host (web, scoped)", [:h1], [:h2, :hg]},
    {"manual authorization moved to another login", [:h1], [:h2, :hg]},
    {"manual authorization moved to another SSH user", [:h1], [:h2, :hg]},
    {"manual authorization options restricted", [:h1], [:h2, :hg]},
    {"manual authorization restriction value changed", [:h1], [:h2, :hg]},
    {"manual authorization permissive option removed", [:h1], [:h2, :hg]},
    {"SSH user disabled", [:h1, :hg], [:h2]},
    {"SSH user disabled (web, scoped)", [:h1, :hg], [:h2]},
    {"SSH user deleted", [:h1, :hg], [:h2]},
    {"SSH user deleted (bulk)", [:h1, :hg], [:h2]},
    {"SSH users merged", [:h1, :hg], []},
    {"SSH user split", [:hg], [:h2]},
    {"key deleted", [:h1, :hg], [:h2]},
    {"key moved to another SSH user", [:h1, :hg], []},
    {"grant deleted", [:hg], [:h1, :h2]},
    {"host left the grant's customer", [:hg], [:h1, :h2]},
    {"person removed (offboarding)", [:h1, :hg], [:h2]},
    {"person's shared key deleted (offboarding)", [:h2], [:h1, :hg]}
  ]

  for {op, marked, unmarked} <- @cases do
    test "#{op} marks the affected hosts", ctx do
      assert Revocations.pending(Scope.global()) == %{}

      run(unquote(op), ctx)

      for host <- unquote(marked) do
        assert Revocations.pending?(ctx[host].id), "#{host} not marked"
      end

      for host <- unquote(unmarked) do
        refute Revocations.pending?(ctx[host].id), "#{host} marked"
      end
    end
  end

  test "a change that keeps access marks nothing", ctx do
    {:ok, _} = Authorizations.update_authorization(ctx.manual, %{comment: "x"})
    {:ok, _} = Users.update_user(ctx.alice, %{comment: "x"})
    {:ok, _} = Users.update_key(ctx.alice_key, %{name: "renamed"})
    {:ok, _} = Users.update_user(ctx.bob, %{enabled: false})
    Repo.delete_all(PendingRevocation)
    {:ok, _} = Users.update_user(ctx.bob, %{enabled: true})
    # options that only widen access (a restriction dropped) remove nothing
    {:ok, auth} = Authorizations.update_authorization(ctx.manual, %{options: "no-pty"})
    Repo.delete_all(PendingRevocation)
    {:ok, auth} = Authorizations.update_authorization(auth, %{options: "agent-forwarding"})
    {:ok, _} = Authorizations.update_authorization(auth, %{options: ~s(agent-forwarding,pty)})

    assert Revocations.pending(Scope.global()) == %{}
  end

  defp run("manual authorization deleted", ctx),
    do: {:ok, _} = Authorizations.delete_authorization(ctx.manual)

  defp run("manual authorization moved to another host", ctx),
    do: {:ok, _} = Authorizations.update_authorization(ctx.manual, %{host_id: ctx.h3.id})

  defp run("manual authorization moved to another host (web, scoped)", ctx) do
    {:ok, _} =
      Authorizations.update_authorization(Scope.global(), ctx.manual, %{host_id: ctx.h3.id},
        role: "admin"
      )
  end

  defp run("manual authorization moved to another login", ctx),
    do: {:ok, _} = Authorizations.update_authorization(ctx.manual, %{login: "other"})

  defp run("manual authorization moved to another SSH user", ctx),
    do: {:ok, _} = Authorizations.update_authorization(ctx.manual, %{user_id: ctx.bob.id})

  defp run("manual authorization options restricted", ctx),
    do: {:ok, _} = Authorizations.update_authorization(ctx.manual, %{options: "no-pty"})

  defp run("manual authorization restriction value changed", ctx) do
    {:ok, auth} =
      Authorizations.update_authorization(ctx.manual, %{options: ~s(from="10.0.0.0/8")})

    Repo.delete_all(PendingRevocation)
    {:ok, _} = Authorizations.update_authorization(auth, %{options: ~s(from="10.0.0.1")})
  end

  defp run("manual authorization permissive option removed", ctx) do
    {:ok, auth} =
      Authorizations.update_authorization(ctx.manual, %{options: "agent-forwarding,no-pty"})

    Repo.delete_all(PendingRevocation)
    {:ok, _} = Authorizations.update_authorization(auth, %{options: "no-pty"})
  end

  defp run("SSH user disabled", ctx),
    do: {:ok, _} = Users.update_user(ctx.alice, %{enabled: false})

  defp run("SSH user disabled (web, scoped)", ctx),
    do: {:ok, _} = Users.update_user(Scope.global(), ctx.alice, %{enabled: false})

  defp run("SSH user deleted", ctx), do: {:ok, _} = Users.delete_user(ctx.alice)

  defp run("SSH user deleted (bulk)", ctx),
    do: %{failed: []} = BulkOps.bulk_delete([ctx.alice])

  defp run("SSH users merged", ctx), do: {:ok, _} = BulkOps.merge_users([ctx.alice], ctx.bob)

  defp run("SSH user split", ctx),
    do: {:ok, _} = BulkOps.split_user(ctx.alice, "alice2", [ctx.alice_key2.id])

  defp run("key deleted", ctx), do: {:ok, _} = Users.delete_key(ctx.alice_key)

  defp run("key moved to another SSH user", ctx),
    do: {:ok, _} = Users.update_key(ctx.alice_key, %{user_id: ctx.bob.id})

  defp run("grant deleted", ctx), do: {:ok, _} = Grants.delete_grant(@admin, ctx.grant)

  defp run("host left the grant's customer", ctx),
    do: {:ok, _} = Hosts.update_membership(ctx.hg, %{customer: nil})

  defp run("person removed (offboarding)", ctx) do
    match = %People.Match{key: "alice", users: [ctx.alice], keys: [ctx.alice_key]}
    {:ok, _} = People.remove_authorizations(match, nil)
  end

  defp run("person's shared key deleted (offboarding)", ctx),
    do: {_, _} = People.delete_keys([ctx.bob_key.id])
end
