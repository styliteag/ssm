defmodule MctlContract.Capabilities do
  @moduledoc """
  Optional parts of the contract a provider supports, listed in `GET /me`
  as `capabilities` and used to include routes in the OpenAPI document.

    * `"host_summaries"` – the provider implements both
      `list_host_summaries/2` and `get_host_summary/2`
      (`GET /host-summaries`, `GET /hosts/{id}/summary`)
    * `"delete_host"` – `delete_host/2` (`DELETE /hosts/{id}`)
    * `"maintenance"` – `create_maintenance/3`, `list_maintenance/2` and
      `cancel_maintenance/2` (`POST /hosts/{id}/maintenance`,
      `GET /maintenance`, `DELETE /maintenance/{id}`)
    * `"people"` – `get_person/2` and `remove_person/3`
      (`GET /people/{key}`, `POST /people/{key}/remove`)
    * `"rename_group"` – `update_group/3` (`PATCH /groups/{slug}`)
    * `"action:<name>"` – one per name of `host_actions/0` when the
      provider implements both `host_actions/0` and `host_action/3`
      (`POST /hosts/{id}/actions`)
  """

  # capability => callbacks that must all be exported
  @callbacks [
    {"host_summaries", [list_host_summaries: 2, get_host_summary: 2]},
    {"delete_host", [delete_host: 2]},
    {"maintenance", [create_maintenance: 3, list_maintenance: 2, cancel_maintenance: 2]},
    {"people", [get_person: 2, remove_person: 3]},
    {"rename_group", [update_group: 3]}
  ]

  @spec list(module()) :: [String.t()]
  def list(provider) do
    named = for {name, _} <- @callbacks, has?(provider, name), do: name
    named ++ Enum.map(actions(provider), &("action:" <> &1))
  end

  @doc "Whether the provider has the named capability (not `action:<name>`)."
  @spec has?(module(), String.t()) :: boolean()
  def has?(provider, name) do
    {^name, funs} = List.keyfind(@callbacks, name, 0)
    Code.ensure_loaded(provider)
    Enum.all?(funs, fn {fun, arity} -> function_exported?(provider, fun, arity) end)
  end

  @spec host_summaries?(module()) :: boolean()
  def host_summaries?(provider), do: has?(provider, "host_summaries")

  @doc "Whether the provider implements host actions (both callbacks)."
  @spec host_actions?(module()) :: boolean()
  def host_actions?(provider) do
    Code.ensure_loaded(provider)

    function_exported?(provider, :host_actions, 0) and
      function_exported?(provider, :host_action, 3)
  end

  @doc "The provider's action names, sorted and unique; `[]` without host actions."
  @spec actions(module()) :: [String.t()]
  def actions(provider) do
    if host_actions?(provider),
      do: provider.host_actions() |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort(),
      else: []
  end
end
