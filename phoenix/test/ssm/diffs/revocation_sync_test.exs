defmodule Ssm.Diffs.RevocationSyncTest do
  @moduledoc """
  ADR-0012 §6: with `SSM_REVOCATION_SYNC=on`, every revoking change starts a
  removal-only sync per affected host: it only drops lines the database no
  longer authorizes, never adds one, follows the readonly/unsafe/own-key
  rules, is audited and clears "revocation pending" only after full
  success. Off (default): nothing is written.
  """

  use Ssm.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Ssm.Fixtures

  alias Ssm.Activity.ActivityLog
  alias Ssm.Diffs.{RevocationSync, Revocations}
  alias Ssm.Ssh.{MockClient, Result}
  alias Ssm.{Authorizations, Customers, Grants, Hosts, Repo, Scope}

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"
  @admin %{role: "admin", scope: Scope.global(), actor: "admin"}

  setup do
    start_supervised!(MockClient)
    previous = Application.get_env(:ssm, :revocation_sync)
    on_exit(fn -> Application.put_env(:ssm, :revocation_sync, previous) end)
    Application.put_env(:ssm, :revocation_sync, "on")
    Application.put_env(:ssm, :revocation_sync_runner, :inline)
    on_exit(fn -> Application.delete_env(:ssm, :revocation_sync_runner) end)

    {:ok, acme} = Customers.create_customer(%{slug: "acme", name: "Acme"})
    {:ok, _} = Customers.create_customer(%{slug: "beta", name: "Beta"})
    {:ok, host} = Hosts.update_membership(host_fixture(%{username: "admin"}), %{customer: "acme"})
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    key_fixture(alice, %{key_type: "ssh-ed25519", key_base64: "ALICE"})
    key_fixture(bob, %{key_type: "ssh-ed25519", key_base64: "BOB"})
    key_fixture(bob, %{key_type: "ssh-ed25519", key_base64: "BOBNEW"})
    %{acme: acme, host: host, alice: alice, bob: bob}
  end

  defp stub_host(host_id, keyfile, extra \\ %{}) do
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host_id, @version_probe, %Result{stdout: payload})

    entry =
      Map.merge(
        %{login: "deploy", has_pragma: true, readonly_condition: nil, keyfile: keyfile},
        extra
      )

    MockClient.set_exec(host_id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
      stdout: Jason.encode!([entry])
    })

    MockClient.set_default_exec(%Result{exit_code: 0})
  end

  defp writes(host_id) do
    for {^host_id, cmd, input} <- MockClient.calls().exec_inputs,
        String.contains?(cmd, "set_authorized_keyfile"),
        do: {cmd, input}
  end

  defp grant!(ctx, user) do
    {:ok, grant} =
      Grants.create_grant(@admin, %{
        ssh_user_id: user.id,
        customer_id: ctx.acme.id,
        login: "deploy"
      })

    grant
  end

  test "removes only revoked lines, keeps host lines verbatim, adds nothing", ctx do
    alice_grant = grant!(ctx, ctx.alice)
    # bob keeps a manual row; his second key BOBNEW is not on the host
    authorization_fixture(ctx.bob, ctx.host, %{login: "deploy"})

    stub_host(
      ctx.host.id,
      ~s(ssh-ed25519 ALICE alice@laptop\nno-pty,from="10.0.0.0/8" ssh-ed25519 BOB bob\n)
    )

    {:ok, _} = Grants.delete_grant(@admin, alice_grant)

    assert [{cmd, content}] = writes(ctx.host.id)
    assert cmd =~ "set_authorized_keyfile deploy"
    assert content == ~s(no-pty,from="10.0.0.0/8" ssh-ed25519 BOB bob\n)
    refute content =~ "BOBNEW"
    refute Revocations.pending?(ctx.host.id)

    [entry] = Repo.all(from l in ActivityLog, where: l.action == "sync")
    assert entry.actor_username == "ssm (revocation sync)"
    assert Jason.decode!(entry.meta)["mode"] == "removal_only"
  end

  test "nothing to remove: no write, the mark clears", ctx do
    grant = grant!(ctx, ctx.alice)
    stub_host(ctx.host.id, "")

    {:ok, _} = Grants.delete_grant(@admin, grant)

    assert writes(ctx.host.id) == []
    refute Revocations.pending?(ctx.host.id)
  end

  test "a disabled host is not touched and stays pending", ctx do
    grant = grant!(ctx, ctx.alice)
    {:ok, _} = Hosts.update_host(ctx.host, %{disabled: true})
    stub_host(ctx.host.id, "ssh-ed25519 ALICE alice\n")

    {:ok, _} = Grants.delete_grant(@admin, grant)

    assert MockClient.calls().exec_inputs == []
    assert Revocations.pending?(ctx.host.id)
    assert [_] = Repo.all(from l in ActivityLog, where: l.action == "sync_failed")
  end

  test "a root-owned user_readonly skips the login and stays pending", ctx do
    grant = grant!(ctx, ctx.alice)

    stub_host(ctx.host.id, "ssh-ed25519 ALICE alice\n", %{
      readonly_condition: "user_readonly (root-owned)",
      readonly_scope: "user"
    })

    {:ok, _} = Grants.delete_grant(@admin, grant)

    assert writes(ctx.host.id) == []
    assert Revocations.pending?(ctx.host.id)
  end

  test "an unread (linked) authorized_keys is not written and stays pending", ctx do
    grant = grant!(ctx, ctx.alice)
    stub_host(ctx.host.id, "", %{unsafe: "symlink"})

    {:ok, _} = Grants.delete_grant(@admin, grant)

    assert writes(ctx.host.id) == []
    assert Revocations.pending?(ctx.host.id)
  end

  test "deleting a manual row marks the host and triggers the sync", ctx do
    auth = authorization_fixture(ctx.alice, ctx.host, %{login: "deploy"})
    stub_host(ctx.host.id, "ssh-ed25519 ALICE alice\n")

    {:ok, _} = Authorizations.delete_authorization(auth)

    assert [{_cmd, ""}] = writes(ctx.host.id)
    refute Revocations.pending?(ctx.host.id)
  end

  test "a rolled-back revocation starts no sync", ctx do
    stub_host(ctx.host.id, "ssh-ed25519 ALICE alice\n")

    {:error, :boom} =
      Grants.transaction(fn ->
        :ok = Revocations.mark(ctx.host.id, "test")
        Repo.rollback(:boom)
      end)

    assert MockClient.calls().exec_inputs == []
    refute Revocations.pending?(ctx.host.id)
  end

  test "off: the mark stays and nothing is written", ctx do
    Application.put_env(:ssm, :revocation_sync, "off")
    grant = grant!(ctx, ctx.alice)
    stub_host(ctx.host.id, "ssh-ed25519 ALICE alice\n")

    {:ok, _} = Grants.delete_grant(@admin, grant)

    assert MockClient.calls().exec_inputs == []
    assert Revocations.pending?(ctx.host.id)
  end

  test "parses SSM_REVOCATION_SYNC" do
    assert RevocationSync.parse(nil) == {:ok, false}
    assert RevocationSync.parse("") == {:ok, false}
    assert RevocationSync.parse("off") == {:ok, false}
    assert RevocationSync.parse(" ON ") == {:ok, true}
    assert {:error, _} = RevocationSync.parse("yes")
  end
end
