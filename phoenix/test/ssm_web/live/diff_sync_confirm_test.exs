defmodule SsmWeb.DiffSyncConfirmTest do
  @moduledoc """
  Every button that writes to a host asks first and says what the write
  does: how many hosts, how many key lines are added and removed, and that
  lines not authorized in ssm (keys added by hand) are removed.
  """
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.Ssh.MockClient
  alias Ssm.Ssh.Result

  @version_probe "sh .ssm/script.sh version 2>/dev/null || true"

  setup [:setup_htpasswd, :log_in]

  setup do
    start_supervised!(MockClient)
    Ssm.Diffs.StatusCache.reset()
    :ok
  end

  defp stub_keyfiles(host_id, entries) do
    payload = Jason.encode!(%{version: "x", sha256: Ssm.Ssh.ScriptRunner.script_sha256()})
    MockClient.set_exec(host_id, @version_probe, %Result{stdout: payload})

    MockClient.set_exec(host_id, "sh .ssm/script.sh get_ssh_keyfiles", %Result{
      stdout: Jason.encode!(entries)
    })
  end

  # one key expected, one hand-added key on the host: drift +1/−1
  defp drifted_host(name) do
    user = user_fixture()
    host = host_fixture(%{name: name})
    key_fixture(user, %{key_type: "ssh-ed25519", key_base64: "WANTED#{name}", name: nil})
    authorization_fixture(user, host, %{login: "deploy"})

    stub_keyfiles(host.id, [
      %{login: "deploy", has_pragma: false, readonly_condition: nil, keyfile: "ssh-rsa ROGUE x"}
    ])

    host
  end

  defp confirm_text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-confirm")
    |> List.first("")
  end

  describe "Sync all" do
    test "has no confirm while no checked host needs a sync", %{conn: conn} do
      drifted_host("web1")

      {:ok, view, _html} = live(conn, ~p"/diff?view=list")

      assert has_element?(view, "#sync-all:not([data-confirm])")
    end

    test "names the hosts and the lines it adds and removes", %{conn: conn} do
      drifted_host("web1")
      drifted_host("web2")

      {:ok, view, _html} = live(conn, ~p"/diff?view=list")
      view |> element("#recheck-all") |> render_click()
      render_async(view)

      text = confirm_text(view, "#sync-all")

      assert text =~ "Sync 2 hosts"
      assert text =~ "adds 2 key lines"
      assert text =~ "removes 2 key lines"
      assert text =~ "added by hand"
      assert text =~ "checked just now"
    end
  end

  describe "single host sync" do
    test "the row button says lines not in ssm are removed", %{conn: conn} do
      host = drifted_host("web1")

      {:ok, view, _html} = live(conn, ~p"/diff?view=list")
      view |> element("#recheck-row-#{host.id}") |> render_click()
      render_async(view)

      text = confirm_text(view, "#sync-row-#{host.id}")

      assert text =~ "Sync web1?"
      assert text =~ "adds 1 key line"
      assert text =~ "removes 1 key line"
      assert text =~ "added by hand"
    end

    test "an unchecked host still warns about removals", %{conn: conn} do
      host = drifted_host("web1")

      {:ok, view, _html} = live(conn, ~p"/diff?view=list")

      text = confirm_text(view, "#sync-row-#{host.id}")

      assert text =~ "not checked yet"
      assert text =~ "added by hand"
    end

    test "the detail Sync button asks first", %{conn: conn} do
      host = drifted_host("web1")

      {:ok, view, _html} = live(conn, ~p"/diff?host_id=#{host.id}")
      render_async(view)

      text = confirm_text(view, "#sync-host")

      assert text =~ "Sync web1?"
      assert text =~ "removes 1 key line"
    end
  end
end
