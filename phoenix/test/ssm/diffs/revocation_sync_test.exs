defmodule Ssm.Diffs.RevocationSyncTest.PausingClient do
  @moduledoc false
  # MockClient, but the first authorized_keys write of a run pauses until the
  # test sends :go — a sync is caught while it holds the host's write lock
  alias Ssm.Ssh.MockClient

  def connect(target), do: MockClient.connect(target)
  def read_file(target, path), do: MockClient.read_file(target, path)
  def write_file(target, path, content), do: MockClient.write_file(target, path, content)
  def probe_host_key(target, opts), do: MockClient.probe_host_key(target, opts)
  def close, do: MockClient.close()

  def exec(target, command, opts) do
    if String.contains?(command, "set_authorized_keyfile") do
      send(:persistent_term.get({__MODULE__, :test}), {:paused, self()})
      receive do: (:go -> :ok)
    end

    MockClient.exec(target, command, opts)
  end
end

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
  alias Ssm.Diffs
  alias Ssm.Diffs.{RevocationSync, Revocations}
  alias Ssm.Diffs.RevocationSyncTest.PausingClient
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

    [entry] = Repo.all(from l in ActivityLog, where: l.action == "sync_revocation")
    assert entry.actor_username == "ssm (revocation sync)"
    assert Repo.all(from l in ActivityLog, where: l.action == "sync") == []
    assert Jason.decode!(entry.meta)["mode"] == "removal_only"
  end

  test "restricted options replace the host's weaker line of that key", ctx do
    row = authorization_fixture(ctx.bob, ctx.host, %{login: "deploy"})

    stub_host(
      ctx.host.id,
      ~s(ssh-ed25519 BOB bob@laptop\npty,no-pty ssh-ed25519 BOBNEW new\nssh-ed25519 OTHER x\n)
    )

    {:ok, _} = Authorizations.update_authorization(row, %{options: ~s(no-pty,from="10.0.0.0/8")})

    assert [{_cmd, content}] = writes(ctx.host.id)
    lines = String.split(content, "\n", trim: true)
    assert [bob, bobnew] = lines
    assert bob =~ ~r/\Ano-pty,from="10.0.0.0\/8" ssh-ed25519 BOB( |\z)/
    assert bobnew =~ ~r/\Ano-pty,from="10.0.0.0\/8" ssh-ed25519 BOBNEW( |\z)/
    refute Revocations.pending?(ctx.host.id)
  end

  test "a host line at least as restricted as the database is kept verbatim", ctx do
    row = authorization_fixture(ctx.bob, ctx.host, %{login: "deploy"})
    host_line = ~s(no-pty,from="10.0.0.0/8",no-agent-forwarding ssh-ed25519 BOB bob@laptop)
    stub_host(ctx.host.id, host_line <> "\nssh-ed25519 OTHER x\n")

    {:ok, _} = Authorizations.update_authorization(row, %{options: ~s(no-pty,from="10.0.0.0/8")})

    assert [{_cmd, content}] = writes(ctx.host.id)
    assert content == host_line <> "\n"
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
    assert [_] = Repo.all(from l in ActivityLog, where: l.action == "sync_revocation_failed")
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

  describe "one write at a time per host (Ssm.Hosts.WriteLock)" do
    defp listings(host_id) do
      Enum.count(MockClient.calls().exec, fn {id, cmd} ->
        id == host_id and String.contains?(cmd, "get_ssh_keyfiles")
      end)
    end

    defp removal_sync(client, host_id), do: RevocationSync.run(client, host_id)
    defp manual_sync(client, host_id), do: Diffs.sync_host(client, host_id)

    for {first, second} <- [
          {:removal_sync, :manual_sync},
          {:manual_sync, :removal_sync}
        ] do
      test "#{first} holds the lock: #{second} waits until it is done", ctx do
        authorization_fixture(ctx.alice, ctx.host, %{login: "deploy"})
        stub_host(ctx.host.id, "ssh-ed25519 ALICE alice\nssh-ed25519 BOB bob\n")
        :persistent_term.put({PausingClient, :test}, self())
        on_exit(fn -> :persistent_term.erase({PausingClient, :test}) end)

        running = Task.async(fn -> unquote(first)(PausingClient, ctx.host.id) end)
        assert_receive {:paused, writer}, 2_000

        waiting = Task.async(fn -> unquote(second)(MockClient, ctx.host.id) end)
        assert Task.yield(waiting, 300) == nil
        # the waiting sync has not even read the host
        assert listings(ctx.host.id) == 1

        send(writer, :go)
        Task.await(running)
        Task.await(waiting)
        assert listings(ctx.host.id) == 2
      end
    end

    test "a removal sync waits for any other writer of the host, audit included", ctx do
      authorization_fixture(ctx.alice, ctx.host, %{login: "deploy"})
      stub_host(ctx.host.id, "ssh-ed25519 ALICE alice\nssh-ed25519 BOB bob\n")
      test = self()

      # KeyRemoval, offboarding and ManagedLogins.forget hold this lock
      holder =
        spawn(fn ->
          Ssm.Hosts.WriteLock.run(ctx.host.id, fn ->
            send(test, :locked)
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive :locked, 2_000
      waiting = Task.async(fn -> RevocationSync.run(MockClient, ctx.host.id) end)
      assert Task.yield(waiting, 300) == nil
      assert MockClient.calls().exec == []
      assert Repo.all(from l in ActivityLog, where: l.host_id == ^ctx.host.id) == []

      send(holder, :release)
      Task.await(waiting)
      assert [_] = writes(ctx.host.id)
    end
  end

  test "parses SSM_REVOCATION_SYNC" do
    assert RevocationSync.parse(nil) == {:ok, false}
    assert RevocationSync.parse("") == {:ok, false}
    assert RevocationSync.parse("off") == {:ok, false}
    assert RevocationSync.parse(" ON ") == {:ok, true}
    assert {:error, _} = RevocationSync.parse("yes")
  end
end
