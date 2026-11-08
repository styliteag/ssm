defmodule SsmWeb.HostsManagedLoginsTest do
  @moduledoc """
  Hosts page, admin only: list a host's managed logins and "Forget" one
  without authorizations and without a file on the host. Operators and
  viewers get neither the button nor the events.
  """

  use SsmWeb.OIDCCase

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.{Activity, Authorizations}
  alias Ssm.Ssh.{MockClient, Result}

  setup do
    start_supervised!(MockClient)
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_default_exec(%Result{stdout: payload})
    host = host_fixture(%{name: "web1"})
    authorization_fixture(user_fixture(), host, %{login: "deploy"})
    auth = authorization_fixture(user_fixture(), host, %{login: "old"})
    {:ok, _} = Authorizations.delete_authorization(auth)

    MockClient.set_exec(host.id, "sh .ssm/script.sh has_keyfile old", %Result{stdout: "no\n"})
    %{host: host}
  end

  defp login_as(conn, provider, role), do: sso_login(conn, provider, %{"orbit_role" => role})

  test "an admin lists managed logins and forgets one without grants and file",
       %{conn: conn, provider: p, host: host} do
    {:ok, lv, _} = live(login_as(conn, p, "admin"), ~p"/hosts")

    lv |> element("#managed-logins-#{host.id}") |> render_click()
    assert has_element?(lv, "#managed-login-deploy", "1")
    assert has_element?(lv, "#forget-login-deploy[disabled]")
    assert has_element?(lv, "#managed-login-old")

    lv |> element("#forget-login-old") |> render_click()
    html = render_async(lv)

    assert html =~ "Forgot login old on web1."
    assert Authorizations.managed_logins(host.id) == ["deploy"]
    refute has_element?(lv, "#managed-login-old")
    assert hd(Activity.list()).action == "forget_login"
  end

  test "a refusal is shown and the login stays", %{conn: conn, provider: p, host: host} do
    MockClient.set_exec(host.id, "sh .ssm/script.sh has_keyfile old", %Result{stdout: "yes\n"})
    {:ok, lv, _} = live(login_as(conn, p, "admin"), ~p"/hosts")

    lv |> element("#managed-logins-#{host.id}") |> render_click()
    lv |> element("#forget-login-old") |> render_click()

    assert render_async(lv) =~ "remove the file on the host first"
    assert Authorizations.managed_logins(host.id) == ["deploy", "old"]
  end

  for role <- ~w(operator viewer) do
    test "#{role}: no button, events refused", %{conn: conn, provider: p, host: host} do
      {:ok, lv, _} = live(login_as(conn, p, unquote(role)), ~p"/hosts")

      refute has_element?(lv, "#managed-logins-#{host.id}")
      render_click(lv, "managed-logins", %{"id" => to_string(host.id)})
      refute has_element?(lv, "#managed-logins-modal")

      render_click(lv, "forget-login", %{"host-id" => to_string(host.id), "login" => "old"})
      assert Authorizations.managed_logins(host.id) == ["deploy", "old"]
      assert MockClient.calls().exec == []
    end
  end
end
