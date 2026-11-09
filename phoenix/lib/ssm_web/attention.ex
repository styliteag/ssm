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
          text: String.t(),
          path: String.t(),
          tone: :warning | :error
        }

  @doc "Items with a count above zero, most urgent first."
  @spec items([Ssm.Hosts.Host.t()], %{integer() => term()}, map()) :: [item()]
  def items(hosts, statuses, pending) do
    enabled = Enum.reject(hosts, & &1.disabled)
    count = fn fun -> Enum.count(enabled, fun) end

    [
      {"host-key", count.(&match?({:host_key_changed, _}, statuses[&1.id])),
       "presented a different host key — check before trusting it", "/diff?filter=other", :error},
      {"auth", count.(&match?({:auth_failed, _}, statuses[&1.id])), "do not accept ssm's key",
       "/diff?filter=auth", :error},
      {"pending", count.(&Map.has_key?(pending, &1.id)),
       "keep keys that lost access until their next sync", "/hosts?filter=pending", :warning},
      {"drift", count.(&match?({:drift, _, _}, statuses[&1.id])), "need a sync",
       "/diff?filter=needs_sync", :warning},
      {"unreachable", count.(&match?({:unreachable, _}, statuses[&1.id])),
       "could not be reached at the last check", "/diff?filter=unreachable", :warning},
      {"unpinned", count.(&(PinState.of(&1) == :unpinned)),
       "have no pinned SSH host key; ssm refuses to connect", "/hosts", :warning}
    ]
    |> Enum.filter(fn {_id, n, _text, _path, _tone} -> n > 0 end)
    |> Enum.map(fn {id, n, text, path, tone} ->
      %{id: id, count: n, text: text, path: path, tone: tone}
    end)
  end
end
