defmodule SsmWeb.Hosts do
  @moduledoc """
  Host names the UI is served under: `PHX_HOST` (the endpoint URL) plus the
  extra names in `PHX_ALT_HOSTS` (e.g. a NetBird name next to the public
  one). Session cookies are host-only, so URLs the browser must come back
  to (the SSO callback, the post-logout sign-in page) have to stay on the
  name the request came in on.

  The Host header is client-controlled: only names on this list are used;
  any other host gets the endpoint URL unchanged.
  """

  @doc "Extra host names from `PHX_ALT_HOSTS` (lowercase)."
  @spec alt_hosts() :: [String.t()]
  def alt_hosts, do: Application.get_env(:ssm, :alt_hosts, [])

  @doc "Parse a comma-separated host list: trimmed, lowercase, no empty entries."
  @spec parse(String.t() | nil) :: [String.t()]
  def parse(nil), do: []

  def parse(list) when is_binary(list) do
    list
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Absolute URL of `path` on the request's host when that host is the
  endpoint's own or in `PHX_ALT_HOSTS`; otherwise the endpoint URL. Scheme
  and port always come from the endpoint URL.
  """
  @spec url(Plug.Conn.t(), String.t()) :: String.t()
  def url(%Plug.Conn{host: host}, path) do
    base = URI.parse(SsmWeb.Endpoint.url() <> path)
    host = String.downcase(host || "")

    if host != "" and (host == base.host or host in alt_hosts()),
      do: URI.to_string(%{base | host: host}),
      else: URI.to_string(base)
  end
end
