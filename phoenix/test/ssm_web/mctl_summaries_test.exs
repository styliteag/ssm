defmodule SsmWeb.MctlSummariesTest do
  @moduledoc """
  C4 host summaries (contract-v1 section 9, ssm column) from the persisted
  periodic check (`Ssm.Diffs.HostCheck`).
  """
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Diffs.HostCheck
  alias Ssm.Hosts
  alias SsmWeb.MctlProvider, as: P

  @principal %MctlContract.Principal{
    id: 1,
    name: "mission-control",
    prefix: "ssm_x",
    scopes: ["read"]
  }
  @checked ~U[2026-11-06 10:00:00Z]
  @changed ~U[2026-11-06 09:30:00Z]

  defp page(filters \\ %{}, limit \\ 100, after_key \\ nil),
    do: %{after: after_key, limit: limit, filters: filters}

  defp put_check(host, attrs) do
    Repo.insert!(
      struct!(
        HostCheck,
        Map.merge(
          %{
            host_id: host.id,
            state: "synced",
            logins: 1,
            drift: [],
            checked_at: @checked,
            changed_at: @changed
          },
          attrs
        )
      ),
      on_conflict: :replace_all,
      conflict_target: :host_id
    )
  end

  defp summary(host) do
    {:ok, s} = P.get_host_summary(@principal, to_string(host.id))
    s
  end

  test "a host never checked is unknown" do
    host = host_fixture()

    assert %{
             host_id: id,
             state: "unknown",
             reason: "never checked",
             counts: %{ok: 0, warn: 0, crit: 0, unknown: 0},
             items: [],
             checked_at: nil
           } = summary(host)

    assert id == to_string(host.id)
  end

  test "a disabled host is unknown even with an old row" do
    host = host_fixture()

    put_check(host, %{
      state: "drift",
      drift: [%{"user" => "a", "login" => "r", "missing" => ["x"], "extra" => []}]
    })

    {:ok, host} = Hosts.update_host(host, %{disabled: true})

    assert %{state: "unknown", reason: "host is disabled", items: []} = summary(host)
  end

  test "keys in sync is ok; counts are the logins" do
    host = host_fixture()
    put_check(host, %{logins: 3})

    assert %{
             state: "ok",
             reason: "keys in sync",
             counts: %{ok: 3, warn: 0, crit: 0, unknown: 0},
             items: [],
             checked_at: @checked
           } = summary(host)
  end

  test "drift is warn with one item per user and login, fingerprints only" do
    host = host_fixture()

    put_check(host, %{
      state: "drift",
      logins: 2,
      drift: [
        %{
          "user" => "alice",
          "login" => "deploy",
          "missing" => ["ssh-ed25519 SHA256:abc (laptop)"],
          "extra" => []
        },
        %{
          "user" => nil,
          "login" => "deploy",
          "missing" => [],
          "extra" => ["ssh-rsa SHA256:def (old)"]
        }
      ]
    })

    s = summary(host)
    assert s.state == "warn"
    assert s.reason == "key drift: 1 missing, 1 extra"
    assert s.counts == %{ok: 1, warn: 2, crit: 0, unknown: 0}

    assert [
             %{
               name: "alice@deploy",
               state: "warn",
               text: "missing: ssh-ed25519 SHA256:abc (laptop)",
               since: @changed
             },
             %{name: "unknown key@deploy", state: "warn", text: "extra: ssh-rsa SHA256:def (old)"}
           ] = s.items
  end

  test "an unreachable host or failed sync is crit" do
    host = host_fixture()

    put_check(host, %{
      state: "error",
      logins: 0,
      error_code: "connect_refused",
      error: "the host refused the SSH connection"
    })

    s = summary(host)
    assert s.state == "crit"
    assert s.reason == "unreachable or sync failed: the host refused the SSH connection"
    assert s.counts.crit == 1
    assert [%{name: "ssh", state: "crit", text: "the host refused the SSH connection"}] = s.items
  end

  test "updated_at is the later of the last result change and the host row" do
    host = host_fixture()
    put_check(host, %{changed_at: ~U[2000-01-01 00:00:00Z]})
    s = summary(host)
    assert DateTime.compare(s.updated_at, ~U[2000-01-01 00:00:00Z]) == :gt

    put_check(host, %{changed_at: ~U[2999-01-01 00:00:00Z]})
    assert summary(host).updated_at == ~U[2999-01-01 00:00:00Z]
  end

  test "get: unknown or malformed ids are not_found" do
    assert P.get_host_summary(@principal, "999999999") == {:error, :not_found}
    assert P.get_host_summary(@principal, "abc") == {:error, :not_found}
  end

  describe "list_host_summaries/2" do
    test "pages by host id and covers hosts without a row" do
      hosts = for _ <- 1..3, do: host_fixture()
      put_check(Enum.at(hosts, 1), %{})

      {:ok, [a, b], next} = P.list_host_summaries(@principal, page(%{}, 2))
      assert [a.host_id, b.host_id] == hosts |> Enum.take(2) |> Enum.map(&to_string(&1.id))
      assert [a.state, b.state] == ["unknown", "ok"]
      assert next == [Enum.at(hosts, 1).id]

      {:ok, [c], nil} = P.list_host_summaries(@principal, page(%{}, 2, next))
      assert c.host_id == to_string(List.last(hosts).id)
    end

    test "host_id filter" do
      a = host_fixture()
      _b = host_fixture()

      assert {:ok, [%{host_id: id}], nil} =
               P.list_host_summaries(@principal, page(%{"host_id" => to_string(a.id)}))

      assert id == to_string(a.id)
      assert {:ok, [], nil} = P.list_host_summaries(@principal, page(%{"host_id" => "abc"}))
    end

    test "changed_after sees a new result as well as a host edit" do
      old = host_fixture()
      Repo.update_all(Ssm.Hosts.Host, set: [updated_at: ~U[2026-11-01 00:00:00Z]])
      cutoff = ~U[2026-11-05 00:00:00Z]

      assert {:ok, [], nil} =
               P.list_host_summaries(@principal, page(%{"changed_after" => cutoff}))

      put_check(old, %{changed_at: ~U[2026-11-06 00:00:00Z]})

      assert {:ok, [%{host_id: id}], nil} =
               P.list_host_summaries(@principal, page(%{"changed_after" => cutoff}))

      assert id == to_string(old.id)

      edited = host_fixture()

      assert {:ok, list, nil} =
               P.list_host_summaries(@principal, page(%{"changed_after" => cutoff}))

      assert to_string(edited.id) in Enum.map(list, & &1.host_id)
    end

    test "the query count does not grow with the page" do
      for _ <- 1..2, do: put_check(host_fixture(), %{})
      small = count_queries(fn -> P.list_host_summaries(@principal, page()) end)
      for _ <- 1..8, do: put_check(host_fixture(), %{})
      assert count_queries(fn -> P.list_host_summaries(@principal, page()) end) == small
    end
  end

  defp count_queries(fun) do
    id = {__MODULE__, make_ref()}
    me = self()
    :telemetry.attach(id, [:ssm, :repo, :query], fn _, _, _, _ -> send(me, :q) end, nil)
    fun.()
    :telemetry.detach(id)
    drain(0)
  end

  defp drain(n) do
    receive do
      :q -> drain(n + 1)
    after
      0 -> n
    end
  end

  test "the provider advertises the host_summaries capability" do
    # section 10: delete_host and people; no maintenance (no alerts in ssm);
    # section 11: rename_group
    assert MctlContract.Capabilities.list(P) ==
             ["host_summaries", "delete_host", "people", "rename_group"]

    assert P.cursor_types("host_summaries") == [:integer]
  end
end
