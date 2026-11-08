defmodule Ssm.Ssh.Target do
  @moduledoc """
  Everything needed to open one SSH session — port of `SshTarget` in
  backend/src/ssm/ssh/protocol.py. `jump_target` nests another target when
  the host is reached via a jump host; chains recurse.

  `host_key_fingerprint` / `host_key` carry the host's pinned identity
  (ADR-0008, see `Ssm.Ssh.HostKey`); every connect verifies against them.
  """

  @enforce_keys [:host_id, :name, :address, :port, :username]
  defstruct [
    :host_id,
    :name,
    :address,
    :port,
    :username,
    :jump_target,
    :host_key_fingerprint,
    :host_key
  ]

  @type t :: %__MODULE__{
          host_id: integer(),
          name: String.t(),
          address: String.t(),
          port: :inet.port_number(),
          username: String.t(),
          jump_target: t() | nil,
          host_key_fingerprint: String.t() | nil,
          host_key: String.t() | nil
        }

  @max_hops 16

  @doc "Longest jump chain (hosts in front of the target) that is followed."
  @spec max_hops() :: pos_integer()
  def max_hops, do: @max_hops

  @doc """
  Build a target (and its jump chain) from `Ssm.Hosts.Host` structs.
  Defensive against stored data the write side refuses today: the chain
  stops at a host already in it (a `jump_via` loop) and after
  `max_hops/0` jump hosts, so it always terminates.
  """
  @spec from_host(struct(), (integer() -> struct() | nil)) :: t()
  def from_host(host, fetch_host), do: build(host, fetch_host, MapSet.new([host.id]), 0)

  defp build(host, fetch_host, seen, hops) do
    jump =
      with jump_id when not is_nil(jump_id) <- host.jump_via,
           false <- MapSet.member?(seen, jump_id) or hops >= @max_hops,
           %{} = jump_host <- fetch_host.(jump_id) do
        build(jump_host, fetch_host, MapSet.put(seen, jump_id), hops + 1)
      else
        _ -> nil
      end

    %__MODULE__{
      host_id: host.id,
      name: host.name,
      address: host.address,
      port: host.port,
      username: host.username,
      jump_target: jump,
      host_key_fingerprint: Map.get(host, :key_fingerprint),
      host_key: Map.get(host, :host_key)
    }
  end
end
