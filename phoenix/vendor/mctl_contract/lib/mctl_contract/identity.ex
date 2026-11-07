defmodule MctlContract.Identity do
  @moduledoc """
  Host identity helpers.

  `useful_macs/1` keeps only MACs that can identify a machine:
  dropped are locally administered addresses (bit `0x02` of the first
  octet: random, Docker, veth, most bridges), multicast and broadcast (bit
  `0x01`), VRRP/CARP virtual MACs (`00:00:5e:00:01:xx`,
  `00:00:5e:00:02:xx`) and the all-zero address. The result is
  normalised (lowercase, colon separated), unique and sorted.

  The cross-host rule (a MAC reported by more than two hosts is not
  useful) needs all hosts and belongs to mctl, not to a single tool.
  """
  import Bitwise

  @doc "Normalises a MAC to `aa:bb:cc:dd:ee:ff`: `{:ok, mac}` or `:error`."
  @spec normalize_mac(term()) :: {:ok, String.t()} | :error
  def normalize_mac(mac) when is_binary(mac) do
    mac
    |> String.trim()
    |> String.downcase()
    |> octets()
    |> case do
      {:ok, octets} -> {:ok, Enum.map_join(octets, ":", &hex/1)}
      :error -> :error
    end
  end

  def normalize_mac(_mac), do: :error

  @doc "The useful MACs of a list (see moduledoc)."
  @spec useful_macs([term()] | nil) :: [String.t()]
  def useful_macs(nil), do: []

  def useful_macs(macs) when is_list(macs) do
    macs
    |> Enum.flat_map(fn mac ->
      case normalize_mac(mac) do
        {:ok, mac} -> [mac]
        :error -> []
      end
    end)
    |> Enum.filter(&useful?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp useful?("00:00:00:00:00:00"), do: false
  defp useful?("00:00:5e:00:01:" <> _), do: false
  defp useful?("00:00:5e:00:02:" <> _), do: false

  defp useful?(mac) do
    {first, _} = mac |> binary_part(0, 2) |> Integer.parse(16)
    (first &&& 0x03) == 0
  end

  defp octets(s) do
    parts =
      cond do
        String.contains?(s, ":") -> String.split(s, ":")
        String.contains?(s, "-") -> String.split(s, "-")
        String.contains?(s, ".") -> s |> String.replace(".", "") |> pairs()
        true -> pairs(s)
      end

    parse_octets(parts)
  end

  defp pairs(s) when byte_size(s) == 12, do: for(<<a, b <- s>>, do: <<a, b>>)
  defp pairs(_s), do: []

  defp parse_octets(parts) when length(parts) == 6 do
    parts
    |> Enum.reduce_while([], fn part, acc ->
      case Integer.parse(part, 16) do
        {n, ""} when byte_size(part) in 1..2 and n in 0..255 -> {:cont, [n | acc]}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      acc -> {:ok, Enum.reverse(acc)}
    end
  end

  defp parse_octets(_parts), do: :error

  defp hex(n), do: n |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase()
end
