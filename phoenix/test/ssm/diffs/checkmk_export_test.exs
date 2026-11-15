defmodule Ssm.Diffs.CheckmkExportTest do
  use ExUnit.Case, async: true

  alias Ssm.Diffs.{CheckmkExport, HostCheck}

  @now ~U[2026-11-15 20:00:00Z]
  @stale_after 2700

  defp check(attrs) do
    struct!(
      %HostCheck{
        host_id: 1,
        state: "synced",
        logins: 2,
        drift: [],
        error_code: nil,
        error: nil,
        checked_at: DateTime.add(@now, -60),
        changed_at: DateTime.add(@now, -3600)
      },
      attrs
    )
  end

  defp export_check(check) do
    %{"version" => 1, "instances" => [instance]} =
      CheckmkExport.build([%{id: 7, name: "web-1", check: check}], @now, @stale_after)

    case instance["checks"] do
      [] -> nil
      [one] -> one
    end
  end

  test "an instance per host, named after the host, never its address" do
    rows = [%{id: 7, name: "web-1", check: check([])}, %{id: 9, name: "db-1", check: nil}]

    assert %{"version" => 1, "instances" => [web, db]} =
             CheckmkExport.build(rows, @now, @stale_after)

    assert %{"instance_id" => 7, "name" => "web-1", "host" => "web-1"} = web
    assert web["device_type"] == "ssh_host"
    assert %{"instance_id" => 9, "checks" => []} = db
  end

  test "states by check result" do
    cases = [
      {check(state: "synced", logins: 3), 0, "3 logins in sync"},
      {check(state: "synced", logins: 1), 0, "1 login in sync"},
      {check(
         state: "drift",
         drift: [
           %{"login" => "root", "missing" => ["a", "b"], "extra" => ["c"]},
           %{"login" => "deploy", "missing" => ["d"], "extra" => [], "blocked" => "x"}
         ]
       ), 2, "drift on 2 logins: 3 keys missing, 1 extra"},
      {check(state: "error", error_code: "host_key_changed", error: "whatever"), 2,
       "host key differs from the pinned one"},
      {check(state: "error", error_code: "timeout", error: "the SSH connection timed out"), 1,
       "the SSH connection timed out"},
      {check(state: "error", error_code: "auth_failed", error: "SSH authentication failed"), 1,
       "SSH authentication failed"},
      {check(state: "error", error_code: nil, error: nil), 1, "the SSH connection failed"}
    ]

    for {check, state, summary} <- cases do
      assert %{"key" => "ssh_keys", "state" => ^state, "summary" => ^summary, "metrics" => []} =
               export_check(check)
    end
  end

  test "a check older than the stale limit is unknown, whatever its result" do
    old = check(state: "drift", checked_at: DateTime.add(@now, -@stale_after - 1))

    assert %{"state" => 3, "summary" => "last key check 45 min ago"} = export_check(old)
    assert %{"state" => 0} = export_check(check(checked_at: DateTime.add(@now, -@stale_after)))
  end

  test "no key material: drift labels never reach the summary" do
    drift = [%{"login" => "root", "missing" => ["ssh-ed25519 SHA256:abc alice"], "extra" => []}]
    %{"summary" => summary} = export_check(check(state: "drift", drift: drift))

    refute summary =~ "SHA256"
    refute summary =~ "alice"
  end
end
