defmodule SsmWeb.StatusTextTest do
  @moduledoc "One word per host state, on every page."
  use ExUnit.Case, async: true

  alias SsmWeb.StatusText

  test "sync view: every Ssm.HostStatus value has one label and one badge class" do
    for {status, label, class} <- [
          {:disabled, "disabled", "badge-neutral"},
          {:loading, "checking…", "badge-ghost"},
          {:unchecked, "not checked", "badge-ghost"},
          {:synced, "in sync", "badge-success"},
          {{:drift, 2, 1}, "needs sync (+2/−1)", "badge-warning"},
          {:reachable, "online", "badge-success"},
          {{:auth_failed, "x"}, "key not accepted", "badge-error"},
          {{:host_key_changed, "x"}, "host key changed", "badge-error"},
          {{:unreachable, "x"}, "unreachable", "badge-error"}
        ] do
      assert StatusText.label(status) == label
      assert StatusText.class(status) == class
    end
  end

  test "connection view: a host whose keys were read is online" do
    assert StatusText.connection(:synced) == "online"
    assert StatusText.connection({:drift, 1, 0}) == "online"
    assert StatusText.connection(:reachable) == "online"
    assert StatusText.connection({:unreachable, "x"}) == "unreachable"
    assert StatusText.connection(:unchecked) == "not checked"
    assert StatusText.connection_class({:drift, 1, 0}) == "badge-success"
  end

  test "stored check states use the same words" do
    assert StatusText.check_state(nil) == {"not checked", "badge-ghost"}
    assert StatusText.check_state("synced") == {"in sync", "badge-success"}
    assert StatusText.check_state("drift") == {"needs sync", "badge-warning"}
    assert StatusText.check_state("error") == {"check failed", "badge-error"}
  end
end
