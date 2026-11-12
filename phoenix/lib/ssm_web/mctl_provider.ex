defmodule SsmWeb.MctlProvider do
  @moduledoc """
  ssm's side of the mctl contract v1 (`/api/mctl/v1`, contract-v1 §8):
  hosts with customer/groups and the pinned SSH host key as identity,
  customers and groups (own tables), `create_host` jobs in the library's
  job store (`mctl_jobs`), host summaries (C4) from the persisted
  periodic key check (`Ssm.Diffs.HostChecks`, table `host_checks`),
  `delete_host`, `rename_group` (§11), `merge_customer` (§12), `delete_group`, `delete_customer`,
  `probe_ssh` (SSH reachability as seen from ssm, `SsmWeb.Mctl.Probe`) and people (offboarding,
  `SsmWeb.Mctl.People`). No maintenance capability: ssm has no alerts to
  silence.

  `create_host` validates and inserts the host (with membership) right
  away — a bad request is a 4xx, never a failed job — then runs the job
  (`SsmWeb.Mctl.CreateHostJob`): hand out `ssm_public_key`, wait for the
  login to work, pin the host key (a pre-seeded `attributes.key_fingerprint`
  is verified, not trusted on first use) and learn the machine-id HMAC. A
  failed job deletes the host again; a duplicate name/address is a 409
  naming the field.
  Writes are audited in the activity log as `mctl:<token name>` with the
  client IP (`principal.ip`).
  """

  @behaviour MctlContract.Provider

  alias MctlContract.Jobs.Ecto, as: Jobs
  alias Ssm.{Customers, Groups, Hosts}
  alias Ssm.Diffs.HostChecks
  alias SsmWeb.Mctl.{Audit, CreateHostJob, HostParams, HostView, People, SummaryView}

  @task_supervisor Ssm.Mctl.TaskSupervisor

  @impl true
  def product, do: %{product: "ssm", version: to_string(Application.spec(:ssm, :vsn))}

  @impl true
  def cursor_types(collection) when collection in ~w(hosts host_summaries jobs), do: [:integer]
  def cursor_types(_collection), do: [:string]

  @impl true
  def attributes_schema, do: HostParams.attributes_schema()

  # ssm connects to the host itself: pull only (others are refused with 422)
  @impl true
  def modes, do: ["pull"]

  ## Hosts

  @impl true
  def list_hosts(_principal, %{after: after_key, limit: limit, filters: filters}) do
    {hosts, next} =
      Hosts.page_hosts(first(after_key), limit, %{
        customer: filters["customer"],
        group: filters["group"],
        changed_after: filters["changed_after"]
      })

    {:ok, Enum.map(hosts, &HostView.render/1), next && [next]}
  end

  @impl true
  def get_host(_principal, id) do
    with {:ok, host} <- fetch_host(id), do: {:ok, HostView.render(host)}
  end

  # C4 host summaries: from the persisted periodic key check

  @impl true
  def list_host_summaries(_principal, %{after: after_key, limit: limit, filters: filters}) do
    case summary_filters(filters) do
      {:ok, parsed} ->
        {rows, next} = HostChecks.page_summaries(first(after_key), limit, parsed)
        {:ok, Enum.map(rows, &SummaryView.render/1), next && [next]}

      :none ->
        {:ok, [], nil}
    end
  end

  @impl true
  def get_host_summary(_principal, id) do
    with {:ok, int} <- HostParams.parse_id(id),
         %{} = row <- HostChecks.get_summary_row(int) do
      {:ok, SummaryView.render(row)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp summary_filters(filters) do
    case filters["host_id"] do
      nil ->
        {:ok, %{changed_after: filters["changed_after"]}}

      raw ->
        case HostParams.parse_id(raw) do
          {:ok, id} -> {:ok, %{host_id: id, changed_after: filters["changed_after"]}}
          :error -> :none
        end
    end
  end

  @impl true
  def create_host(principal, params) do
    with {:ok, attrs, membership} <- HostParams.create(params),
         {:ok, attrs} <- HostParams.resolve_jump(attrs),
         {:ok, host} <- insert_host(attrs, membership, ctx(principal)) do
      audit(principal, "create", host)

      {:ok, job} =
        Jobs.run("create_host", to_string(host.id), &CreateHostJob.run(host.id, principal, &1),
          task_supervisor: @task_supervisor
        )

      {:ok, Jobs.to_map(job)}
    end
  end

  defp insert_host(attrs, membership, ctx) do
    case Hosts.create_host_with_membership(attrs, membership, ctx) do
      {:ok, host} -> {:ok, host}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, HostParams.changeset_error(changeset)}
      {:error, {:validation, _}} = error -> error
    end
  end

  @impl true
  def update_host(principal, id, params) do
    with {:ok, host} <- fetch_host(id),
         {:ok, updated} <- update_membership(host, HostParams.membership(params), ctx(principal)) do
      audit(principal, "update", updated)
      {:ok, HostView.render(updated)}
    end
  end

  defp update_membership(host, attrs, ctx) do
    case Hosts.update_membership(host, attrs, ctx) do
      {:ok, host} -> {:ok, host}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, HostParams.changeset_error(changeset)}
      {:error, {:validation, _}} = error -> error
    end
  end

  defp fetch_host(id) do
    with {:ok, int} <- HostParams.parse_id(id),
         %{} = host <- Hosts.get_host_with_membership(int) do
      {:ok, host}
    else
      _ -> {:error, :not_found}
    end
  end

  # Contract section 10. The host row goes with its authorizations and
  # checks (ON DELETE CASCADE); keys on the host itself stay untouched (it
  # may be gone). A jump host still in use is refused: the cascade would
  # delete the hosts behind it.
  @impl true
  def delete_host(principal, id) do
    with {:ok, host} <- fetch_host(id),
         [] <- Hosts.jump_dependents(host),
         {:ok, _deleted} <- Hosts.delete_host(host, ctx(principal)) do
      audit(principal, "delete", host)

      {:ok, job} =
        Jobs.run("delete_host", to_string(host.id), fn _ -> {:ok, %{"deleted" => true}} end,
          inline: true
        )

      {:ok, Jobs.to_map(job)}
    else
      {:error, :not_found} = error -> error
      [_ | _] = names -> {:error, {:conflict, "jump host of #{Enum.join(names, ", ")}"}}
      {:error, %Ecto.Changeset{}} -> {:error, {:conflict, "host cannot be deleted"}}
    end
  end

  ## People (offboarding, SsmWeb.Mctl.People)

  @impl true
  def get_person(_principal, key), do: People.get(key)

  @impl true
  def remove_person(principal, key, params), do: People.remove(principal, key, params)

  ## Customers and groups

  @impl true
  def list_customers(_principal, %{after: after_key, limit: limit}) do
    {items, next} = Customers.page_customers(first(after_key), limit)
    {:ok, Enum.map(items, &named/1), next && [next]}
  end

  @impl true
  def create_customer(_principal, params) do
    params |> named_attrs() |> Customers.create_customer() |> named_result()
  end

  @impl true
  def update_customer(principal, slug, params) do
    case Customers.get_customer_by_slug(slug) do
      nil ->
        {:error, :not_found}

      customer ->
        customer
        |> Customers.update_customer(named_attrs(params), ctx(principal))
        |> named_result()
    end
  end

  @impl true
  def list_groups(_principal, %{after: after_key, limit: limit}) do
    {items, next} = Groups.page_groups(first(after_key), limit)
    {:ok, Enum.map(items, &named/1), next && [next]}
  end

  @impl true
  def create_group(_principal, params) do
    params |> named_attrs() |> Groups.create_group() |> named_result()
  end

  # contract section 12 (capability `merge_customer`): ssm has no token
  # binding, so every `setup` token may merge (like create_customer)
  @impl true
  def merge_customer(principal, source, target) do
    with {:ok, result} <- Customers.merge_customer(source, target, ctx(principal)) do
      Audit.customer(principal, "merge", source, %{into: target, moved_hosts: result.moved_hosts})
      {:ok, result}
    end
  end

  # contract section 11 (capability `rename_group`): the name only, the
  # slug is fixed after create
  @impl true
  def update_group(principal, slug, params) do
    case Groups.get_group_by_slug(slug) do
      nil -> {:error, :not_found}
      group -> group |> Groups.update_group(named_attrs(params), ctx(principal)) |> named_result()
    end
  end

  # contract 0.3.0 (capability `delete_group`): unused groups only; ssm has
  # no token binding, so every `setup` token may delete (like create_group)
  @impl true
  def delete_group(principal, slug) do
    with :ok <- Groups.delete_group(slug, ctx(principal)) do
      Audit.group(principal, "delete", slug)
      :ok
    end
  end

  # contract 0.4.0 (capability `delete_customer`): empty customers only; no
  # token binding in ssm, so every `setup` token may delete (like create)
  @impl true
  def delete_customer(principal, slug) do
    with :ok <- Customers.delete_customer(slug, ctx(principal)) do
      Audit.customer(principal, "delete", slug)
      :ok
    end
  end

  # contract 0.5.0 (capability `probe_ssh`): can ssm reach address:port and
  # does SSH answer there, directly or via a jump host (SsmWeb.Mctl.Probe)
  @impl true
  def probe_ssh(principal, params), do: SsmWeb.Mctl.Probe.run(principal, params)

  defp named_attrs(params), do: %{slug: params["slug"], name: params["name"]}
  defp named(item), do: %{slug: item.slug, name: item.name}

  defp named_result({:ok, item}), do: {:ok, named(item)}

  defp named_result({:error, %Ecto.Changeset{errors: errors}}) do
    if Enum.any?(errors, fn {_field, {_msg, meta}} -> meta[:constraint] == :unique end) do
      {:error, :conflict}
    else
      {:error,
       {:validation, Enum.group_by(errors, &to_string(elem(&1, 0)), fn {_f, {msg, _}} -> msg end)}}
    end
  end

  ## Jobs

  @impl true
  def get_job(_principal, id) do
    with {:ok, job} <- Jobs.get(id), do: {:ok, Jobs.to_map(job)}
  end

  @impl true
  def list_jobs(_principal, page) do
    {:ok, jobs, next} = Jobs.list(page)
    {:ok, Enum.map(jobs, &Jobs.to_map/1), next}
  end

  ## Helpers

  defp first(nil), do: nil
  defp first([key | _]), do: key

  defp audit(principal, action, host), do: Audit.host(principal, action, host)

  # grant reconcile context (ADR-0012 §10): the contract actor; these calls
  # run before any contract job exists, so no job id
  defp ctx(principal), do: %{actor: Audit.actor(principal), job_id: nil}
end
