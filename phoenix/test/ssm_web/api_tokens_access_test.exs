defmodule SsmWeb.ApiTokensAccessTest do
  use SsmWeb.OIDCCase

  import Phoenix.LiveViewTest

  alias MctlContract.{Connect, Tokens}

  defp login_as(conn, provider, role), do: sso_login(conn, provider, %{"orbit_role" => role})

  for role <- ~w(operator viewer) do
    test "#{role} cannot open the page", %{conn: conn, provider: p} do
      conn = login_as(conn, p, unquote(role))

      assert {:error, {:redirect, %{to: "/dashboard", flash: flash}}} =
               live(conn, ~p"/settings/api-tokens")

      assert flash["error"] =~ "administrators"
    end
  end

  test "admin SSO user can open it and create", %{conn: conn, provider: p} do
    conn = login_as(conn, p, "admin")
    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")
    html = view |> form("#connect-form", %{"scopes" => ["read"]}) |> render_submit()
    assert html =~ "shown once"
    assert %{state: "active"} = Connect.status(Tokens.Ecto)
  end

  test "admin demoted while the page is open: events refused, nothing created",
       %{conn: conn, provider: p} do
    conn = login_as(conn, p, "admin")
    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")

    # Simulate an event reaching a socket whose user is no longer admin.
    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns.current_user, &Map.put(&1, :role, "operator"))
    end)

    html = render_hook(view, "create", %{"scopes" => ["read"]})
    assert html =~ "administrators"
    assert Connect.status(Tokens.Ecto) == nil
  end
end
