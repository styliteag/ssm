defmodule Ssm.Hosts.MachineId do
  @moduledoc """
  identity-claims-v1 §1/§2: learn a host's machine-id claim over SSH.

  A fixed command (no user input) prints the raw id — `/etc/machine-id` on
  Linux, `sysctl -n kern.hostuuid` on FreeBSD. ssm derives
  `hex(HMAC-SHA256(key = raw id, msg = "stylite-orbit-identity-v1"))` and
  stores only that; the raw id is never logged, stored or returned. Any
  failure (disabled host, SSH error, odd output) keeps the stored value.
  """

  require Logger

  alias Ssm.Hosts
  alias Ssm.Hosts.Host
  alias Ssm.Repo
  alias Ssm.Ssh.Result

  # Never change: every cross-tool match breaks (dashboard agent, omon).
  @context "stylite-orbit-identity-v1"

  @command "if [ \"$(uname -s)\" = FreeBSD ]; then sysctl -n kern.hostuuid; " <>
             "else cat /etc/machine-id; fi"

  @max_raw_bytes 256

  @doc "The fixed remote command."
  @spec command() :: String.t()
  def command, do: @command

  @doc "`hex(HMAC-SHA256(raw id, context))` of a raw id (trimmed)."
  @spec derive(String.t()) :: String.t()
  def derive(raw) when is_binary(raw) do
    :crypto.mac(:hmac, :sha256, String.trim(raw), @context) |> Base.encode16(case: :lower)
  end

  @doc """
  Learn and store the machine-id HMAC. Always returns the host (updated on
  success, unchanged otherwise) — callers never branch on failure.
  Options: `:client` (default `Ssm.Ssh`).
  """
  @spec refresh(Host.t(), keyword()) :: Host.t()
  def refresh(%Host{disabled: true} = host, _opts), do: host

  def refresh(%Host{} = host, opts) do
    client = Keyword.get(opts, :client, Ssm.Ssh)

    with {:ok, %Result{exit_code: 0, stdout: out}} <-
           client.exec(Hosts.target_for(host), @command, []),
         {:ok, raw} <- clean(out) do
      store(host, derive(raw))
    else
      other ->
        Logger.warning("machine_id: not learned for host #{host.id} (#{reason(other)})")
        host
    end
  end

  defp store(%Host{machine_id: same} = host, same), do: host

  defp store(host, machine_id) do
    case host |> Host.machine_id_changeset(machine_id) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, _} -> host
    end
  end

  defp clean(out) when is_binary(out) do
    raw = String.trim(out)

    if raw != "" and byte_size(raw) <= @max_raw_bytes and String.printable?(raw),
      do: {:ok, raw},
      else: :invalid
  end

  # Reasons only — remote output may contain the raw id, so it is never echoed.
  defp reason({:ok, %Result{exit_code: code}}) when code != 0, do: "exit #{code}"
  defp reason({:error, {:ssh_connect_failed, _}}), do: "ssh failed"
  defp reason(:invalid), do: "empty or invalid output"
  defp reason(_), do: "unexpected result"
end
