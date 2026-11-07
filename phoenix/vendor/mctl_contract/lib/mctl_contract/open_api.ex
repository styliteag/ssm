defmodule MctlContract.OpenAPI do
  @moduledoc """
  OpenAPI 3.1 document of contract v1, served at `/openapi.json`.

  `spec/1` options: `provider` (its optional `attributes_schema/0` documents
  the host `attributes`), `product` (`%{product, version}`), `server`
  (default `/api/mctl/v1`). The host summary routes and schema appear only
  when the provider implements them (`MctlContract.Capabilities`); so do
  `POST /hosts/{id}/actions` and `HostAction` (with the provider's action
  names as enum) and the routes and schemas of the `delete_host`,
  `maintenance`, `people`, `rename_group`, `merge_customer`, `delete_group`
  and `delete_customer` capabilities.
  """
  alias MctlContract.{Capabilities, Envelope, Page}
  alias MctlContract.OpenAPI.Schemas

  @ops [
    {"get", "/me", :any, "Me", "Product, version, scopes and token", []},
    {"get", "/openapi.json", :public, nil, "This document", []},
    {"get", "/hosts", "read", {:list, "Host"}, "List hosts", paged: "hosts"},
    {"get", "/hosts/{id}", "read", "Host", "One host", []},
    {"post", "/hosts", "setup", "Job", "Create a host (job)", body: "HostCreate", status: 202},
    {"patch", "/hosts/{id}", "setup", "Host",
     "Change name, customer, groups, mode (202 Job when the switch waits for the agent)",
     body: "HostUpdate", also: [{202, "Job"}]},
    {"get", "/customers", "read", {:list, "Customer"}, "List customers", paged: "customers"},
    {"post", "/customers", "setup", "Customer", "Create a customer",
     body: "NamedCreate", status: 201},
    {"patch", "/customers/{slug}", "setup", "Customer", "Rename a customer", body: "NamedUpdate"},
    {"get", "/groups", "read", {:list, "Group"}, "List groups", paged: "groups"},
    {"post", "/groups", "setup", "Group", "Create a group", body: "NamedCreate", status: 201},
    {"get", "/jobs", "read", {:list, "Job"}, "List jobs", paged: "jobs"},
    {"get", "/jobs/{id}", "read", "Job", "One job", []}
  ]

  # only when the provider has the `host_summaries` capability
  @summary_ops [
    {"get", "/host-summaries", "read", {:list, "HostSummary"}, "List host summaries",
     paged: "host_summaries"},
    {"get", "/hosts/{id}/summary", "read", "HostSummary", "Summary of one host", []}
  ]

  # only when the provider has host actions (`action:<name>` capabilities)
  @action_ops [
    {"post", "/hosts/{id}/actions", "commands", "Job", "Run an allow-listed action (job)",
     body: "HostAction", status: 202, idempotent: true}
  ]

  # contract sections 10 to 14, one group per capability
  @capability_ops %{
    "delete_host" => [
      {"delete", "/hosts/{id}", "setup", "Job", "Delete a host (job, kind delete_host)",
       status: 202}
    ],
    "maintenance" => [
      {"post", "/hosts/{id}/maintenance", "setup", "Maintenance", "Schedule a maintenance window",
       body: "MaintenanceCreate", status: 201},
      {"get", "/maintenance", "read", {:list, "Maintenance"}, "List maintenance windows",
       paged: "maintenance"},
      {"delete", "/maintenance/{id}", "setup", :no_content,
       "Cancel a window (ends an active one)", status: 204}
    ],
    "people" => [
      {"get", "/people/{key}", "read", "Person",
       "What the tool knows about a person (key URL-encoded)", []},
      {"post", "/people/{key}/remove", "commands", "Job",
       "Remove the person's access (job, kind remove_person)",
       body: "PersonRemove", status: 202, idempotent: true}
    ],
    "rename_group" => [
      {"patch", "/groups/{slug}", "setup", "Group", "Rename a group (slug stays)",
       body: "NamedUpdate"}
    ],
    "merge_customer" => [
      {"post", "/customers/{slug}/merge", "setup", "CustomerMergeResult",
       "Merge the customer into another (hosts move, the customer is deleted; global token)",
       body: "CustomerMerge", idempotent: true}
    ],
    "delete_group" => [
      {"delete", "/groups/{slug}", "setup", :no_content,
       "Delete an unused group (409 while hosts carry it)", status: 204}
    ],
    "delete_customer" => [
      {"delete", "/customers/{slug}", "setup", :no_content,
       "Delete an empty customer (409 while hosts belong to it; global token)", status: 204}
    ]
  }

  @doc """
  `[{method, path, need}]` of every operation, including the optional
  routes of all capabilities (need: :public, :any or a scope).
  """
  @spec operations() :: [{String.t(), String.t(), atom() | String.t()}]
  def operations do
    optional = @capability_ops |> Map.values() |> List.flatten()

    Enum.map(@ops ++ @summary_ops ++ @action_ops ++ optional, fn {m, p, need, _, _, _} ->
      {m, p, need}
    end)
  end

  @spec spec(keyword()) :: map()
  def spec(opts \\ []) do
    product = opts[:product] || %{product: "tool", version: "0"}
    provider = opts[:provider]
    summaries? = provider != nil and Capabilities.host_summaries?(provider)

    actions =
      if provider != nil and Capabilities.host_actions?(provider),
        do: Capabilities.actions(provider)

    caps = if provider, do: Capabilities.list(provider), else: []

    %{
      "openapi" => "3.1.0",
      "info" => %{
        "title" => "mctl contract v1 (#{product.product})",
        "version" => "1",
        "x-product-version" => product.version,
        "description" => description()
      },
      "servers" => [%{"url" => Keyword.get(opts, :server, "/api/mctl/v1")}],
      "security" => [%{"bearer" => []}],
      "paths" => paths(summaries?, actions, caps),
      "components" => %{
        "securitySchemes" => %{
          "bearer" => %{"type" => "http", "scheme" => "bearer"}
        },
        "schemas" => Schemas.all(attributes(provider), summaries?, actions, caps)
      },
      "x-error-codes" =>
        Enum.map(Envelope.error_codes(), fn {code, status, desc} ->
          %{"code" => code, "status" => status, "description" => desc}
        end)
    }
  end

  defp description do
    """
    mctl contract v1. Envelope `{data, meta}` / `{error: {code, message, details}}` \
    (`x-error-codes`). Bearer token with scopes read, setup, commands. Keyset cursor \
    pagination (`limit` ≤ 1000, `cursor` = `meta.next_cursor`). POST accepts an \
    Idempotency-Key (24 h). Times are ISO 8601 UTC.\
    """
  end

  defp attributes(nil), do: %{"type" => "object"}

  defp attributes(provider) do
    Code.ensure_loaded(provider)

    if function_exported?(provider, :attributes_schema, 0),
      do: provider.attributes_schema(),
      else: %{"type" => "object"}
  end

  defp paths(summaries?, actions, caps) do
    ops =
      @ops ++
        if(summaries?, do: @summary_ops, else: []) ++
        if(actions, do: @action_ops, else: []) ++
        Enum.flat_map(caps, &Map.get(@capability_ops, &1, []))

    ops
    |> Enum.group_by(fn {_m, p, _, _, _, _} -> p end)
    |> Map.new(fn {path, ops} ->
      {path, Map.new(ops, fn {m, _p, _, _, _, _} = op -> {m, operation(op)} end)}
    end)
  end

  defp operation({_m, path, need, data, summary, opts}) do
    %{
      "summary" => summary,
      "x-scope" => to_string(need),
      "parameters" => path_params(path) ++ paged(opts[:paged]) ++ idempotency(opts, path),
      "responses" => responses(data, opts)
    }
    |> put_security(need)
    |> put_body(opts[:body])
  end

  defp put_security(op, :public), do: Map.put(op, "security", [])
  defp put_security(op, _need), do: op

  defp put_body(op, nil), do: op

  defp put_body(op, schema) do
    Map.put(op, "requestBody", %{
      "required" => true,
      "content" => %{"application/json" => %{"schema" => ref(schema)}}
    })
  end

  defp path_params(path) do
    ~r/\{(\w+)\}/
    |> Regex.scan(path, capture: :all_but_first)
    |> Enum.map(fn [name] ->
      %{"name" => name, "in" => "path", "required" => true, "schema" => %{"type" => "string"}}
    end)
  end

  defp paged(nil), do: []

  defp paged(collection) do
    base = [
      query("limit", %{"type" => "integer", "minimum" => 1, "maximum" => 1000}),
      query("cursor", %{"type" => "string"}, "opaque; meta.next_cursor of the previous page")
    ]

    base ++
      Enum.map(Page.filters(collection), fn
        {name, :datetime} -> query(name, %{"type" => "string", "format" => "date-time"})
        {name, :string} -> query(name, %{"type" => "string"})
        {name, {:enum, values}} -> query(name, %{"type" => "string", "enum" => values})
      end)
  end

  defp idempotency(opts, path) do
    if opts[:body] == nil or (String.contains?(path, "{") and !opts[:idempotent]),
      do: [],
      else: [
        %{
          "name" => "Idempotency-Key",
          "in" => "header",
          "schema" => %{"type" => "string", "maxLength" => 255},
          "description" => "retries with the same key and body return the first response (24 h)"
        }
      ]
  end

  defp query(name, schema, desc \\ nil) do
    %{"name" => name, "in" => "query", "schema" => schema}
    |> then(&if(desc, do: Map.put(&1, "description", desc), else: &1))
  end

  defp responses(nil, _opts), do: %{"200" => %{"description" => "OpenAPI document"}}

  defp responses(:no_content, _opts) do
    %{"204" => %{"description" => "done, no body"}, "default" => error_response()}
  end

  defp responses(data, opts) do
    status = opts |> Keyword.get(:status, 200) |> Integer.to_string()

    # `also`: further success statuses with their data, e.g. PATCH /hosts/{id}
    # answers 202 with a Job when a mode switch waits for the agent
    extra =
      Map.new(Keyword.get(opts, :also, []), fn {code, name} ->
        {Integer.to_string(code), success(name)}
      end)

    Map.merge(extra, %{status => success(data), "default" => error_response()})
  end

  defp error_response do
    %{
      "description" => "error",
      "content" => %{"application/json" => %{"schema" => ref("Error")}}
    }
  end

  defp success(data),
    do: %{
      "description" => "success",
      "content" => %{"application/json" => %{"schema" => envelope(data)}}
    }

  defp envelope({:list, name}) do
    %{
      "type" => "object",
      "required" => ["data", "meta"],
      "properties" => %{
        "data" => %{"type" => "array", "items" => ref(name)},
        "meta" => ref("PageMeta")
      }
    }
  end

  defp envelope(name) do
    %{
      "type" => "object",
      "required" => ["data", "meta"],
      "properties" => %{"data" => ref(name), "meta" => %{"type" => "object"}}
    }
  end

  defp ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}
end
