defmodule Ssm.Hosts.SshFields do
  @moduledoc """
  Rules for the host fields that end up on the local `ssh` command line
  (the OpenSSH forwarder for jump chains): `username` and `address`.

  A value starting with `-` would be parsed as an ssh option
  (`-oProxyCommand=…` runs a shell command on the ssm server); `@`, `,`,
  `:` or whitespace would change which host or user ssh uses. The rules are
  checked twice: in `Ssm.Hosts.Host.changeset/2` (input) and, via
  `check_target/1`, before every SSH connection — rows written before the
  rule existed still load, but are never connected to.

    * username: `^[A-Za-z0-9_][A-Za-z0-9._-]{0,31}$`
    * address: an IPv4/IPv6 literal (no zone id, no brackets) or a DNS
      hostname (labels of letters, digits, `_`, inner `-`; ≤ 253 chars)
  """

  alias Ssm.Ssh.Target

  @username ~r/\A[A-Za-z0-9_][A-Za-z0-9._-]{0,31}\z/
  @label "[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?"
  @hostname Regex.compile!("\\A#{@label}(?:\\.#{@label})*\\.?\\z")

  @spec valid_username?(term()) :: boolean()
  def valid_username?(value) when is_binary(value), do: Regex.match?(@username, value)
  def valid_username?(_), do: false

  @spec valid_address?(term()) :: boolean()
  def valid_address?(value) when is_binary(value) do
    ip_literal?(value) or (byte_size(value) <= 253 and Regex.match?(@hostname, value))
  end

  def valid_address?(_), do: false

  defp ip_literal?(value) do
    not String.contains?(value, "%") and
      match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(value)))
  end

  @doc "The fields of `host` that break the rules (`[:username, :address]`)."
  @spec problems(%{username: term(), address: term()}) :: [:username | :address]
  def problems(host) do
    Enum.reject(
      [
        if(valid_username?(host.username), do: nil, else: :username),
        if(valid_address?(host.address), do: nil, else: :address)
      ],
      &is_nil/1
    )
  end

  @doc """
  `:ok` when the target and every jump hop pass the rules, else
  `{:error, {:ssh_connect_failed, message}}` naming the host and field
  (never the offending value).
  """
  @spec check_target(Target.t()) :: :ok | {:error, {:ssh_connect_failed, String.t()}}
  def check_target(%Target{} = target) do
    case target |> chain() |> Enum.find_value(&bad_hop/1) do
      nil -> :ok
      message -> {:error, {:ssh_connect_failed, message}}
    end
  end

  defp chain(nil), do: []
  defp chain(%Target{} = t), do: [t | chain(t.jump_target)]

  defp bad_hop(hop) do
    case problems(hop) do
      [] ->
        nil

      fields ->
        "host #{hop.name} has an invalid #{Enum.join(fields, " and ")} for SSH — " <>
          "refusing to connect; fix the host record"
    end
  end
end
