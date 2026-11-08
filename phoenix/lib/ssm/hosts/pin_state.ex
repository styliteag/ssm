defmodule Ssm.Hosts.PinState do
  @moduledoc """
  Pure: how far a host's SSH host key is pinned (ADR-0008), for display.

    * `:unpinned` – no `key_fingerprint`; every connect is refused until
      the key is pinned ("Pin host keys")
    * `:preseeded` – a fingerprint (entered by an operator, or a legacy
      bare hash) but no `host_key` yet: not confirmed by a connection; the
      next pin (`Ssm.Hosts.HostKeys.pin/2`) fills the key only if the host
      presents a matching one
    * `:confirmed` – fingerprint and public key, stored from a probe

  The states are read from the row only; `Ssm.Hosts.HostKeys` alone
  changes them.
  """

  alias Ssm.Hosts.Host
  alias Ssm.Ssh.HostKey

  @type t :: :unpinned | :preseeded | :confirmed

  @spec of(Host.t()) :: t()
  def of(%Host{key_fingerprint: fingerprint, host_key: key}) do
    cond do
      not HostKey.pinned?(fingerprint) -> :unpinned
      is_binary(key) and String.trim(key) != "" -> :confirmed
      true -> :preseeded
    end
  end

  @doc "Tooltip text for the state of `host`."
  @spec title(Host.t()) :: String.t()
  def title(%Host{} = host) do
    case of(host) do
      :unpinned ->
        "No host key pinned: ssm refuses to connect until it is pinned (Pin host keys)"

      :preseeded ->
        "Host key fingerprint set but not confirmed by a connection yet: " <>
          host.key_fingerprint

      :confirmed ->
        "Host key pinned and confirmed by a connection: " <> host.key_fingerprint
    end
  end
end
