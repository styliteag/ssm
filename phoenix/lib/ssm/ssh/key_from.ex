defmodule Ssm.Ssh.KeyFrom do
  @moduledoc """
  `SSM_KEY_FROM`: the networks ssm connects from (its own address and the
  inner addresses of the jump hosts), as IPs or CIDRs. When set, a sync
  writes ssm's own key line with `from="<list>"`, so a stolen ssm key is of
  no use elsewhere. The same list goes to every host.

  Lockout guard: before writing, ssm asks the host which address it sees
  (`$SSH_CONNECTION`). If that address is not in the list, the own key is
  written without `from=` and a warning is logged — a sync never locks ssm
  out. To move a host to a jump host in a new network, add the network
  first, sync, then switch.
  """

  require Logger

  @type list_t :: [String.t()]

  @doc "The configured list (`config :ssm, :key_from`)."
  @spec list() :: list_t()
  def list, do: Application.get_env(:ssm, :key_from, [])

  @doc "Parses a comma-separated list; `{:error, entry}` names the first bad one."
  @spec parse(String.t() | nil) :: {:ok, list_t()} | {:error, String.t()}
  def parse(nil), do: {:ok, []}

  def parse(text) when is_binary(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case network(entry) do
        {:ok, _} -> {:cont, {:ok, acc ++ [entry]}}
        :error -> {:halt, {:error, entry}}
      end
    end)
  end

  @doc "The `from=` option for `list` (nil when empty)."
  @spec option(list_t()) :: String.t() | nil
  def option([]), do: nil
  def option(list), do: ~s(from="#{Enum.join(list, ",")}")

  @doc "Whether `address` (as the host sees ssm) lies in one of `list`."
  @spec allowed?(list_t(), String.t() | nil) :: boolean()
  def allowed?(list, address) when is_binary(address) do
    case :inet.parse_strict_address(String.to_charlist(String.trim(address))) do
      {:ok, ip} -> Enum.any?(list, &in_network?(ip, &1))
      {:error, _} -> false
    end
  end

  def allowed?(_list, _address), do: false

  @doc """
  The `from=` option for a host that sees ssm at `address`: the option when
  the address is covered, else nil (and a warning) — never a lockout.
  """
  @spec option_for(list_t(), String.t() | nil, String.t()) :: String.t() | nil
  def option_for([], _address, _host_name), do: nil

  def option_for(list, address, host_name) do
    if allowed?(list, address) do
      option(list)
    else
      Logger.warning(
        "ssm key from=: #{host_name} sees ssm at #{inspect(address)}, not in SSM_KEY_FROM; " <>
          "own key written without from= (add that network to SSM_KEY_FROM)"
      )

      nil
    end
  end

  defp in_network?(ip, entry) do
    case network(entry) do
      {:ok, {net, bits}} ->
        tuple_size(ip) == tuple_size(net) and prefix(ip, bits) == prefix(net, bits)

      :error ->
        false
    end
  end

  defp prefix(ip, bits) do
    size = if tuple_size(ip) == 4, do: 8, else: 16

    <<head::bitstring-size(^bits), _::bitstring>> =
      for part <- Tuple.to_list(ip), into: <<>>, do: <<part::size(size)>>

    head
  end

  defp network(entry) do
    {addr, bits} =
      case String.split(entry, "/", parts: 2) do
        [addr, bits] -> {addr, Integer.parse(bits)}
        [addr] -> {addr, :host}
      end

    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(addr)),
         max = if(tuple_size(ip) == 4, do: 32, else: 128),
         {:ok, n} <- bits(bits, max) do
      {:ok, {ip, n}}
    else
      _ -> :error
    end
  end

  defp bits(:host, max), do: {:ok, max}
  defp bits({n, ""}, max) when n >= 0 and n <= max, do: {:ok, n}
  defp bits(_other, _max), do: :error
end
