defmodule Ssm.Ssh.HostKeyCb do
  @moduledoc """
  `:ssh_client_key_api` callback for `Ssm.Ssh.ErlangClient` (ADR-0008,
  pattern from the dashboard's Securepoint SSH).

  The client key comes from the prepared key dir exactly as before
  (delegated to `:ssh_file`); the host key is decided here, during key
  exchange — returning `false` aborts the handshake before authentication,
  so nothing is ever sent to an impostor.

  `key_cb_private` options:

    * `mode: {:verify, pinned_fingerprint}` — every normal connect. Accepts
      only a key whose fingerprint matches; a blank pin refuses (fail closed).
    * `mode: :capture` — `ErlangClient.probe_host_key/1` only, the single
      trust-on-first-use path. Accepts and reports the key.
    * `reply_to: pid` — receives `{:ssm_host_key, :accepted | :rejected,
      %{public_key, fingerprint}}` so the caller can store the key or explain
      a refusal.
  """

  @behaviour :ssh_client_key_api

  alias Ssm.Ssh.HostKey

  @impl true
  def user_key(algorithm, opts), do: :ssh_file.user_key(algorithm, opts)

  @impl true
  def is_host_key(key, _host, _port, _algorithm, opts) do
    private = Keyword.get(opts, :key_cb_private, [])

    case HostKey.from_erlang_key(key) do
      {:ok, offered} -> decide(Keyword.get(private, :mode), offered, private)
      {:error, _} -> false
    end
  end

  @impl true
  def add_host_key(_host, _port, _key, _opts), do: :ok

  defp decide(:capture, offered, private), do: report(private, :accepted, offered)

  defp decide({:verify, pinned}, offered, private) do
    if HostKey.matches?(pinned, offered.fingerprint) do
      report(private, :accepted, offered)
    else
      report(private, :rejected, offered)
    end
  end

  defp decide(_mode, _offered, _private), do: false

  defp report(private, verdict, offered) do
    case Keyword.get(private, :reply_to) do
      pid when is_pid(pid) -> send(pid, {:ssm_host_key, verdict, offered})
      _ -> :ok
    end

    verdict == :accepted
  end
end
