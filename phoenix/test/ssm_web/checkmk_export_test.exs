defmodule SsmWeb.CheckmkExportTest do
  @moduledoc """
  `GET /api/export/checkmk`: the periodic key check for STYLiTE Orbit
  Monitor, behind an `ssm_` service token with scope `read`.
  """
  use SsmWeb.ConnCase, async: false

  import Ssm.Fixtures

  alias Ssm.Diffs.HostCheck
  alias Ssm.{MctlFixtures, Repo}

  @path "/api/export/checkmk"

  setup do
    Ssm.RateLimit.reset()
    :ok
  end

  defp get_export(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> get(@path)
  end

  test "enabled hosts with their stored check, disabled hosts left out", %{conn: conn} do
    web = host_fixture(%{name: "web-1", address: "192.0.2.10"})
    _off = host_fixture(%{name: "off-1", disabled: true})

    Repo.insert!(%HostCheck{
      host_id: web.id,
      state: "synced",
      logins: 2,
      drift: [],
      checked_at: DateTime.utc_now(:second),
      changed_at: DateTime.utc_now(:second)
    })

    body = conn |> get_export(MctlFixtures.token(["read"])) |> json_response(200)

    assert %{"version" => 1, "instances" => [instance]} = body
    assert %{"name" => "web-1", "host" => "web-1", "checks" => [check]} = instance
    assert %{"key" => "ssh_keys", "state" => 0} = check
    refute Jason.encode!(body) =~ "192.0.2.10"
  end

  test "refused without a token, with a bad token and without scope read", %{conn: conn} do
    assert conn |> get(@path) |> json_response(401)
    assert build_conn() |> get_export("ssm_not-a-token") |> json_response(401)

    assert %{"error" => %{"code" => "insufficient_scope"}} =
             build_conn() |> get_export(MctlFixtures.token(["setup"])) |> json_response(403)
  end
end
