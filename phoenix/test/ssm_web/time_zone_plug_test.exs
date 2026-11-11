defmodule SsmWeb.TimeZonePlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias SsmWeb.TimeZonePlug

  defp run(cookie) do
    conn(:get, "/")
    |> init_test_session(%{})
    |> put_req_header("cookie", "tz=" <> cookie)
    |> TimeZonePlug.call([])
  end

  test "the URI-encoded cookie lands in the session" do
    assert get_session(run("Europe%2FBerlin"), "tz") == "Europe/Berlin"
    assert get_session(run("America%2FNew_York"), "tz") == "America/New_York"
  end

  test "an invalid or malformed cookie is ignored" do
    for bad <- ["Mars%2FOlympus", "%E0%A4%A", "", String.duplicate("a", 200)] do
      assert get_session(run(bad), "tz") == nil
    end
  end
end
