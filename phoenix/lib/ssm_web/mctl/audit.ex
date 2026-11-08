defmodule SsmWeb.Mctl.Audit do
  @moduledoc """
  Activity-log entries for mctl writes: actor `mctl:<token name>`, the
  client IP (`principal.ip`) in the details.
  """

  alias Ssm.Activity

  @doc "The activity-log actor of a principal."
  def actor(principal), do: "mctl:#{principal.name}"

  @doc """
  Log a customer action (`merge`) as type `host` (it moves hosts; the
  activity log knows no customer type): action `customer_<action>`, target
  `customer:<slug>`.
  """
  def customer(principal, action, slug, details \\ %{}) do
    Activity.log(%{
      activity_type: "host",
      action: "customer_" <> action,
      target: "customer:" <> slug,
      actor_username: actor(principal),
      details: Map.merge(%{via: "mctl", ip: principal.ip}, details)
    })
  end

  @doc "Log a group action (`delete`)."
  def group(principal, action, slug, details \\ %{}) do
    Activity.log(%{
      activity_type: "host",
      action: "group_" <> action,
      target: "group:" <> slug,
      actor_username: actor(principal),
      details: Map.merge(%{via: "mctl", ip: principal.ip}, details)
    })
  end

  @doc """
  Log an SSH probe (`probe_ssh`) as type `host`, action `probe_ssh`, target
  the probed address: ports, the jump host, and which ports answered SSH
  (banners are not stored), or `refused` for a target ssm does not probe.
  """
  def probe(principal, address, ports, via, results) do
    outcome =
      case results do
        :refused ->
          %{refused: true}

        list ->
          %{
            ssh_ports: for(r <- list, r.banner, do: r.port),
            open_ports: for(r <- list, r.open, do: r.port)
          }
      end

    Activity.log(%{
      activity_type: "host",
      action: "probe_ssh",
      target: address,
      actor_username: actor(principal),
      details: Map.merge(%{ports: ports, jump_via: via, via: "mctl", ip: principal.ip}, outcome)
    })
  end

  @doc "Log a host action (`create`, `update`, `create_rolled_back`)."
  def host(principal, action, host, details \\ %{}) do
    Activity.log(%{
      activity_type: "host",
      action: action,
      target: host.name,
      host_id: host.id,
      actor_username: actor(principal),
      details:
        Map.merge(
          %{address: host.address, port: host.port, via: "mctl", ip: principal.ip},
          details
        )
    })
  end
end
