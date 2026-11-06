defmodule SsmWeb.MctlHostConflictTest do
  @moduledoc "Wire-level 409 for duplicate hosts, and re-POST after a failed create_host job."

  use SsmWeb.ConnCase, async: false

  import Ssm.Fixtures

  alias Ssm.Ssh.MockClient

  @ed "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDe2nndD7+tlXY2983h/zouDiBPDl6Ni4YtTK7Y5TyuQ"
  @ecdsa_fp "ecdsa-sha2-nistp256 SHA256:lF0rWjfoTUXjkp9k51UM1vcqsjpqOz9XcMLrCCVpnNM"

  setup %{conn: conn} do
    start_supervised!(MockClient)
    MockClient.set_default_host_keys([@ed])

    {:ok, _t, plain} =
      MctlContract.Tokens.Ecto.create("conflict-test", ~w(read setup), prefix: "ssm_")

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> plain)
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn}
  end

  defp post_host(conn, params), do: post(conn, "/api/mctl/v1/hosts", Jason.encode!(params))

  defp await_jobs do
    for pid <- Task.Supervisor.children(Ssm.Mctl.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end
  end

  test "duplicate name: 409 conflict with details naming name", %{conn: conn} do
    host = host_fixture(%{name: "dup"})

    body =
      conn
      |> post_host(%{name: "dup", addresses: ["10.77.0.1"], mode: "pull"})
      |> json_response(409)

    assert %{"error" => %{"code" => "conflict", "details" => %{"name" => [_]}}} = body
    assert is_integer(host.id)
  end

  test "duplicate address: 409 conflict with details naming address", %{conn: conn} do
    host = host_fixture()

    body =
      conn
      |> post_host(%{name: "other", addresses: [host.address], mode: "pull"})
      |> json_response(409)

    assert %{"error" => %{"code" => "conflict", "details" => %{"address" => [_]}}} = body
  end

  test "a rejected pin leaves no host behind, so the re-POST succeeds", %{conn: conn} do
    bad = %{
      name: "retry",
      addresses: ["10.77.0.2"],
      mode: "pull",
      attributes: %{key_fingerprint: @ecdsa_fp}
    }

    assert conn |> post_host(bad) |> json_response(202)
    await_jobs()

    good = Map.delete(bad, :attributes)
    assert conn |> post_host(good) |> json_response(202)
    await_jobs()
  end
end
