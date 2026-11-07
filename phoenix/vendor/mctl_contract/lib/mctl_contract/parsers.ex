defmodule MctlContract.Parsers do
  @moduledoc """
  Drop-in replacement for `Plug.Parsers` in the tool's endpoint. Bodies of
  requests below the contract prefix are left unparsed: `MctlContract.Plug`
  parses them after the token check (with its `max_body` limit and the
  contract's `400 bad_request` envelope). Every other path is parsed by
  `Plug.Parsers` as before.

      plug MctlContract.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Phoenix.json_library(),
        mctl_prefix: "/api/mctl/v1"

  All options except `mctl_prefix` (default `/api/mctl/v1`) go to
  `Plug.Parsers`.
  """
  @behaviour Plug

  @impl true
  def init(opts) do
    {prefix, parser_opts} = Keyword.pop(opts, :mctl_prefix, "/api/mctl/v1")
    {String.split(prefix, "/", trim: true), Plug.Parsers.init(parser_opts)}
  end

  @impl true
  def call(conn, {prefix, parsers}) do
    if contract_path?(conn.path_info, prefix),
      do: conn,
      else: Plug.Parsers.call(conn, parsers)
  end

  # on path segments (empty ones dropped, as the router sees them), so
  # `/api//mctl/v1` cannot slip past the prefix
  defp contract_path?(path_info, prefix), do: List.starts_with?(path_info, prefix)
end
