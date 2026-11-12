defmodule MctlContract.Plug.Handlers do
  @moduledoc false
  # One function per contract operation: parse, call the provider, render.
  require Logger

  alias MctlContract.{Capabilities, MaintenanceLimits, OpenAPI, Page, Params, Render}
  alias MctlContract.Plug.Respond

  @contract_version "1"

  def openapi(conn, opts) do
    Respond.send_json(conn, 200, OpenAPI.spec(provider: opts[:provider], product: product(opts)))
  end

  def me(conn, opts) do
    p = conn.assigns.mctl_principal
    %{product: product, version: version} = product(opts)

    Respond.ok(conn, 200, %{
      product: product,
      version: version,
      contract_version: @contract_version,
      scopes: p.scopes,
      capabilities: Capabilities.list(opts[:provider]),
      token: %{name: p.name, prefix: p.prefix}
    })
  end

  @doc "List of an optional capability: 404 `not_found` when the provider lacks it."
  def list_if(conn, opts, capability, collection, fun, render) do
    if capability in Capabilities.list(opts[:provider]),
      do: list(conn, opts, collection, fun, render),
      else: not_found(conn)
  end

  @doc "Get of an optional capability: 404 `not_found` when the provider lacks it."
  def get_if(conn, opts, capability, fun, id, render) do
    if capability in Capabilities.list(opts[:provider]),
      do: get(conn, opts, fun, id, render),
      else: not_found(conn)
  end

  def list(conn, opts, collection, fun, render) do
    provider = opts[:provider]

    case Page.parse(conn.query_params, collection, cursor_types(provider, collection)) do
      {:ok, page} ->
        with_provider(conn, fn ->
          {:ok, items, next} = apply(provider, fun, [principal(conn), page])
          cursor = if next, do: MctlContract.Cursor.encode(collection, next)
          meta = %{limit: page.limit, next_cursor: cursor}
          Respond.ok(conn, 200, Enum.map(items, render), meta)
        end)

      {:error, message} ->
        Respond.error(conn, "bad_request", message)
    end
  end

  def get(conn, opts, fun, id, render) do
    with_provider(conn, fn ->
      case apply(opts[:provider], fun, [principal(conn), id]) do
        {:ok, item} -> Respond.ok(conn, 200, render.(item))
        {:error, reason} -> Respond.provider_error(conn, reason)
      end
    end)
  end

  @doc """
  Write: shape check with `check`, then `provider.fun(principal, args…, params)`.
  `{:ok, item}` answers `status` with `render`; `{:accepted, job}` (a write
  that continues as a job, e.g. a mode switch) answers 202 with the job.
  """
  def write(conn, opts, check, {fun, args}, status, render) do
    case params(check, body(conn), opts[:provider]) do
      {:ok, params} ->
        with_provider(conn, fn ->
          case apply(opts[:provider], fun, [principal(conn) | args] ++ [params]) do
            {:ok, item} -> Respond.ok(conn, status, render.(item))
            {:accepted, job} -> Respond.ok(conn, 202, Render.job(job))
            {:error, reason} -> Respond.provider_error(conn, reason)
          end
        end)

      {:error, details} ->
        Respond.error(conn, "validation_failed", "invalid input", details)
    end
  end

  # `PATCH /hosts/{id}` checks `attributes` against the provider's
  # updatable keys (capability `update_attributes`); the rest by shape only
  defp params(:host_update, body, provider),
    do:
      Params.host_update(
        body,
        Capabilities.updatable_attributes(provider),
        Capabilities.modes(provider)
      )

  # the provider's modes (`modes/0`): another mode is 422 on `mode`
  defp params(:host_create, body, provider),
    do: Params.host_create(body, Capabilities.modes(provider))

  defp params(check, body, _provider), do: apply(Params, check, [body])

  @doc """
  `POST /hosts/{id}/actions`: 404 without the capability, shape check,
  allow-list check (`host_actions/0`), then `provider.host_action/3`.
  """
  def host_action(conn, opts, id) do
    provider = opts[:provider]

    if Capabilities.host_actions?(provider) do
      with {:ok, params} <- Params.host_action(body(conn)),
           :ok <- supported(params["action"], Capabilities.actions(provider)) do
        with_provider(conn, fn ->
          case provider.host_action(principal(conn), id, params) do
            {:ok, job} -> Respond.ok(conn, 202, Render.job(job))
            {:error, reason} -> Respond.provider_error(conn, reason)
          end
        end)
      else
        {:error, details} -> Respond.error(conn, "validation_failed", "invalid input", details)
      end
    else
      not_found(conn)
    end
  end

  # contract section 10 (delete, maintenance, people): each route is
  # 404 `not_found` when the provider lacks the capability

  @doc "`DELETE /hosts/{id}`: 202 with the provider's `delete_host` job."
  def delete_host(conn, opts, id) do
    if_capability(conn, opts, "delete_host", fn provider ->
      reply(conn, provider.delete_host(principal(conn), id), 202, &Render.job/1)
    end)
  end

  @doc "`POST /hosts/{id}/maintenance`: shape and window check, 201."
  def create_maintenance(conn, opts, host_id) do
    if_capability(conn, opts, "maintenance", fn provider ->
      case Params.maintenance_create(body(conn)) do
        {:ok, params} ->
          result =
            with :ok <- MaintenanceLimits.check(provider, principal(conn), host_id, params),
                 do: provider.create_maintenance(principal(conn), host_id, params)

          reply(conn, result, 201, &Render.maintenance/1)

        {:error, details} ->
          Respond.error(conn, "validation_failed", "invalid input", details)
      end
    end)
  end

  @doc "`DELETE /maintenance/{id}`: 204 without body."
  def cancel_maintenance(conn, opts, id) do
    if_capability(conn, opts, "maintenance", fn provider ->
      case provider.cancel_maintenance(principal(conn), id) do
        :ok -> conn |> Plug.Conn.send_resp(204, "") |> Plug.Conn.halt()
        {:error, reason} -> Respond.provider_error(conn, reason)
      end
    end)
  end

  @doc """
  `DELETE /groups/{slug}` (capability `delete_group`): 204 without body;
  409 when hosts still carry the group.
  """
  def delete_group(conn, opts, slug) do
    if_capability(conn, opts, "delete_group", fn provider ->
      case provider.delete_group(principal(conn), slug) do
        :ok -> conn |> Plug.Conn.send_resp(204, "") |> Plug.Conn.halt()
        {:error, reason} -> Respond.provider_error(conn, reason)
      end
    end)
  end

  @doc """
  `DELETE /customers/{slug}` (capability `delete_customer`): 204 without
  body; 409 when hosts still belong to the customer.
  """
  def delete_customer(conn, opts, slug) do
    if_capability(conn, opts, "delete_customer", fn provider ->
      case provider.delete_customer(principal(conn), slug) do
        :ok -> conn |> Plug.Conn.send_resp(204, "") |> Plug.Conn.halt()
        {:error, reason} -> Respond.provider_error(conn, reason)
      end
    end)
  end

  @doc """
  `POST /probe/ssh` (capability `probe_ssh`): shape check, then
  `provider.probe_ssh/2`; 200 with the per-port results.
  """
  def probe_ssh(conn, opts) do
    if_capability(conn, opts, "probe_ssh", fn provider ->
      case Params.probe_ssh(body(conn)) do
        {:ok, params} ->
          reply(conn, provider.probe_ssh(principal(conn), params), 200, &Render.probe_ssh/1)

        {:error, details} ->
          Respond.error(conn, "validation_failed", "invalid input", details)
      end
    end)
  end

  @doc "`GET /people/{key}`: 400 on a malformed key."
  def get_person(conn, opts, key) do
    if_capability(conn, opts, "people", fn provider ->
      with_key(conn, key, fn ->
        reply(conn, provider.get_person(principal(conn), key), 200, &Render.person/1)
      end)
    end)
  end

  @doc "`POST /people/{key}/remove`: 202 with the provider's `remove_person` job."
  def remove_person(conn, opts, key) do
    if_capability(conn, opts, "people", fn provider ->
      with_key(conn, key, fn ->
        case Params.person_remove(body(conn)) do
          {:ok, params} ->
            result = provider.remove_person(principal(conn), key, params)
            reply(conn, result, 202, &Render.job/1)

          {:error, details} ->
            Respond.error(conn, "validation_failed", "invalid input", details)
        end
      end)
    end)
  end

  @doc "`PATCH /groups/{slug}` (capability `rename_group`): rename, 200 with the group."
  def update_group(conn, opts, slug) do
    if Capabilities.has?(opts[:provider], "rename_group"),
      do: write(conn, opts, :named_update, {:update_group, [slug]}, 200, renderer(:named)),
      else: not_found(conn)
  end

  @doc """
  `POST /customers/{slug}/merge` (capability `merge_customer`): shape
  check, then `provider.merge_customer/3`; 200 with `moved_hosts`.
  """
  def merge_customer(conn, opts, slug) do
    if_capability(conn, opts, "merge_customer", fn provider ->
      case Params.customer_merge(body(conn), slug) do
        {:ok, %{"into" => into}} ->
          result = provider.merge_customer(principal(conn), slug, into)
          reply(conn, result, 200, &Render.customer_merge/1)

        {:error, details} ->
          Respond.error(conn, "validation_failed", "invalid input", details)
      end
    end)
  end

  defp if_capability(conn, opts, capability, fun) do
    provider = opts[:provider]

    if Capabilities.has?(provider, capability),
      do: with_provider(conn, fn -> fun.(provider) end),
      else: not_found(conn)
  end

  defp with_key(conn, key, fun) do
    case Params.person_key(key) do
      :ok -> fun.()
      {:error, message} -> Respond.error(conn, "bad_request", message)
    end
  end

  defp reply(conn, {:ok, item}, status, render), do: Respond.ok(conn, status, render.(item))
  defp reply(conn, {:error, reason}, _status, _render), do: Respond.provider_error(conn, reason)

  defp supported(action, actions) do
    if action in actions, do: :ok, else: {:error, %{"action" => ["not supported"]}}
  end

  def not_found(conn), do: Respond.error(conn, "not_found", "unknown endpoint")

  def renderer(:host), do: &Render.host/1
  def renderer(:named), do: &Render.named/1
  def renderer(:job), do: &Render.job/1
  def renderer(:host_summary), do: &Render.host_summary/1

  defp body(conn) do
    case conn.body_params do
      %{"_json" => v} = params when map_size(params) == 1 -> v
      %Plug.Conn.Unfetched{} -> %{}
      params -> params
    end
  end

  defp principal(conn), do: conn.assigns.mctl_principal

  defp product(opts) do
    base = opts[:provider].product()

    case opts[:product] do
      nil -> base
      name when is_binary(name) -> %{base | product: name}
    end
  end

  defp cursor_types(provider, collection) do
    if function_exported?(provider, :cursor_types, 1),
      do: provider.cursor_types(collection),
      else: :any
  end

  # an exception in the provider answers 500 internal_error in the
  # envelope (and is logged), not the host framework's error page. The log
  # names only the exception module and an argument-free stacktrace:
  # messages, reasons and call arguments may hold provider data (secrets,
  # one-time passwords of a job result)
  defp with_provider(conn, fun) do
    fun.()
  rescue
    e ->
      log_failure(inspect(e.__struct__), __STACKTRACE__)
      Respond.error(conn, "internal_error", "unexpected server error")
  catch
    kind, _reason ->
      log_failure(inspect(kind), __STACKTRACE__)
      Respond.error(conn, "internal_error", "unexpected server error")
  end

  defp log_failure(what, stacktrace) do
    Logger.error(
      "mctl contract: provider failed with #{what}\n" <>
        Exception.format_stacktrace(safe_stacktrace(stacktrace))
    )
  end

  @doc false
  # stacktrace entries with call arguments replaced by their arity
  def safe_stacktrace(stacktrace) do
    Enum.map(stacktrace, fn
      {mod, fun, args, loc} when is_list(args) -> {mod, fun, length(args), loc}
      {fun, args, loc} when is_list(args) -> {fun, length(args), loc}
      entry -> entry
    end)
  end
end
