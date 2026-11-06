defmodule SsmWeb.Plugs.TrustedProxies do
  @moduledoc """
  Real client IP behind a reverse proxy, without a dependency.

  `TRUSTED_PROXIES` (comma-separated addresses or CIDRs, read into
  `config :ssm, :trusted_proxies`) names the proxies in front of ssm. Only
  when a request comes from one of them, `X-Forwarded-For` is walked from
  the right, skipping trusted hops; the first untrusted address becomes
  `conn.remote_ip`. Unset (the default), the header is ignored — a client
  cannot spoof its address. A malformed entry stops the walk at the last
  trusted hop.

  Used for the mctl token's `last_used_ip` and the per-IP limit of failed
  `/api/mctl/v1` authentication.
  """

  @behaviour Plug

  import Bitwise

  require Logger

  @impl true
  def init(opts), do: opts

  @warned {__MODULE__, :warned}

  @impl true
  def call(conn, _opts) do
    case trusted() do
      [] -> maybe_warn(conn)
      cidrs -> %{conn | remote_ip: client_ip(conn, cidrs)}
    end
  end

  # A forwarded request without TRUSTED_PROXIES: per-IP limits and
  # last_used_ip see the proxy, not the client. Say so once per boot.
  defp maybe_warn(conn) do
    if Plug.Conn.get_req_header(conn, "x-forwarded-for") != [] and
         not :persistent_term.get(@warned, false) do
      :persistent_term.put(@warned, true)

      Logger.warning(
        "X-Forwarded-For received but TRUSTED_PROXIES is unset: client IPs are the " <>
          "proxy's (mctl token last-use IP, failed-auth limit). Set TRUSTED_PROXIES " <>
          "to the proxy's address/CIDR."
      )
    end

    conn
  end

  @doc false
  def reset_warning, do: :persistent_term.erase(@warned)

  defp trusted do
    case Application.get_env(:ssm, :trusted_proxies, []) do
      value when is_binary(value) -> parse_cidrs(value)
      list when is_list(list) -> Enum.flat_map(list, &parse_cidrs/1)
    end
  end

  defp client_ip(conn, cidrs) do
    if trusted?(conn.remote_ip, cidrs) do
      conn
      |> Plug.Conn.get_req_header("x-forwarded-for")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> walk(conn.remote_ip, cidrs)
    else
      conn.remote_ip
    end
  end

  defp walk([], last, _cidrs), do: last

  defp walk([entry | rest], last, cidrs) do
    case :inet.parse_strict_address(String.to_charlist(entry)) do
      {:ok, ip} -> if trusted?(ip, cidrs), do: walk(rest, ip, cidrs), else: ip
      {:error, _} -> last
    end
  end

  defp trusted?(ip, cidrs), do: Enum.any?(cidrs, &in_cidr?(ip, &1))

  defp in_cidr?(ip, {net, bits}) when tuple_size(ip) == tuple_size(net) do
    width = if tuple_size(ip) == 4, do: 8, else: 16
    size = tuple_size(ip) * width
    mask = bnot((1 <<< (size - bits)) - 1) &&& (1 <<< size) - 1
    (to_int(ip, width) &&& mask) == (to_int(net, width) &&& mask)
  end

  defp in_cidr?(_ip, _cidr), do: false

  defp to_int(ip, width) do
    ip |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< width) + part end)
  end

  @doc "Parse `\"10.0.0.0/8, 192.168.1.1, fd00::/8\"`; invalid entries are dropped."
  @spec parse_cidrs(String.t()) :: [{:inet.ip_address(), non_neg_integer()}]
  def parse_cidrs(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(&parse_cidr/1)
  end

  defp parse_cidr(entry) do
    {address, bits} =
      case String.split(entry, "/", parts: 2) do
        [address, bits] -> {address, Integer.parse(bits)}
        [address] -> {address, :full}
      end

    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(address)),
         max = tuple_size(ip) * if(tuple_size(ip) == 4, do: 8, else: 16),
         {:ok, bits} <- prefix(bits, max) do
      [{ip, bits}]
    else
      _ -> []
    end
  end

  defp prefix(:full, max), do: {:ok, max}
  defp prefix({bits, ""}, max) when bits >= 0 and bits <= max, do: {:ok, bits}
  defp prefix(_, _max), do: :error
end
