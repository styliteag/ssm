defmodule Ssm.ScopeWriteTxTest do
  @moduledoc """
  The scope checks of the web-user write paths (`Users.writable?/2`, admin-only
  options) run inside the write's IMMEDIATE transaction (`Ssm.Grants.transaction/1`):
  a write committed by someone else while the check waits is seen by the check.

  Real connections outside the sandbox (`Sandbox.unboxed_run/2`): process A holds
  a write transaction that adds an out-of-scope authorization; process B's scoped
  write must wait for it and then refuse.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Ssm.Authorizations.Authorization
  alias Ssm.{Customers, Grants, Hosts, Repo, Scope, Users}
  alias Ssm.Users.BulkOps

  @scope %Scope{customers: ["tx-in"], groups: :all}

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    n = System.unique_integer([:positive])

    data =
      unboxed(fn ->
        {:ok, cin} = Customers.create_customer(%{slug: "tx-in", name: "In #{n}"})
        {:ok, cout} = Customers.create_customer(%{slug: "tx-out", name: "Out #{n}"})
        {:ok, hin} = Hosts.create_host(host_attrs("in", n))
        {:ok, hin} = Hosts.update_membership(hin, %{customer: "tx-in"})
        {:ok, hout} = Hosts.create_host(host_attrs("out", n))
        {:ok, hout} = Hosts.update_membership(hout, %{customer: "tx-out"})
        {:ok, user} = Users.create_user(%{username: "tx-user-#{n}"})

        {:ok, _} =
          Ssm.Authorizations.create_authorization(%{
            user_id: user.id,
            host_id: hin.id,
            login: "deploy"
          })

        %{customers: [cin, cout], hosts: [hin, hout], user: user, hout: hout}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from u in Users.User, where: u.id == ^data.user.id)
        Enum.each(data.hosts, &Repo.delete_all(from h in Hosts.Host, where: h.id == ^&1.id))
        Enum.each(data.customers, &Repo.delete(&1))
        Repo.delete_all(Ssm.Diffs.PendingRevocation)
        Repo.delete_all(Ssm.Activity.ActivityLog)
      end)
    end)

    data
  end

  defp host_attrs(tag, n),
    do: %{name: "tx-#{tag}-#{n}", username: "root", address: "tx-#{tag}-#{n}.test", port: 22}

  # A: in one write transaction, give the user a row outside the scope and
  # hold it until told to commit
  defp hold_out_of_scope_row(ctx) do
    me = self()

    a =
      Task.async(fn ->
        unboxed(fn ->
          Grants.transaction(fn ->
            Repo.insert!(%Authorization{
              user_id: ctx.user.id,
              host_id: ctx.hout.id,
              login: "deploy"
            })

            send(me, :holding)
            receive do: (:commit -> :ok)
          end)
        end)
      end)

    assert_receive :holding, 5000
    a
  end

  defp race(ctx, write) do
    a = hold_out_of_scope_row(ctx)
    b = Task.async(fn -> unboxed(write) end)
    Process.sleep(300)
    send(a.pid, :commit)
    {:ok, _} = Task.await(a, 10_000)
    Task.await(b, 10_000)
  end

  test "Users.update_user re-checks writable? inside its transaction", ctx do
    assert {:error, :out_of_scope} =
             race(ctx, fn -> Users.update_user(@scope, ctx.user, %{comment: "late"}) end)

    assert unboxed(fn -> Users.get_user(ctx.user.id).comment end) in [nil, ""]
  end

  test "BulkOps.bulk_delete re-checks writable? inside its transaction", ctx do
    assert %{deleted: [], failed: [{_, :out_of_scope}]} =
             race(ctx, fn -> BulkOps.bulk_delete(@scope, [ctx.user]) end)

    assert unboxed(fn -> Users.get_user(ctx.user.id) end)
  end
end
