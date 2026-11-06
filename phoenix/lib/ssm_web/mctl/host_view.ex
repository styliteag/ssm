defmodule SsmWeb.Mctl.HostView do
  @moduledoc """
  An ssm host (membership preloaded) as a contract `Host` map. ssm reaches
  hosts over SSH, so `mode` is always `pull`; it cannot tell the OS, so
  `kind` is `other`. The pinned host key (ADR-0008) is the identity claim.
  """

  alias Ssm.Hosts.Host
  alias Ssm.Ssh.HostKey

  @spec render(Host.t()) :: map()
  def render(%Host{} = host) do
    %{
      id: to_string(host.id),
      name: host.name,
      addresses: [host.address],
      mode: "pull",
      kind: "other",
      customer: host.customer && host.customer.slug,
      groups: host.groups |> Enum.map(& &1.slug) |> Enum.sort(),
      ui_url: SsmWeb.Endpoint.url() <> "/diff?host_id=#{host.id}",
      updated_at: host.updated_at,
      identity: identity(host),
      attributes: %{
        "username" => host.username,
        "port" => host.port,
        "jump_via" => host.jump_via && to_string(host.jump_via),
        "disabled" => host.disabled,
        "comment" => host.comment
      }
    }
  end

  defp identity(host) do
    pinned? = HostKey.pinned?(host.key_fingerprint)

    %{
      machine_id: nil,
      product_uuid: nil,
      macs: [],
      ssh_host_keys: if(pinned?, do: [host.key_fingerprint], else: []),
      observed_at: if(pinned?, do: host.host_key_observed_at)
    }
  end
end
