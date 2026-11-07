defmodule MctlContract.Provider do
  @moduledoc """
  The tool's side of the contract: domain logic behind `/api/mctl/v1`.

  Every callback gets the `MctlContract.Principal` first (binding, audit).
  `params` are string-keyed maps, already checked for shape by the library
  (types, slug format, known fields); the provider checks meaning (unknown
  customer, unsupported mode, …).

  `page` is `%{after: key | nil, limit: pos_integer, filters: map}`. List
  callbacks return items sorted by their key and, when more items exist,
  the key of the last returned item (a list of strings, integers or
  `DateTime`s, the last element unique); else nil. The library turns the
  key into an opaque cursor and back. Without `cursor_types/1` decoded keys
  hold strings and integers as encoded (a `DateTime` comes back as an
  ISO 8601 string).

  Filters (string keys): hosts `changed_after` (`DateTime`), `customer`,
  `group`; jobs `host_id`, `state`; host summaries `changed_after`,
  `host_id`; maintenance `host_id`, `state`.

  Items are maps with the keys of the contract objects (atom or string
  keys); the library renders them (`MctlContract.Render`).
  """
  alias MctlContract.Principal

  @type page :: %{after: list() | nil, limit: pos_integer(), filters: map()}
  @type error ::
          :not_found
          | :conflict
          | {:conflict, String.t()}
          | {:conflict, String.t(), %{String.t() => [String.t()]}}
          | :forbidden
          | {:validation, %{String.t() => [String.t()]}}
  @type list_result :: {:ok, [map()], list() | nil}

  @callback product() :: %{product: String.t(), version: String.t()}
  @callback list_hosts(Principal.t(), page()) :: list_result()
  @callback get_host(Principal.t(), id :: String.t()) :: {:ok, map()} | {:error, :not_found}
  @callback create_host(Principal.t(), params :: map()) :: {:ok, job :: map()} | {:error, error()}
  # `{:accepted, job}`: the update continues as a job (202 Job), e.g. a
  # switch of `mode` that waits for the agent
  @callback update_host(Principal.t(), id :: String.t(), params :: map()) ::
              {:ok, map()} | {:accepted, job :: map()} | {:error, error()}
  @callback list_customers(Principal.t(), page()) :: list_result()
  @callback create_customer(Principal.t(), params :: map()) :: {:ok, map()} | {:error, error()}
  @callback update_customer(Principal.t(), slug :: String.t(), params :: map()) ::
              {:ok, map()} | {:error, error()}
  @callback list_groups(Principal.t(), page()) :: list_result()
  @callback create_group(Principal.t(), params :: map()) :: {:ok, map()} | {:error, error()}
  @callback get_job(Principal.t(), id :: String.t()) :: {:ok, map()} | {:error, :not_found}
  @callback list_jobs(Principal.t(), page()) :: list_result()

  @doc """
  Optional: cursor key types per collection (`"hosts"`, `"customers"`,
  `"groups"`, `"jobs"`, `"host_summaries"`, `"maintenance"`), see `MctlContract.Cursor`. Default `:any`.
  """
  @callback cursor_types(collection :: String.t()) :: [MctlContract.Cursor.type()] | :any

  @doc """
  Optional: JSON schema of the tool's host `attributes`, embedded in the
  OpenAPI document.
  """
  @callback attributes_schema() :: map()

  @doc """
  Optional (C4, host summaries): one summary per host, paged like the other
  lists (collection `"host_summaries"`, filters `changed_after`
  (`DateTime`, against the summary's `updated_at`) and `host_id`). Return
  the summary of every host, `unknown` for a host without data. Implement
  both callbacks or none: without them both routes answer `404 not_found`
  and `/me` has no `host_summaries` capability.

  A summary is a map with the keys of `HostSummary` (contract section 9).
  Handled problems (US-HST-09): an item may carry `acknowledged` and
  `in_downtime` (absent = `false`), `counts` may carry `handled` (number of
  non-OK items that are handled). Compute `state` from unhandled items only
  and bump `updated_at` when an item becomes handled or unhandled.
  """
  @callback list_host_summaries(Principal.t(), page()) :: list_result()
  @callback get_host_summary(Principal.t(), host_id :: String.t()) ::
              {:ok, map()} | {:error, :not_found}

  @doc """
  Optional (onboarding v2, host actions): the names of the fixed,
  allow-listed actions this tool can run on a host (`/me` lists them as
  `capabilities` `"action:<name>"`). Called per request, so the list may
  depend on configuration. Implement it together with `host_action/3`.
  """
  @callback host_actions() :: [String.t()]

  @doc """
  Optional (onboarding v2, host actions): run `action` on host `id`
  (`POST /hosts/{id}/actions`, scope `commands`). The library has already
  checked the shape (`action` a string, `params` an object, default `%{}`)
  and that `action` is one of `host_actions/0`; the provider validates
  `params` (`{:validation, %{field => [msg]}}`) and answers `:not_found`
  for an unknown host. Returns the job tracking the action (202). Without
  both callbacks the route answers `404 not_found`.
  """
  @callback host_action(Principal.t(), id :: String.t(), %{
              String.t() => String.t() | map()
            }) :: {:ok, job :: map()} | {:error, error()}

  @doc """
  Optional (contract section 10, delete): remove host `id`
  (`DELETE /hosts/{id}`, scope `setup`). Returns the job (`kind:
  "delete_host"`, result `%{"deleted" => true}` once done) or `:not_found`.
  Without it the route answers `404 not_found` and `/me` has no
  `delete_host` capability.
  """
  @callback delete_host(Principal.t(), id :: String.t()) ::
              {:ok, job :: map()} | {:error, error()}

  @doc """
  Optional (contract section 10, maintenance): schedule a maintenance
  window on host `id` (`POST /hosts/{id}/maintenance`, scope `setup`).
  The library has checked the shape: `params` holds `"start"` and `"end"`
  as UTC `DateTime`s (`end > start`, `end` in the future, at most 30
  days, `start` at most 90 days ahead) and `"comment"` (non-empty string),
  and that the window overlaps no `planned`/`active` window of the host
  and the host has fewer than 10 `planned` ones
  (`MctlContract.MaintenanceLimits`, through `list_maintenance/2`). A
  window starting in the future must take effect at `start` without
  another call. Returns the
  `Maintenance` (201) or `:not_found` for an unknown host.

  Implement `create_maintenance/3`, `list_maintenance/2` and
  `cancel_maintenance/2` together or none: without them the routes answer
  `404 not_found` and `/me` has no `maintenance` capability.
  """
  @callback create_maintenance(Principal.t(), host_id :: String.t(), params :: map()) ::
              {:ok, map()} | {:error, error()}

  @doc """
  Optional (maintenance): windows paged like the other lists (collection
  `"maintenance"`, filters `host_id`, `state`).
  """
  @callback list_maintenance(Principal.t(), page()) :: list_result()

  @doc """
  Optional (maintenance): cancel window `id`, ending it when active
  (`DELETE /maintenance/{id}`, 204). Cancelling an ended or cancelled
  window is `:ok` too.
  """
  @callback cancel_maintenance(Principal.t(), id :: String.t()) :: :ok | {:error, error()}

  @doc """
  Optional (contract section 10, people; ssm): what the tool knows about a
  person (`GET /people/{key}`, scope `read`). `key` is `oidc:<iss>|<sub>`
  or `email:<address>` (the library checks the form). A map with the keys
  of `Person`; fingerprints only, never key material. `:not_found` when
  the tool knows nothing about the person.

  Implement `get_person/2` and `remove_person/3` together or none:
  without them the routes answer `404 not_found` and `/me` has no
  `people` capability.
  """
  @callback get_person(Principal.t(), key :: String.t()) :: {:ok, map()} | {:error, error()}

  @doc """
  Optional (people): delete the person's authorizations, remove their
  public keys from the managed hosts (all, or `params["hosts"]`, a list of
  host ids), then disable the operator (`POST /people/{key}/remove`, scope
  `commands`). Returns the job (`kind: "remove_person"`, result per host
  `%{"hosts" => [%{"host_id", "ok", "error"}]}`).
  """
  @callback remove_person(Principal.t(), key :: String.t(), params :: map()) ::
              {:ok, job :: map()} | {:error, error()}

  @doc """
  Optional (rename): change the display name of group `slug`
  (`PATCH /groups/{slug}`, scope `setup`). `params` is `%{"name" => name}`
  (the library has checked the shape; the slug never changes). Returns the
  group or `:not_found`; the same name twice is not an error. Without it
  the route answers `404 not_found` and `/me` has no `rename_group`
  capability.
  """
  @callback update_group(Principal.t(), slug :: String.t(), params :: map()) ::
              {:ok, map()} | {:error, error()}

  @doc """
  Optional (merge, contract section 12): merge customer `source` into
  customer `target` (`POST /customers/{slug}/merge`, scope `setup`, body
  `{"into": target}`; the library has checked the shape and that both
  slugs differ). The tool moves every host of `source` to `target`,
  carries over its own rights or memberships of `source` where it has
  them (e.g. the users of a group), then deletes `source`. Returns the
  number of moved hosts.

  Like customer create it needs a GLOBAL token: a token with a binding
  gets `{:error, :forbidden}`. `:not_found` when `source` or `target` is
  unknown (mctl treats `:not_found` for a gone `source` with an existing
  `target` as already merged, so a repeat after success is safe).
  `{:conflict, message}` when the tool cannot merge (the message says
  why, e.g. "source has subfolders"). Without it the route answers
  `404 not_found` and `/me` has no `merge_customer` capability.
  """
  @callback merge_customer(Principal.t(), source :: String.t(), target :: String.t()) ::
              {:ok, %{moved_hosts: non_neg_integer()}} | {:error, error()}

  @optional_callbacks cursor_types: 1,
                      attributes_schema: 0,
                      list_host_summaries: 2,
                      get_host_summary: 2,
                      host_actions: 0,
                      host_action: 3,
                      delete_host: 2,
                      create_maintenance: 3,
                      list_maintenance: 2,
                      cancel_maintenance: 2,
                      get_person: 2,
                      remove_person: 3,
                      update_group: 3,
                      merge_customer: 3
end
