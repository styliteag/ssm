defmodule SsmWeb.Mctl.Audit do
  @moduledoc """
  Activity-log entries for mctl writes: actor `mctl:<token name>`, the
  client IP (`principal.ip`) in the details.
  """

  alias Ssm.Activity

  @doc "The activity-log actor of a principal."
  def actor(principal), do: "mctl:#{principal.name}"

  @doc "Log a host action (`create`, `update`, `create_rolled_back`)."
  def host(principal, action, host, details \\ %{}) do
    Activity.log(%{
      activity_type: "host",
      action: action,
      target: host.name,
      actor_username: actor(principal),
      details:
        Map.merge(
          %{address: host.address, port: host.port, via: "mctl", ip: principal.ip},
          details
        )
    })
  end
end
