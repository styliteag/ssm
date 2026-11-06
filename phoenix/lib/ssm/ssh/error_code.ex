defmodule Ssm.Ssh.ErrorCode do
  @moduledoc """
  Short, stable codes for SSH failures shown to API clients (mctl job
  errors). The raw failure text (addresses, Erlang terms, OpenSSH output)
  stays in the server log; clients get the code and a fixed sentence.
  """

  @rules [
    {~r/host key changed/, "host_key_changed",
     "the host presented a different SSH host key than the pinned one"},
    {~r/not pinned|cannot be verified by OpenSSH/, "host_key_unpinned",
     "the SSH host key (of the host or a jump host) is not pinned"},
    {~r/invalid (username|address)/, "invalid_host",
     "the host record has an invalid username or address for SSH"},
    {~r/econnrefused/, "connect_refused", "the host refused the SSH connection"},
    {~r/timeout|timed out|etimedout/, "timeout", "the SSH connection timed out"},
    {~r/ehostunreach|enetunreach|ehostdown|enetdown/, "unreachable", "the host is unreachable"},
    {~r/nxdomain/, "dns_error", "the host name does not resolve"},
    {~r/authentication|Unable to connect using/i, "auth_failed",
     "SSH authentication with ssm's key failed"}
  ]

  @spec classify(term()) :: {code :: String.t(), message :: String.t()}
  def classify({:host_disabled, _message}), do: {"host_disabled", "the host is disabled"}

  def classify({:ssh_connect_failed, message}) when is_binary(message) do
    Enum.find_value(@rules, default(), fn {pattern, code, text} ->
      if Regex.match?(pattern, message), do: {code, text}
    end)
  end

  def classify(_reason), do: default()

  defp default, do: {"connect_failed", "the SSH connection failed"}
end
