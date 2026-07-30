defmodule Ssm.Ssh.CacheTest do
  use ExUnit.Case, async: false

  alias Ssm.Ssh.{Cache, MockClient, Target}

  # Ssm.Ssh.Cache is a named singleton started by the application supervisor;
  # reset its ETS between cases and point it at a fresh mock each time.
  setup do
    start_supervised!(MockClient)
    Cache.reset()

    previous = Application.get_env(:ssm, :ssh_inner_client)
    Application.put_env(:ssm, :ssh_inner_client, MockClient)

    on_exit(fn ->
      Cache.reset()

      case previous do
        nil -> Application.delete_env(:ssm, :ssh_inner_client)
        mod -> Application.put_env(:ssm, :ssh_inner_client, mod)
      end
    end)

    :ok
  end

  defp target(id \\ 1),
    do: %Target{host_id: id, name: "h#{id}", address: "10.0.0.#{id}", port: 22, username: "root"}

  test "read_file hits the inner client once per {host, path}" do
    MockClient.set_file(1, ".ssh/authorized_keys", "key\n")

    assert {:ok, %{content: "key\n"}} = Cache.read_file(target(), ".ssh/authorized_keys")
    assert {:ok, %{content: "key\n"}} = Cache.read_file(target(), ".ssh/authorized_keys")

    assert MockClient.calls().read == [{1, ".ssh/authorized_keys"}]
  end

  test "write_file invalidates exactly that entry" do
    MockClient.set_file(1, "a", "old-a")
    MockClient.set_file(1, "b", "old-b")

    {:ok, _} = Cache.read_file(target(), "a")
    {:ok, _} = Cache.read_file(target(), "b")

    :ok = Cache.write_file(target(), "a", "new-a")

    assert {:ok, %{content: "new-a"}} = Cache.read_file(target(), "a")
    assert {:ok, %{content: "old-b"}} = Cache.read_file(target(), "b")

    # "a" was re-read after the write; "b" stayed cached.
    assert MockClient.calls().read == [{1, "a"}, {1, "b"}, {1, "a"}]
  end

  test "invalidate/1 drops every entry of one host only" do
    MockClient.set_file(1, "a", "h1-a")
    MockClient.set_file(2, "a", "h2-a")

    {:ok, _} = Cache.read_file(target(1), "a")
    {:ok, _} = Cache.read_file(target(2), "a")

    :ok = Cache.invalidate(1)

    {:ok, _} = Cache.read_file(target(1), "a")
    {:ok, _} = Cache.read_file(target(2), "a")

    assert MockClient.calls().read == [{1, "a"}, {2, "a"}, {1, "a"}]
  end

  test "failed reads are not cached" do
    t = target()

    assert {:error, _} = Cache.read_file(t, "missing")

    MockClient.set_file(1, "missing", "now exists")
    assert {:ok, %{content: "now exists"}} = Cache.read_file(t, "missing")
  end

  test "exec passes through untouched" do
    MockClient.set_default_exec(%Ssm.Ssh.Result{stdout: "hi"})
    assert {:ok, %{stdout: "hi"}} = Cache.exec(target(), "echo hi", [])
  end
end
