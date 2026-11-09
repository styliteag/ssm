defmodule Ssm.OIDC.LoginHosts do
  @moduledoc """
  `OIDC_LOGIN_HOSTS` (oidc-client-v1 §2a): when ssm is served under a
  second name (`PHX_ALT_HOSTS`, e.g. `ssm.orbit.my.sty`) and the provider
  is too (`orbit.my.sty`), a login or RP logout started on that name sends
  the browser to the provider's alias name, where the user's session
  cookie lives. Only the host of the front-channel URL changes; discovery,
  JWKS, the token endpoint and the `iss` check keep using `OIDC_ISSUER`.

  The target always comes from the configuration, never from the Host
  header: a request host that is not a key keeps the URL unchanged.
  """

  require Logger

  # a DNS name: dot-separated labels of letters, digits and inner hyphens
  @host ~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\z/

  @type t :: %{String.t() => String.t()}

  @doc """
  Parse `toolhost=idphost,…`. Keys must be among `own_hosts` (ssm's
  `PHX_HOST` and `PHX_ALT_HOSTS`); malformed or foreign entries are
  logged and dropped.
  """
  @spec parse(String.t() | nil, [String.t()]) :: t()
  def parse(nil, _own_hosts), do: %{}

  def parse(value, own_hosts) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn entry, acc ->
      case entry(entry, own_hosts) do
        {:ok, from, to} -> Map.put(acc, from, to)
        :error -> acc
      end
    end)
  end

  defp entry(entry, own_hosts) do
    with [from, to] <- entry |> String.split("=") |> Enum.map(&normalize/1),
         true <- host?(from) and host?(to) do
      if from in own_hosts do
        {:ok, from, to}
      else
        Logger.error(
          "OIDC_LOGIN_HOSTS: #{from} is not one of ssm's names (PHX_HOST, PHX_ALT_HOSTS); ignored"
        )

        :error
      end
    else
      _ ->
        Logger.error(
          "OIDC_LOGIN_HOSTS: malformed entry #{inspect(entry)} ignored (want toolhost=idphost)"
        )

        :error
    end
  end

  defp normalize(part), do: part |> String.trim() |> String.downcase()

  defp host?(name), do: byte_size(name) <= 253 and Regex.match?(@host, name)

  @doc """
  `url` with its host replaced by the mapped IdP host when `request_host`
  is a key of `map`; otherwise `url` unchanged (`nil` stays `nil`).
  """
  @spec rewrite(String.t() | nil, String.t() | nil, t()) :: String.t() | nil
  def rewrite(nil, _request_host, _map), do: nil
  def rewrite(url, nil, _map), do: url

  def rewrite(url, request_host, map) when is_binary(url) do
    case Map.fetch(map, String.downcase(request_host)) do
      {:ok, idp_host} -> url |> URI.parse() |> Map.put(:host, idp_host) |> URI.to_string()
      :error -> url
    end
  end
end
