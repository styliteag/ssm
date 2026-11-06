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
        "comment" => host.comment,
        "limited" => Ssm.Hosts.limited?(host),
        "limited_reason" => Ssm.Hosts.limited_reason(host)
      }
    }
  end

  defp identity(host) do
    keys = ssh_host_keys(host)

    %{
      machine_id: host.machine_id,
      product_uuid: nil,
      macs: [],
      ssh_host_keys: keys,
      observed_at: if(keys != [], do: host.host_key_observed_at)
    }
  end

  # identity-claims-v1 §1: `<type> SHA256:<unpadded base64>`. A bare legacy
  # pin has no type; it is reported only when the stored public key gives it
  # one, never as a typeless claim.
  defp ssh_host_keys(%Host{key_fingerprint: pin, host_key: key}) do
    cond do
      not HostKey.pinned?(pin) -> []
      typed?(pin) -> [pin]
      is_binary(key) -> from_public_key(key)
      true -> []
    end
  end

  defp typed?(pin), do: match?([_type, _hash], String.split(pin, " "))

  defp from_public_key(key) do
    case HostKey.fingerprint(key) do
      {:ok, fingerprint} -> [fingerprint]
      {:error, _} -> []
    end
  end
end
