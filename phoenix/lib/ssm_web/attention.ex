defmodule SsmWeb.Attention do
  @moduledoc """
  The dashboard's "Needs attention" list: what an operator should act on,
  from the host states (`Ssm.HostStatus`), the revocation-pending marks and
  the host-key pins. Pure: callers pass hosts, statuses and marks. Disabled
  hosts are left out (ssm never touches them).
  """

  alias Ssm.Hosts.PinState

  @type item :: %{
          id: String.t(),
          count: pos_integer(),
          title: String.t(),
          hint: String.t(),
          path: String.t(),
          tone: :warning | :error
        }

  @doc "Items with a count above zero, most urgent first."
  @spec items([Ssm.Hosts.Host.t()], %{integer() => term()}, map()) :: [item()]
  def items(hosts, statuses, pending) do
    enabled = Enum.reject(hosts, & &1.disabled)
    count = fn fun -> Enum.count(enabled, fun) end

    [
      {"host-key", count.(&match?({:host_key_changed, _}, statuses[&1.id])), "Host key changed",
       "check the host before trusting the new key", "/diff?filter=other", :error},
      {"auth", count.(&match?({:auth_failed, _}, statuses[&1.id])), "Key not accepted",
       "the host refuses ssm's key", "/diff?filter=auth", :error},
      {"pending", count.(&Map.has_key?(pending, &1.id)), "Pending sync",
       "keys that lost access stay until the next sync", "/hosts?filter=pending", :warning},
      {"drift", count.(&match?({:drift, _, _}, statuses[&1.id])), "Needs sync",
       "the host differs from the database", "/diff?filter=needs_sync", :warning},
      {"unreachable", count.(&match?({:unreachable, _}, statuses[&1.id])), "Unreachable",
       "at the last check", "/diff?filter=unreachable", :warning},
      {"unpinned", count.(&(PinState.of(&1) == :unpinned)), "No pinned host key",
       "ssm refuses to connect until the key is pinned", "/hosts", :warning}
    ]
    |> Enum.filter(fn {_id, n, _title, _hint, _path, _tone} -> n > 0 end)
    |> Enum.map(fn {id, n, title, hint, path, tone} ->
      %{id: id, count: n, title: title, hint: hint, path: path, tone: tone}
    end)
  end
end
