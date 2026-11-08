defmodule Ssm.GrantsTest do
  @moduledoc """
  ADR-0012 phase 2: grants give an SSH user access per customer or host
  group. A grant is expanded into normal `authorization` rows (`grant_id`)
  by a full, idempotent per-host reconcile in the transaction of each
  trigger; a manual row wins; removals mark the host "revocation pending".
  """

  use Ssm.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Ssm.Fixtures

  alias Ssm.Activity.ActivityLog
  alias Ssm.Authorizations.Authorization
  alias Ssm.Diffs.Revocations
  alias Ssm.Grants.{DriftCheck, Expansion, Grant}
  alias Ssm.{Authorizations, Customers, Grants, Groups, Hosts, Repo, Scope, Users}

  @admin %{role: "admin", scope: Scope.global(), actor: "admin"}

  setup do
    {:ok, acme} = Customers.create_customer(%{slug: "acme", name: "Acme"})
    {:ok, beta} = Customers.create_customer(%{slug: "beta", name: "Beta"})
    {:ok, web} = Groups.create_group(%{slug: "web", name: "Web"})
    {:ok, db} = Groups.create_group(%{slug: "db", name: "DB"})
    alice = user_fixture(%{username: "alice"})
    %{acme: acme, beta: beta, web: web, db: db, alice: alice}
  end

  defp operator(customers, groups),
    do: %{role: "operator", scope: Scope.new(customers, groups), actor: "op (oidc:1)"}

  defp host_in(customer, groups \\ []) do
    {:ok, host} = Hosts.update_membership(host_fixture(), %{customer: customer, groups: groups})
    host
  end

  defp grant!(actor \\ @admin, attrs) do
    {:ok, grant} = Grants.create_grant(actor, attrs)
    grant
  end

  defp rows(host_id) do
    Repo.all(
      from a in Authorization,
        where: a.host_id == ^host_id,
        order_by: [a.user_id, a.login],
        select: {a.user_id, a.login, a.grant_id}
    )
  end

  defp audit(action) do
    Repo.all(from l in ActivityLog, where: l.action == ^action, order_by: l.id)
    |> Enum.map(&Map.update!(&1, :meta, fn m -> m && Jason.decode!(m) end))
  end

  describe "expansion" do
    test "a customer grant reaches every host of the customer, now and later", ctx do
      h1 = host_in("acme")
      other = host_in("beta")

      grant =
        grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})

      assert rows(h1.id) == [{ctx.alice.id, "deploy", grant.id}]
      assert rows(other.id) == []

      h2 = host_in("acme")
      assert rows(h2.id) == [{ctx.alice.id, "deploy", grant.id}]
      assert Authorizations.managed_logins(h2.id) == ["deploy"]
    end

    test "a group grant reaches the hosts of the group", ctx do
      h = host_in(nil, ["web"])
      grant = grant!(%{ssh_user_id: ctx.alice.id, group_id: ctx.web.id, login: "app"})
      assert rows(h.id) == [{ctx.alice.id, "app", grant.id}]
    end

    test "moving a host to another customer removes the rows and marks revocation", ctx do
      host = host_in("acme")
      grant = grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})
      refute Revocations.pending?(host.id)

      {:ok, _} = Hosts.update_membership(host, %{customer: "beta"})

      assert rows(host.id) == []
      assert Revocations.pending?(host.id)

      assert [%{host_id: host_id, meta: meta}] = audit("grant_remove")
      assert host_id == host.id
      assert meta["trigger"] == "host_membership"
      assert meta["grant_id"] == grant.id
    end

    test "leaving a group removes the rows of the group grant only", ctx do
      host = host_in("acme", ["web"])
      grant!(%{ssh_user_id: ctx.alice.id, group_id: ctx.web.id, login: "app"})
      cust = grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})

      {:ok, _} = Hosts.update_membership(host, %{groups: []})

      assert rows(host.id) == [{ctx.alice.id, "deploy", cust.id}]
      assert Revocations.pending?(host.id)
    end

    test "a manual row wins and no duplicate is created", ctx do
      host = host_in("acme")
      manual = authorization_fixture(ctx.alice, host, %{login: "deploy", comment: "by hand"})

      grant = grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})

      assert rows(host.id) == [{ctx.alice.id, "deploy", nil}]
      assert Repo.get!(Authorization, manual.id).comment == "by hand"

      # deleting the manual row that had won brings the grant row back
      {:ok, _} = Authorizations.delete_authorization(Repo.get!(Authorization, manual.id))
      assert rows(host.id) == [{ctx.alice.id, "deploy", grant.id}]
      assert [%{meta: %{"trigger" => "authorization_delete"}}] = audit("grant_add")
    end

    test "two grants for the same row share one row and hand it over", ctx do
      host = host_in("acme", ["web"])
      g1 = grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})
      g2 = grant!(%{ssh_user_id: ctx.alice.id, group_id: ctx.web.id, login: "deploy"})

      assert rows(host.id) == [{ctx.alice.id, "deploy", g1.id}]

      {:ok, _} = Grants.delete_grant(@admin, g1)
      assert rows(host.id) == [{ctx.alice.id, "deploy", g2.id}]
      refute Revocations.pending?(host.id)
    end

    test "reconcile is idempotent", ctx do
      host = host_in("acme", ["web"])
      grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})
      before = Repo.all(from a in Authorization, where: a.host_id == ^host.id)

      for _ <- 1..3 do
        assert {:ok, %{added: 0, removed: 0, moved: 0}} =
                 Expansion.reconcile([host.id], %{trigger: "test", actor: "test"})
      end

      assert Repo.all(from a in Authorization, where: a.host_id == ^host.id) == before
      assert Expansion.drift() == []
    end

    test "deleting a grant removes its rows and marks revocation", ctx do
      host = host_in("acme")
      grant = grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})

      assert {:ok, _} = Grants.delete_grant(@admin, grant)

      assert rows(host.id) == []
      assert Revocations.pending?(host.id)
      assert [%{meta: %{"trigger" => "grant_delete"}}] = audit("grant_remove")
      assert [%{actor_username: "admin"}] = audit("grant_delete")
    end

    test "an update through a stale struct cannot overwrite a grant row", ctx do
      host = host_in("acme")
      grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})
      row = Repo.get_by!(Authorization, host_id: host.id)
      stale = %{row | grant_id: nil}

      assert {:error, :grant_row} = Authorizations.update_authorization(stale, %{login: "x"})

      assert {:error, :grant_row} =
               Authorizations.update_authorization(Scope.global(), stale, %{login: "x"})

      assert Repo.get!(Authorization, row.id).login == "deploy"
    end

    test "a grant row is read-only in the web and API paths", ctx do
      host = host_in("acme")
      grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})
      row = Repo.get_by!(Authorization, host_id: host.id)

      assert {:error, :grant_row} = Authorizations.delete_authorization(Scope.global(), row)
      assert {:error, :grant_row} = Authorizations.delete_authorization(row)

      assert {:error, :grant_row} =
               Authorizations.update_authorization(Scope.global(), row, %{login: "x"})

      assert {:error, :grant_row} = Authorizations.update_authorization(row, %{login: "x"})
      assert rows(host.id) != []
    end

    test "a disabled SSH user keeps its grant rows (the sync leaves its keys out)", ctx do
      host = host_in("acme")
      grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})
      {:ok, _} = Users.update_user(ctx.alice, %{enabled: false})
      assert [{_, "deploy", _}] = rows(host.id)
    end
  end

  describe "cascade" do
    test "deleting the SSH user deletes its grants and their rows", ctx do
      host = host_in("acme")
      grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})

      {:ok, _} = Users.delete_user(ctx.alice)

      assert Repo.aggregate(Grant, :count) == 0
      assert rows(host.id) == []
    end

    test "deleting a grant row by row FK cascades its authorization rows", ctx do
      host = host_in("acme")
      grant = grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})
      Repo.delete!(grant)
      assert rows(host.id) == []
    end

    test "deleting a customer or group via the contract deletes its grants", ctx do
      grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.beta.id, login: "deploy"})
      grant!(%{ssh_user_id: ctx.alice.id, group_id: ctx.db.id, login: "deploy"})

      :ok = Customers.delete_customer("beta")
      :ok = Groups.delete_group("db")

      assert Repo.aggregate(Grant, :count) == 0
    end

    test "merging a customer moves its hosts and reconciles them", ctx do
      host = host_in("beta")
      grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.beta.id, login: "old"})
      acme = grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "new"})

      {:ok, %{moved_hosts: 1}} =
        Customers.merge_customer("beta", "acme", %{actor: "mctl:test", job_id: "42"})

      assert rows(host.id) == [{ctx.alice.id, "new", acme.id}]
      assert Revocations.pending?(host.id)

      assert [%{meta: %{"trigger" => "customer_merge", "job_id" => "42"}}] =
               audit("grant_remove")
    end

    test "renaming a customer or group changes nothing", ctx do
      host = host_in("acme", ["web"])
      grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})
      before = rows(host.id)

      {:ok, _} = Customers.update_customer(ctx.acme, %{name: "Acme AG"})
      {:ok, _} = Groups.update_group(ctx.web, %{name: "Webservers"})

      assert rows(host.id) == before
    end

    test "deleting a host takes its grant rows along and logs them", ctx do
      host = host_in("acme")
      grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})

      {:ok, _} = Hosts.delete_host(host)

      assert rows(host.id) == []
      assert [%{meta: %{"trigger" => "host_delete"}}] = audit("grant_remove")
    end
  end

  describe "SSH user removal" do
    test "deleting an SSH user audits its grants and marks the hosts", ctx do
      host = host_in("acme")
      grant = grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})

      {:ok, _} = Users.delete_user(ctx.alice)

      assert Repo.aggregate(Grant, :count) == 0
      assert Revocations.pending?(host.id)
      assert [%{meta: %{"trigger" => "user_delete", "grant_id" => id}}] = audit("grant_remove")
      assert id == grant.id
      assert [%{meta: %{"grant_id" => ^id}}] = audit("grant_delete")
    end

    test "bulk delete and merge drop the grants of deleted users the same way", ctx do
      host = host_in("acme")
      bob = user_fixture(%{username: "bob"})
      grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "a"})
      grant!(%{ssh_user_id: bob.id, customer_id: ctx.acme.id, login: "b"})

      %{deleted: [_]} = Ssm.Users.BulkOps.bulk_delete([ctx.alice])
      {:ok, _} = Ssm.Users.BulkOps.merge_users([bob], %{username: "carol"})

      assert Repo.aggregate(Grant, :count) == 0
      assert length(audit("grant_delete")) == 2
      assert Revocations.pending?(host.id)
    end

    test "offboarding a person deletes its grants, so access does not come back", ctx do
      alice = ctx.alice
      host = host_in("acme")
      grant!(%{ssh_user_id: alice.id, customer_id: ctx.acme.id, login: "deploy"})
      authorization_fixture(alice, host, %{login: "manual"})

      match = %Ssm.People.Match{key: "email:alice@example.com", users: [alice]}
      assert {:ok, [host_id]} = Ssm.People.remove_authorizations(match, nil)
      assert host_id == host.id

      assert Repo.aggregate(Grant, :count) == 0
      assert rows(host.id) == []

      later = host_in("acme")
      assert rows(later.id) == []
      assert [%{meta: %{"trigger" => "person_remove"}}] = audit("grant_remove")
    end
  end

  describe "who may create a grant" do
    test "an admin creates any grant", ctx do
      assert {:ok, %Grant{scope_customer_ids: nil, scope_group_ids: nil}} =
               Grants.create_grant(@admin, %{
                 ssh_user_id: ctx.alice.id,
                 customer_id: ctx.beta.id,
                 login: "deploy"
               })

      assert [%{actor_username: "admin", meta: meta}] = audit("grant_create")
      assert meta["target"] == "customer:beta"
    end

    test "a viewer creates none", ctx do
      viewer = %{role: "viewer", scope: Scope.global(), actor: "v"}

      assert {:error, :forbidden} =
               Grants.create_grant(viewer, %{
                 ssh_user_id: ctx.alice.id,
                 customer_id: ctx.acme.id,
                 login: "deploy"
               })
    end

    test "a scoped operator only targets its scope", ctx do
      op = operator(["acme"], ["*"])

      assert {:error, :out_of_scope} =
               Grants.create_grant(op, %{
                 ssh_user_id: ctx.alice.id,
                 customer_id: ctx.beta.id,
                 login: "deploy"
               })

      assert {:ok, %Grant{}} =
               Grants.create_grant(op, %{
                 ssh_user_id: ctx.alice.id,
                 customer_id: ctx.acme.id,
                 login: "deploy"
               })

      op_web = operator(["*"], ["web"])

      assert {:error, :out_of_scope} =
               Grants.create_grant(op_web, %{
                 ssh_user_id: ctx.alice.id,
                 group_id: ctx.db.id,
                 login: "deploy"
               })
    end

    test "the creator's scope narrows the target, also for future hosts", ctx do
      op = operator(["acme"], ["*"])
      in_scope = host_in("acme", ["web"])
      outside = host_in("beta", ["web"])

      grant = grant!(op, %{ssh_user_id: ctx.alice.id, group_id: ctx.web.id, login: "app"})
      assert grant.scope_customer_ids == [ctx.acme.id]
      assert grant.scope_group_ids == nil

      assert rows(in_scope.id) == [{ctx.alice.id, "app", grant.id}]
      assert rows(outside.id) == []

      later_out = host_in("beta", ["web"])
      later_in = host_in("acme", ["web"])
      assert rows(later_out.id) == []
      assert rows(later_in.id) == [{ctx.alice.id, "app", grant.id}]
    end

    test "a scoped operator sees and deletes only grants inside its scope", ctx do
      op = operator(["acme"], ["*"])
      mine = grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "a"})
      wide = grant!(%{ssh_user_id: ctx.alice.id, group_id: ctx.web.id, login: "b"})
      narrowed = grant!(op, %{ssh_user_id: ctx.alice.id, group_id: ctx.web.id, login: "c"})

      assert Enum.map(Grants.list_grants(op.scope), & &1.id) |> Enum.sort() ==
               Enum.sort([mine.id, narrowed.id])

      assert {:error, :not_found} = Grants.delete_grant(op, wide)
      assert {:ok, _} = Grants.delete_grant(op, narrowed)
      viewer = %{role: "viewer", scope: Scope.global(), actor: "v"}
      assert {:error, :forbidden} = Grants.delete_grant(viewer, mine)
    end

    test "an SSH user with a grant reaching outside the scope is read-only for it", ctx do
      op = operator(["acme"], ["*"])
      host = host_in("acme")
      authorization_fixture(ctx.alice, host, %{login: "manual"})
      assert Users.writable?(op.scope, ctx.alice)

      # a grant on beta has no host yet, but future beta hosts get alice's keys
      grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.beta.id, login: "deploy"})
      refute Users.writable?(op.scope, ctx.alice)
      assert {:error, :out_of_scope} = Users.delete_user(op.scope, ctx.alice)
    end

    test "a scope whose slugs match nothing creates no grant and manages none", ctx do
      ghost = operator(["ghost"], ["*"])

      assert {:error, :out_of_scope} =
               Grants.create_grant(ghost, %{
                 ssh_user_id: ctx.alice.id,
                 group_id: ctx.web.id,
                 login: "x"
               })

      empty = grant!(%{ssh_user_id: ctx.alice.id, group_id: ctx.web.id, login: "y"})
      Repo.update_all(from(g in Grant, where: g.id == ^empty.id), set: [scope_customer_ids: []])
      refute Grants.manageable?(ghost.scope, Repo.get!(Grant, empty.id))
      refute Grants.manageable?(operator(["acme"], ["*"]).scope, Repo.get!(Grant, empty.id))
    end

    test "labels never name customers or groups outside the viewer's scope", ctx do
      wide = operator(["acme", "beta"], ["*"])
      narrow = operator(["acme"], ["*"])
      grant = grant!(wide, %{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "a"})

      assert Grants.limit_labels(Scope.global(), [grant])[grant.id] =~ "Beta"
      refute Grants.limit_labels(narrow.scope, [grant])[grant.id] =~ "Beta"
      assert Grants.limit_labels(narrow.scope, [grant])[grant.id] =~ "1 other"

      group = grant!(%{ssh_user_id: ctx.alice.id, group_id: ctx.db.id, login: "g"})
      assert Grants.labels(Scope.global(), [group.id]) == %{group.id => "group DB"}
      assert Grants.labels(operator(["*"], ["web"]).scope, [group.id]) == %{group.id => "grant"}
    end

    test "validation: one target, login rules, unique per user, target and login", ctx do
      base = %{ssh_user_id: ctx.alice.id, login: "deploy"}

      assert {:error, %Ecto.Changeset{}} = Grants.create_grant(@admin, base)

      assert {:error, %Ecto.Changeset{}} =
               Grants.create_grant(
                 @admin,
                 Map.merge(base, %{customer_id: ctx.acme.id, group_id: ctx.web.id})
               )

      assert {:error, %Ecto.Changeset{}} =
               Grants.create_grant(
                 @admin,
                 %{base | login: "bad\nlogin"} |> Map.put(:customer_id, ctx.acme.id)
               )

      grant!(Map.put(base, :customer_id, ctx.acme.id))

      assert {:error, %Ecto.Changeset{} = cs} =
               Grants.create_grant(@admin, Map.put(base, :customer_id, ctx.acme.id))

      assert cs.errors != []
    end
  end

  describe "revocation pending" do
    setup do
      start_supervised!(Ssm.Ssh.MockClient)
      :ok
    end

    defp stub_sync(host_id) do
      payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})

      Ssm.Ssh.MockClient.set_exec(
        host_id,
        "sh .ssm/script.sh version 2>/dev/null || true",
        %Ssm.Ssh.Result{stdout: payload}
      )

      Ssm.Ssh.MockClient.set_default_exec(%Ssm.Ssh.Result{exit_code: 0})
    end

    test "a successful sync clears the mark, a failed one keeps it", ctx do
      host = host_in("acme")
      grant = grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})
      {:ok, _} = Grants.delete_grant(@admin, grant)
      assert Revocations.pending?(host.id)

      {:ok, _} = Hosts.update_host(host, %{disabled: true})
      assert {:error, _} = Ssm.Diffs.sync_host(Ssm.Ssh.MockClient, host.id)
      assert Revocations.pending?(host.id)

      {:ok, _} = Hosts.update_host(Repo.reload!(host), %{disabled: false})
      stub_sync(host.id)
      assert {:ok, _} = Ssm.Diffs.sync_host(Ssm.Ssh.MockClient, host.id)
      refute Revocations.pending?(host.id)
    end

    test "only the mark a sync saw at its start is cleared" do
      host = host_fixture()
      assert Revocations.seen(host.id) == nil
      :ok = Revocations.clear(host.id, nil)

      :ok = Revocations.mark(host.id, "first")
      seen = Revocations.seen(host.id)
      # a reconcile commits a new removal while the sync runs
      :ok = Revocations.mark(host.id, "second")
      :ok = Revocations.clear(host.id, seen)
      assert Revocations.pending?(host.id)
      assert Map.has_key?(Revocations.pending(Scope.global()), host.id)

      :ok = Revocations.clear(host.id, Revocations.seen(host.id))
      refute Revocations.pending?(host.id)
    end
  end

  describe "drift" do
    test "reports missing and stray grant rows without fixing them", ctx do
      host = host_in("acme")
      grant = grant!(%{ssh_user_id: ctx.alice.id, customer_id: ctx.acme.id, login: "deploy"})
      Repo.delete_all(from a in Authorization, where: a.host_id == ^host.id)

      assert [%{host_id: host_id, missing: [%{grant_id: grant_id}], stray: []}] =
               Expansion.drift()

      assert {host_id, grant_id} == {host.id, grant.id}
      assert rows(host.id) == []

      log = ExUnit.CaptureLog.capture_log(fn -> assert [_] = DriftCheck.run() end)
      assert log =~ "grant drift"
      assert log =~ "host #{host.id}"
      assert rows(host.id) == []
    end
  end
end
