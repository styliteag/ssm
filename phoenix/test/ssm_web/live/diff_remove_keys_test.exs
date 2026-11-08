defmodule SsmWeb.DiffRemoveKeysTest do
  @moduledoc """
  Diff page "Remove" on an unauthorized line and "Remove all extra keys" of
  a login: admins and operators on hosts in their scope, never viewers;
  no button for a readonly or unsafe login.
  """

  use SsmWeb.OIDCCase

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.{Activity, Hosts}
  alias Ssm.Ssh.{MockClient, Result}

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"

  setup do
    start_supervised!(MockClient)
    Ssm.Diffs.StatusCache.reset()
    :ok
  end

  defp login_as(conn, provider, role, claims \\ %{}),
    do: sso_login(conn, provider, Map.put(claims, "orbit_role", role))

  defp stub_host(host, entries) do
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host.id, @version_probe, %Result{stdout: payload})

    MockClient.set_exec(host.id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
      stdout: Jason.encode!(entries)
    })

    MockClient.set_default_exec(%Result{exit_code: 0})
  end

  defp rogue_host(extra \\ %{}) do
    host = host_fixture(%{name: "web1"})

    stub_host(host, [
      Map.merge(
        %{
          login: "deploy",
          has_pragma: true,
          keyfile: "ssh-rsa ROGUE1 x\nssh-rsa ROGUE2 y\n"
        },
        extra
      )
    ])

    host
  end

  defp writes(host) do
    for {id, cmd, input} <- MockClient.calls().exec_inputs,
        id == host.id,
        String.contains?(cmd, "set_authorized_keyfile"),
        do: input
  end

  defp open(conn, host) do
    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)
    view
  end

  test "an admin removes one unauthorized line", %{conn: conn, provider: p} do
    host = rogue_host()
    view = open(login_as(conn, p, "admin"), host)

    view |> element("#remove-key-deploy-0") |> render_click()
    html = render_async(view)

    assert writes(host) == ["ssh-rsa ROGUE2 y\n"]
    assert html =~ "Removed 1 key line(s) from deploy on web1."
    assert hd(Activity.list()).action == "remove_keys"
  end

  test "an operator removes all extra keys of a login", %{conn: conn, provider: p} do
    host = rogue_host()
    view = open(login_as(conn, p, "operator"), host)

    view |> element("#remove-extra-deploy") |> render_click()
    render_async(view)

    assert writes(host) == [""]
  end

  test "a viewer gets no buttons and the events are refused", %{conn: conn, provider: p} do
    host = rogue_host()
    {:ok, view, _html} = live(login_as(conn, p, "viewer"), ~p"/diff?host_id=#{host.id}")

    refute has_element?(view, "#remove-extra-deploy")
    assert render_click(view, "remove-key", %{"login" => "deploy", "index" => "0"}) =~ "read-only"
    assert render_click(view, "remove-extra-keys", %{"login" => "deploy"}) =~ "read-only"
    assert writes(host) == []
  end

  test "a readonly or unsafe login has no remove buttons", %{conn: conn, provider: p} do
    host =
      rogue_host(%{readonly_condition: "user_readonly (root-owned)", readonly_scope: "user"})

    view = open(login_as(conn, p, "admin"), host)

    refute has_element?(view, "#remove-extra-deploy")
    refute has_element?(view, "[id^='remove-key-deploy-']")
  end

  test "a scoped operator cannot remove keys on a host outside its scope",
       %{conn: conn, provider: p} do
    {:ok, _} = Ssm.Customers.create_customer(%{slug: "acme", name: "Acme"})
    {:ok, _} = Ssm.Customers.create_customer(%{slug: "beta", name: "Beta"})
    host = rogue_host()
    {:ok, _} = Hosts.update_membership(host, %{customer: "beta"})

    conn = login_as(conn, p, "operator", %{"orbit_customers" => ["acme"]})
    {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
    render_async(view)

    refute has_element?(view, "#remove-extra-deploy")
    render_click(view, "remove-extra-keys", %{"login" => "deploy"})
    render_async(view)
    assert writes(host) == []
  end
end
