defmodule Ssm.Ssh.Probe do
  @moduledoc """
  Narrow SSH reachability probe for mctl (`probe_ssh`, mctl_contract 0.5.0):
  can ssm reach `address:port`, and does an SSH server answer there?

  Per port it opens a TCP connection (short timeout), reads the first line
  (at most #{255} bytes) and never sends anything; no login, no handshake.
  `open` means the TCP connection was accepted; `banner` is that first line
  when it starts with `SSH-`.

  Directly (no jump host) the address is resolved like the SSH client does
  (`Ssm.Ssh.ErlangClient.connect_attempts/1`: an IPv4/IPv6 literal as is, a
  DNS name over IPv4, then IPv6). Every resolved address is checked first:
  loopback, link-local, unspecified and multicast targets and ssm's own
  interface addresses are refused, so the probe cannot be pointed at ssm's
  own services. Tests may allow loopback (`config :ssm, :probe_allow_loopback`).

  Through a jump host the jump host connects (`ssh -W`, see
  `Ssm.Ssh.ErlangClient.banner_via/4`); a DNS name is then resolved by the
  jump host, an address literal is checked against the same ranges.
  """

  alias Ssm.Ssh.Target

  @connect_ms 3_000
  @read_ms 2_000
  @max_line 255

  @type result :: %{
          port: pos_integer(),
          open: boolean(),
          banner: String.t() | nil,
          error: String.t() | nil
        }

  @doc """
  Probe `ports` on `address`, directly or through the jump `Target`.
  `{:ok, results}` (one per port, in order) or
  `{:error, {:validation, %{"address" => [reason]}}}` for a refused target.
  """
  @spec run(String.t(), [pos_integer()], Target.t() | nil) ::
          {:ok, [result()]} | {:error, {:validation, map()}}
  def run(address, ports, jump \\ nil)

  def run(address, ports, nil) do
    with {:ok, ips} <- resolve(address),
         :ok <- allowed(ips) do
      {:ok, Enum.map(ports, &probe_port(ips, &1))}
    end
  end

  def run(address, ports, %Target{} = jump) do
    with :ok <- literal_allowed(address) do
      client = Application.get_env(:ssm, :probe_jump_client, Ssm.Ssh.ErlangClient)
      {:ok, Enum.map(ports, &via_jump(client, jump, address, &1))}
    end
  end

  ## Resolution and the refused ranges

  @doc false
  @spec resolve(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, {:validation, map()}}
  def resolve(address) do
    charlist = String.to_charlist(address)

    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        {:ok, [ip]}

      {:error, _} ->
        ips = lookup(charlist, :inet) ++ lookup(charlist, :inet6)
        if ips == [], do: refused("does not resolve"), else: {:ok, ips}
    end
  end

  defp lookup(charlist, family) do
    case :inet.getaddrs(charlist, family, @connect_ms) do
      {:ok, ips} -> ips
      {:error, _} -> []
    end
  end

  defp allowed(ips) do
    case Enum.find(ips, &blocked?/1) do
      nil -> :ok
      ip -> refused("#{:inet.ntoa(ip)} is not a probe target (#{blocked_reason(ip)})")
    end
  end

  defp literal_allowed(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, ip} -> allowed([ip])
      {:error, _} -> :ok
    end
  end

  @doc false
  @spec blocked?(:inet.ip_address()) :: boolean()
  def blocked?(ip), do: blocked_reason(ip) != nil

  defp blocked_reason(ip) do
    cond do
      loopback?(ip) and not allow_loopback?() -> "loopback"
      loopback?(ip) -> nil
      unspecified?(ip) -> "unspecified"
      link_local?(ip) -> "link-local"
      multicast?(ip) -> "multicast"
      ip in own_addresses() -> "ssm's own address"
      true -> nil
    end
  end

  defp allow_loopback?, do: Application.get_env(:ssm, :probe_allow_loopback, false)

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, a, _}), do: div(a, 256) == 127
  defp loopback?(_), do: false

  defp unspecified?({0, 0, 0, 0}), do: true
  defp unspecified?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp unspecified?(_), do: false

  defp link_local?({169, 254, _, _}), do: true
  defp link_local?({a, _, _, _, _, _, _, _}), do: Bitwise.band(a, 0xFFC0) == 0xFE80
  defp link_local?(_), do: false

  defp multicast?({a, _, _, _}), do: a in 224..239
  defp multicast?({a, _, _, _, _, _, _, _}), do: Bitwise.band(a, 0xFF00) == 0xFF00
  defp multicast?(_), do: false

  defp own_addresses do
    case :inet.getifaddrs() do
      {:ok, ifs} -> for {_name, opts} <- ifs, {:addr, ip} <- opts, do: ip
      _ -> []
    end
  end

  defp refused(reason), do: {:error, {:validation, %{"address" => [reason]}}}

  ## Direct probe

  defp probe_port(ips, port) do
    Enum.reduce_while(ips, closed(port, "no address answered"), fn ip, acc ->
      case :gen_tcp.connect(ip, port, [:binary, active: false], @connect_ms) do
        {:ok, socket} ->
          line = read_line(socket, "")
          :gen_tcp.close(socket)
          {:halt, from_line(port, line)}

        {:error, reason} ->
          {:cont, %{acc | error: describe(reason)}}
      end
    end)
  end

  defp read_line(socket, acc) do
    case :gen_tcp.recv(socket, 0, @read_ms) do
      {:ok, data} ->
        acc = acc <> data

        if String.contains?(acc, "\n") or byte_size(acc) >= @max_line,
          do: acc,
          else: read_line(socket, acc)

      {:error, _} ->
        acc
    end
  end

  @doc false
  @spec from_line(pos_integer(), binary()) :: result()
  def from_line(port, data) do
    line =
      data
      |> binary_part(0, min(byte_size(data), @max_line))
      |> String.split("\n", parts: 2)
      |> hd()
      |> String.trim_trailing("\r")

    if String.starts_with?(line, "SSH-") and String.valid?(line),
      do: %{port: port, open: true, banner: line, error: nil},
      else: %{port: port, open: true, banner: nil, error: "no SSH banner"}
  end

  defp closed(port, error), do: %{port: port, open: false, banner: nil, error: error}

  defp describe(:econnrefused), do: "connection refused"
  defp describe(:timeout), do: "no answer within #{div(@connect_ms, 1000)} s"
  defp describe(:ehostunreach), do: "host unreachable"
  defp describe(:enetunreach), do: "network unreachable"
  defp describe(reason), do: inspect(reason)

  ## Through a jump host

  defp via_jump(client, jump, address, port) do
    case client.banner_via(jump, address, port, @connect_ms + @read_ms) do
      {:ok, data} -> from_line(port, data)
      {:error, reason} -> closed(port, reason)
    end
  end
end
