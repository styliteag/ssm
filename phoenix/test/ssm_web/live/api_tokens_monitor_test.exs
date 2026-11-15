defmodule SsmWeb.ApiTokensMonitorTest do
  @moduledoc "Setup → API tokens → \"Connect Orbit Monitor\" (key check export token)."
  use SsmWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias MctlContract.Tokens
  alias Ssm.Activity.ActivityLog
  alias Ssm.Repo

  setup [:setup_htpasswd, :log_in]

  setup do
    Ssm.RateLimit.reset()
    :ok
  end

  defp audit(action), do: Repo.all(from(l in ActivityLog, where: l.action == ^action))
  defp token_in(html), do: hd(Regex.run(~r/ssm_[A-Za-z0-9_-]{20,}/, html))

  defp export_status(plain) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> plain)
    |> get("/api/export/checkmk")
    |> Map.fetch!(:status)
  end

  test "create issues a read-only token that opens the export; audited without it",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")
    assert has_element?(view, "#monitor-status", "No token")

    plain = view |> element("#monitor-create") |> render_click() |> token_in()

    assert {:ok, %{name: "orbit-monitor", scopes: ["read"]}} = Tokens.Ecto.verify(plain)
    assert has_element?(view, "#monitor-secret", plain)
    assert has_element?(view, "#monitor-export-url", "/api/export/checkmk")
    assert export_status(plain) == 200

    assert [entry] = audit("omon.connect.create")
    assert Jason.decode!(entry.meta)["scopes"] == ["read"]
    refute inspect(entry) =~ plain

    view |> element("#monitor-done") |> render_click()
    refute render(view) =~ plain
    assert has_element?(view, "#monitor-status", "Active")
  end

  test "rotate replaces the secret, revoke closes the export", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")
    first = view |> element("#monitor-create") |> render_click() |> token_in()
    view |> element("#monitor-done") |> render_click()

    second = view |> element("#monitor-rotate") |> render_click() |> token_in()
    assert second != first
    assert export_status(first) == 401
    assert export_status(second) == 200
    view |> element("#monitor-done") |> render_click()

    view |> element("#monitor-revoke") |> render_click()
    assert export_status(second) == 401
    assert has_element?(view, "#monitor-status", "Revoked")
    assert [_] = audit("omon.connect.rotate")
    assert [_] = audit("omon.connect.revoke")
  end

  test "the Mission Control token is a different token", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")
    view |> element("#monitor-create") |> render_click()
    view |> element("#monitor-done") |> render_click()

    assert has_element?(view, "#connect-status", "No token")
  end
end
