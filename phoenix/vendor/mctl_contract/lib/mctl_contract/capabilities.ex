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
    * `"merge_customer"` – `merge_customer/3`
      (`POST /customers/{slug}/merge`)
    * `"delete_group"` – `delete_group/2` (`DELETE /groups/{slug}`)
    * `"delete_customer"` – `delete_customer/2` (`DELETE /customers/{slug}`)
    * `"probe_ssh"` – `probe_ssh/2` (`POST /probe/ssh`)
    * `"update_attributes"` – `updatable_attributes/0`: the host attribute
      keys `PATCH /hosts/{id}` accepts in `attributes` (the library refuses
      other keys with 422 before `update_host/3` runs)
    * `"mode:<m>"` – one per mode of the optional `modes/0`: the host
      modes `POST /hosts` and `PATCH /hosts/{id}` accept (the library
      refuses others with 422 on `mode`); none without the callback
    * `"attribute:<key>"` – one per key of `updatable_attributes/0`
      (capability `update_attributes`)
    * `"action:<name>"` – one per name of `host_actions/0` when the
      provider implements both `host_actions/0` and `host_action/3`
      (`POST /hosts/{id}/actions`)
    * tool facts from the optional `extra_capabilities/0`, each
      `<prefix>:<value>` (e.g. the dashboard's `relay_device:linux`); the
      reserved prefixes `mode`, `attribute` and `action` and malformed
      entries are dropped
  """

  @reserved ~w(mode attribute action)
  @extra ~r/\A([a-z][a-z0-9_]{0,31}):[a-z0-9][a-z0-9_.-]{0,63}\z/

  # capability => callbacks that must all be exported
  @callbacks [
    {"host_summaries", [list_host_summaries: 2, get_host_summary: 2]},
    {"delete_host", [delete_host: 2]},
    {"maintenance", [create_maintenance: 3, list_maintenance: 2, cancel_maintenance: 2]},
    {"people", [get_person: 2, remove_person: 3]},
    {"rename_group", [update_group: 3]},
    {"merge_customer", [merge_customer: 3]},
    {"delete_group", [delete_group: 2]},
    {"delete_customer", [delete_customer: 2]},
    {"probe_ssh", [probe_ssh: 2]},
    {"update_attributes", [updatable_attributes: 0]}
  ]

  @spec list(module()) :: [String.t()]
  def list(provider) do
    named = for {name, _} <- @callbacks, has?(provider, name), do: name

    named ++
      Enum.map(modes(provider) || [], &("mode:" <> &1)) ++
      Enum.map(updatable_attributes(provider) || [], &("attribute:" <> &1)) ++
      Enum.map(actions(provider), &("action:" <> &1)) ++
      extra(provider)
  end

  # tool facts (`extra_capabilities/0`): well-formed, not reserved, sorted
  defp extra(provider) do
    Code.ensure_loaded(provider)

    if function_exported?(provider, :extra_capabilities, 0) do
      provider.extra_capabilities()
      |> Enum.filter(&extra?/1)
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  end

  defp extra?(entry) when is_binary(entry) do
    case Regex.run(@extra, entry) do
      [_, prefix] -> prefix not in @reserved
      _ -> false
    end
  end

  defp extra?(_entry), do: false

  @doc """
  The host modes the provider accepts (`modes/0`), sorted and unique; nil
  without the callback (then the provider checks the mode itself).
  """
  @spec modes(module()) :: [String.t()] | nil
  def modes(provider) do
    Code.ensure_loaded(provider)

    if function_exported?(provider, :modes, 0),
      do: provider.modes() |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort(),
      else: nil
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

  @doc """
  The host attribute keys the provider lets `PATCH /hosts/{id}` change,
  sorted and unique; nil without the `update_attributes` capability.
  """
  @spec updatable_attributes(module()) :: [String.t()] | nil
  def updatable_attributes(provider) do
    if has?(provider, "update_attributes"),
      do: provider.updatable_attributes() |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort(),
      else: nil
  end

  @doc "The provider's action names, sorted and unique; `[]` without host actions."
  @spec actions(module()) :: [String.t()]
  def actions(provider) do
    if host_actions?(provider),
      do: provider.host_actions() |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort(),
      else: []
  end
end
