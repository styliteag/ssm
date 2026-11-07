defmodule MctlContract.MaintenanceLimits do
  @max_planned 10

  @moduledoc """
  Limits on maintenance windows that need the host's existing windows,
  checked by the library before `create_maintenance/3` so every tool
  enforces them alike (a window mutes alerts, so it must not pile up):

    * a new window must not overlap a `planned` or `active` window of the
      same host → `409 conflict` naming the window;
    * at most #{@max_planned} `planned` windows per host → `409 conflict`.

  The existing windows come from the provider's own `list_maintenance/2`
  (filter `host_id`, all pages) with the caller's principal. The per-window
  limits (length, lead time) are shape checks in `MctlContract.Params`.
  """

  alias MctlContract.Render

  @page 1000
  @max_pages 20

  @doc "Most `planned` windows a host may have."
  def max_planned, do: @max_planned

  @doc "`:ok` or `{:error, {:conflict, message}}`."
  @spec check(module(), MctlContract.Principal.t(), String.t(), map()) ::
          :ok | {:error, {:conflict, String.t()}}
  def check(provider, principal, host_id, %{"start" => from, "end" => to}) do
    open =
      provider |> windows(principal, host_id) |> Enum.filter(&(&1.state in ~w(planned active)))

    cond do
      overlap = Enum.find(open, &(before?(&1.start, to) and before?(from, &1.end))) ->
        {:error, {:conflict, "overlaps maintenance #{overlap.id} of this host"}}

      Enum.count(open, &(&1.state == "planned")) >= @max_planned ->
        {:error, {:conflict, "at most #{@max_planned} planned maintenance windows per host"}}

      true ->
        :ok
    end
  end

  defp windows(provider, principal, host_id, after_key \\ nil, pages \\ @max_pages)
  defp windows(_provider, _principal, _host_id, _after, 0), do: []

  defp windows(provider, principal, host_id, after_key, pages) do
    page = %{after: after_key, limit: @page, filters: %{"host_id" => host_id}}
    {:ok, items, next} = provider.list_maintenance(principal, page)
    parsed = Enum.map(items, &parse/1)

    case next do
      nil -> parsed
      key -> parsed ++ windows(provider, principal, host_id, key, pages - 1)
    end
  end

  defp parse(item) do
    m = Render.maintenance(item)
    %{id: m["id"], state: m["state"], start: time(m["start"]), end: time(m["end"])}
  end

  defp time(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    dt
  end

  defp before?(a, b), do: DateTime.compare(a, b) == :lt
end
