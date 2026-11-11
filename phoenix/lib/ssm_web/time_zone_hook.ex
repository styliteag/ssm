defmodule SsmWeb.TimeZoneHook do
  @moduledoc """
  LiveView `on_mount` hook: assigns `:time_zone` — the LiveSocket connect
  param `tz` when connected, else the session's `tz` (`SsmWeb.TimeZonePlug`),
  else `SsmWeb.TimeZone.default/0`. An invalid value falls back silently.
  """

  import Phoenix.Component, only: [assign: 3]

  alias SsmWeb.TimeZone

  def on_mount(:default, _params, session, socket) do
    param = Phoenix.LiveView.get_connect_params(socket) |> param()
    {:cont, assign(socket, :time_zone, TimeZone.pick([param, session["tz"]]))}
  end

  defp param(%{"tz" => tz}), do: tz
  defp param(_not_connected), do: nil
end
