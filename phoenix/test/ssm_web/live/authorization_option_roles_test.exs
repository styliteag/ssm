defmodule SsmWeb.AuthorizationOptionRolesTest do
  @moduledoc """
  Authorizations page: an SSO operator may set restrictive options only;
  permissive ones (`pty`, `agent-forwarding`, …) are refused with a form
  error, in the single form and in bulk grant. Admins may set them.
  """

  use SsmWeb.OIDCCase

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Authorizations

  defp login_as(conn, provider, role), do: sso_login(conn, provider, %{"orbit_role" => role})

  defp save(lv, user, host, options) do
    render_click(lv, "new", %{})

    lv
    |> form("#authorization-form",
      authorization: %{
        user_id: user.id,
        host_id: host.id,
        login: "deploy",
        options: options
      }
    )
    |> render_submit()
  end

  test "an operator's permissive option is refused with a form error", %{conn: conn, provider: p} do
    user = user_fixture()
    host = host_fixture()
    {:ok, lv, _} = live(login_as(conn, p, "operator"), ~p"/access")

    html = save(lv, user, host, "agent-forwarding")
    assert html =~ "may be set by an admin only"
    refute Authorizations.exists?(user.id, host.id, "deploy")

    save(lv, user, host, "no-pty")
    assert Authorizations.exists?(user.id, host.id, "deploy")
  end

  test "an operator's bulk grant with a permissive option creates nothing",
       %{conn: conn, provider: p} do
    user = user_fixture()
    host = host_fixture()
    {:ok, lv, _} = live(login_as(conn, p, "operator"), ~p"/access")

    render_click(lv, "bulk-open", %{})
    render_click(lv, "bulk-toggle-user", %{"id" => to_string(user.id)})
    render_click(lv, "bulk-toggle-host", %{"id" => to_string(host.id)})
    render_change(lv, "bulk-change", %{"bulk" => %{"login" => "ops", "options" => "pty"}})

    assert render_click(lv, "bulk-save", %{}) =~ "may be set by an admin only"
    refute Authorizations.exists?(user.id, host.id, "ops")
  end

  test "an admin may set permissive options", %{conn: conn, provider: p} do
    user = user_fixture()
    host = host_fixture()
    {:ok, lv, _} = live(login_as(conn, p, "admin"), ~p"/access")

    save(lv, user, host, "agent-forwarding")
    assert Authorizations.exists?(user.id, host.id, "deploy")
  end
end
