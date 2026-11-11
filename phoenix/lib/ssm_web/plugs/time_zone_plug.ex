defmodule SsmWeb.TimeZonePlug do
  @moduledoc """
  Copies the browser's `tz` cookie (written by `assets/js/app.js`, URI-encoded)
  into the session, so a LiveView's dead render knows the zone before the
  socket connects. An invalid cookie is ignored. See `SsmWeb.TimeZone`.
  """

  import Plug.Conn

  alias SsmWeb.TimeZone

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    case conn.cookies["tz"] |> decode() |> TimeZone.valid() do
      nil -> conn
      zone -> remember(conn, zone)
    end
  end

  # no session write (and no new Set-Cookie) when nothing changed
  defp remember(conn, zone) do
    if get_session(conn, "tz") == zone, do: conn, else: put_session(conn, "tz", zone)
  end

  defp decode(value) when is_binary(value) do
    URI.decode(value)
  rescue
    ArgumentError -> nil
  end

  defp decode(_value), do: nil
end
