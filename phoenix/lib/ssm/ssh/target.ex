defmodule Ssm.Ssh.Target do
  @moduledoc """
  Everything needed to open one SSH session — port of `SshTarget` in
  backend/src/ssm/ssh/protocol.py. `jump_target` nests another target when
  the host is reached via a jump host; chains recurse.
  """

  @enforce_keys [:host_id, :name, :address, :port, :username]
  defstruct [:host_id, :name, :address, :port, :username, :jump_target]

  @type t :: %__MODULE__{
          host_id: integer(),
          name: String.t(),
          address: String.t(),
          port: :inet.port_number(),
          username: String.t(),
          jump_target: t() | nil
        }

  @doc "Build a target (and its jump chain) from `Ssm.Hosts.Host` structs."
  @spec from_host(struct(), (integer() -> struct() | nil)) :: t()
  def from_host(host, fetch_host) do
    jump =
      case host.jump_via do
        nil ->
          nil

        jump_id ->
          case fetch_host.(jump_id) do
            nil -> nil
            jump_host -> from_host(jump_host, fetch_host)
          end
      end

    %__MODULE__{
      host_id: host.id,
      name: host.name,
      address: host.address,
      port: host.port,
      username: host.username,
      jump_target: jump
    }
  end
end
