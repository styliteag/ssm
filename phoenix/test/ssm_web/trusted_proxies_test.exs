defmodule SsmWeb.TrustedProxiesTest do
  use SsmWeb.ConnCase, async: false

  alias SsmWeb.Plugs.TrustedProxies

  setup do
    previous = Application.get_env(:ssm, :trusted_proxies)
    on_exit(fn -> Application.put_env(:ssm, :trusted_proxies, previous || []) end)
    :ok
  end

  defp call(remote_ip, xff, proxies) do
    Application.put_env(:ssm, :trusted_proxies, proxies)

    %{build_conn() | remote_ip: remote_ip}
    |> then(&if(xff, do: put_req_header(&1, "x-forwarded-for", xff), else: &1))
    |> TrustedProxies.call(TrustedProxies.init([]))
  end

  test "no trusted proxies configured: X-Forwarded-For is ignored, with one warning" do
    TrustedProxies.reset_warning()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert call({192, 168, 1, 10}, "203.0.113.7", []).remote_ip == {192, 168, 1, 10}
        assert call({192, 168, 1, 10}, "203.0.113.8", []).remote_ip == {192, 168, 1, 10}
      end)

    assert log =~ "TRUSTED_PROXIES is unset"
    assert length(String.split(log, "X-Forwarded-For received")) == 2
  end

  test "no X-Forwarded-For: no warning" do
    TrustedProxies.reset_warning()
    log = ExUnit.CaptureLog.capture_log(fn -> call({192, 168, 1, 10}, nil, []) end)
    refute log =~ "TRUSTED_PROXIES"
  end

  test "request from a trusted proxy: rightmost untrusted X-Forwarded-For entry wins" do
    conn = call({172, 18, 0, 2}, "198.51.100.1, 203.0.113.7, 172.18.0.5", ["172.18.0.0/16"])
    assert conn.remote_ip == {203, 0, 113, 7}
  end

  test "request NOT from a trusted proxy: header is ignored (no spoofing)" do
    assert call({198, 51, 100, 9}, "10.0.0.1", ["172.18.0.0/16"]).remote_ip ==
             {198, 51, 100, 9}
  end

  test "garbage entries stop the walk; remote_ip stays the proxy" do
    assert call({172, 18, 0, 2}, "not-an-ip", ["172.18.0.0/16"]).remote_ip == {172, 18, 0, 2}
  end

  test "IPv6 and single addresses" do
    assert call({0, 0, 0, 0, 0, 0, 0, 1}, "2001:db8::7", ["::1"]).remote_ip ==
             {8193, 3512, 0, 0, 0, 0, 0, 7}
  end

  test "parse_cidrs/1 reads the TRUSTED_PROXIES format and drops junk" do
    assert TrustedProxies.parse_cidrs("10.0.0.0/8, 192.168.1.1 ,fd00::/8,junk,10.0.0.0/99") ==
             [{{10, 0, 0, 0}, 8}, {{192, 168, 1, 1}, 32}, {{64768, 0, 0, 0, 0, 0, 0, 0}, 8}]
  end

  test "last_used_ip of an mctl token is the client behind the trusted proxy" do
    {:ok, _t, plain} = MctlContract.Tokens.Ecto.create("proxy-test", ["read"], prefix: "ssm_")
    Application.put_env(:ssm, :trusted_proxies, ["172.18.0.0/16"])

    %{build_conn() | remote_ip: {172, 18, 0, 2}}
    |> put_req_header("x-forwarded-for", "203.0.113.7")
    |> put_req_header("authorization", "Bearer " <> plain)
    |> get("/api/mctl/v1/me")
    |> json_response(200)

    [token] = MctlContract.Tokens.Ecto.list()
    assert token.last_used_ip == "203.0.113.7"
  end
end
