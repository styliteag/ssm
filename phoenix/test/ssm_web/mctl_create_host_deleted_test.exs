defmodule SsmWeb.MctlCreateHostDeletedTest do
  # a host deleted (e.g. DELETE /hosts/{id}) while its create_host job runs:
  # the job ends cleanly as failed / host_deleted, nothing crashes
  use Ssm.DataCase, async: false

  alias MctlContract.Principal
  alias Ssm.Hosts
  alias Ssm.Ssh.MockClient
  alias SsmWeb.MctlProvider

  @ed "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDe2nndD7+tlXY2983h/zouDiBPDl6Ni4YtTK7Y5TyuQ"

  @p %Principal{
    id: 1,
    name: "mission-control",
    prefix: "ssm_abc",
    scopes: ~w(read setup),
    ip: "203.0.113.9"
  }

  setup do
    start_supervised!(MockClient)
    MockClient.set_default_host_keys([@ed])
    on_exit(fn -> Application.delete_env(:ssm, :test_own_key_hook) end)
    :ok
  end

  defp await_jobs do
    for pid <- Task.Supervisor.children(Ssm.Mctl.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end

    :ok
  end

  test "deleted after the job read the host: failed with host_deleted" do
    test_pid = self()

    # runs inside the job, after it loaded the host and before it pins
    Application.put_env(:ssm, :test_own_key_hook, fn ->
      receive do
        {:delete, host_id} -> {:ok, _} = host_id |> Hosts.get_host() |> Hosts.delete_host()
      after
        1_000 -> :ok
      end

      send(test_pid, :deleted)
    end)

    {:ok, job} =
      MctlProvider.create_host(@p, %{
        "name" => "gone",
        "addresses" => ["10.9.9.9"],
        "mode" => "pull"
      })

    host_id = String.to_integer(job.host_id)
    [task] = Task.Supervisor.children(Ssm.Mctl.TaskSupervisor)
    send(task, {:delete, host_id})
    assert_receive :deleted, 2_000
    await_jobs()

    assert {:ok, done} = MctlProvider.get_job(@p, job.id)
    assert done.state == "failed"
    assert done.error["code"] == "host_deleted"
    assert Hosts.get_host(host_id) == nil
  end

  test "deleted before the job started: failed with host_deleted" do
    Application.put_env(:ssm, :test_own_key_hook, fn -> :ok end)

    {:ok, host} =
      Hosts.create_host(%{name: "early", address: "10.9.9.8", port: 22, username: "root"})

    {:ok, _} = Hosts.delete_host(host)

    {:ok, job} =
      MctlContract.Jobs.Ecto.run(
        "create_host",
        to_string(host.id),
        &SsmWeb.Mctl.CreateHostJob.run(host.id, @p, &1),
        inline: true
      )

    assert job.state == "failed"
    assert MctlContract.Jobs.Ecto.to_map(job).error["code"] == "host_deleted"
  end
end
