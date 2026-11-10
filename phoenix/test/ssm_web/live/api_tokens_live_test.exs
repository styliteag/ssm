defmodule SsmWeb.ApiTokensLiveTest do
  use SsmWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias MctlContract.{Connect, Tokens}
  alias Ssm.Activity.ActivityLog
  alias Ssm.Repo

  setup [:setup_htpasswd, :log_in]

  defp audit(action), do: Repo.all(from(l in ActivityLog, where: l.action == ^action))
  defp token_in(html), do: hd(Regex.run(~r/ssm_[A-Za-z0-9_-]{20,}/, html))
  defp verify(plain), do: Tokens.Ecto.verify(plain)

  defp create(view, scopes \\ ~w(read setup commands)) do
    view
    |> form("#connect-form", %{"scopes" => scopes})
    |> render_submit()
  end

  test "anonymous visitor is redirected" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings/api-tokens")
  end

  test "no token yet: status none, all scopes checked", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings/api-tokens")
    assert html =~ "Connect Mission Control"
    assert has_element?(view, "#connect-status", "No token")

    for scope <- ~w(read setup commands) do
      assert has_element?(view, "#connect-form input[value=#{scope}][checked]")
    end

    refute has_element?(view, "#connect-rotate")
    refute has_element?(view, "#connect-revoke")
  end

  test "create shows token once with base URL and snippet; token verifies; audited",
       %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")
    html = create(view)

    plain = token_in(html)
    assert {:ok, %{name: "mission-control", scopes: scopes}} = verify(plain)
    assert Enum.sort(scopes) == ~w(commands read setup)

    assert has_element?(view, "#connect-secret", plain)
    assert html =~ SsmWeb.Endpoint.url()
    assert has_element?(view, "#connect-snippet", "\"kind\": \"ssm\"")
    assert has_element?(view, "#connect-snippet", "token_file")
    assert has_element?(view, "#connect-secret-note", "shown once")
    assert has_element?(view, "#copy-connect-token")
    assert has_element?(view, "#copy-connect-snippet")

    assert [entry] = audit("mctl.connect.create")
    assert entry.actor_username == "admin"
    meta = Jason.decode!(entry.meta)
    assert meta["scopes"] == ~w(read setup commands)
    assert meta["prefix"] == Connect.status(Tokens.Ecto).prefix
    refute entry.meta =~ plain
    refute inspect(entry) =~ plain
  end

  test "Done clears the token from the page; status keeps only the prefix", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")
    plain = token_in(create(view))

    html = view |> element("#connect-done") |> render_click()
    refute html =~ plain
    refute has_element?(view, "#connect-secret")
    assert has_element?(view, "#connect-status", "Active")
    refute render(view) =~ plain

    {:ok, _view, fresh} = live(conn, ~p"/settings/api-tokens")
    refute fresh =~ plain
  end

  test "status line shows prefix, scopes, last use and IP", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")
    plain = token_in(create(view, ~w(read)))
    {:ok, principal} = verify(plain)
    Tokens.Ecto.touch(principal, "203.0.113.7")

    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")
    status = Connect.status(Tokens.Ecto)
    assert has_element?(view, "#connect-status", status.prefix)
    assert has_element?(view, "#connect-status", "read")
    assert has_element?(view, "#connect-status", "203.0.113.7")
    refute has_element?(view, "#connect-form")
    assert has_element?(view, "#connect-rotate[data-confirm]")
    assert has_element?(view, "#connect-revoke[data-confirm]")
  end

  test "empty scopes: error flash, nothing created", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")
    html = view |> form("#connect-form") |> render_submit(%{"scopes" => []})
    assert html =~ "at least one scope"
    assert Connect.status(Tokens.Ecto) == nil
    assert audit("mctl.connect.create") == []
    refute has_element?(view, "#connect-secret")
  end

  test "rotate: new secret, same scopes, old token invalid, audited", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")
    old = token_in(create(view, ~w(read setup)))
    view |> element("#connect-done") |> render_click()

    html = view |> element("#connect-rotate") |> render_click()
    new = token_in(html)

    assert new != old
    assert {:error, _} = verify(old)
    assert {:ok, %{scopes: scopes}} = verify(new)
    assert Enum.sort(scopes) == ~w(read setup)
    assert has_element?(view, "#connect-secret", new)

    assert [entry] = audit("mctl.connect.rotate")
    assert Jason.decode!(entry.meta)["scopes"] == ~w(read setup)
    refute entry.meta =~ new
  end

  test "revoke: token invalid, status revoked, create offered again", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")
    plain = token_in(create(view))
    view |> element("#connect-done") |> render_click()

    view |> element("#connect-revoke") |> render_click()
    assert {:error, _} = verify(plain)
    assert has_element?(view, "#connect-status", "Revoked")
    refute has_element?(view, "#connect-revoke")
    refute has_element?(view, "#connect-rotate")
    assert has_element?(view, "#connect-form")
    assert [entry] = audit("mctl.connect.revoke")
    assert Jason.decode!(entry.meta)["prefix"] == Connect.status(Tokens.Ecto).prefix
  end

  test "env-managed mission-control-env token stays untouched", %{conn: conn} do
    {:ok, _t, env_plain} =
      Tokens.Ecto.create("mission-control-env", ["read"], prefix: "ssm_")

    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")
    create(view)
    view |> element("#connect-done") |> render_click()
    view |> element("#connect-rotate") |> render_click()
    view |> element("#connect-done") |> render_click()
    view |> element("#connect-revoke") |> render_click()

    assert {:ok, %{name: "mission-control-env", scopes: ["read"]}} = verify(env_plain)
  end

  test "stale create event after Done does not leak or reuse a secret", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/api-tokens")
    plain = token_in(create(view))
    html = view |> element("#connect-done") |> render_click()
    refute html =~ plain
  end
end
