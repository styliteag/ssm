defmodule SsmWeb.MctlProvider do
  @moduledoc """
  ssm's side of the mctl contract v1 (`/api/mctl/v1`, contract-v1 §8):
  hosts with customer/groups and the pinned SSH host key as identity,
  customers and groups (own tables), and `create_host` jobs in the
  library's job store (`mctl_jobs`).

  `create_host` validates and inserts the host (with membership) right
  away — a bad request is a 4xx, never a failed job — then runs the job:
  probe the host key and pin it (`Ssm.Hosts.HostKeys.pin/2`; a pre-seeded
  `attributes.key_fingerprint` is verified, not trusted on first use) and
  learn the machine-id HMAC (`Ssm.Hosts.MachineId`). A failed job deletes
  the host again; a duplicate name/address is a 409 naming the field.
  Writes are audited in the activity log as `mctl:<token name>` with the
  client IP (`principal.ip`).
  """

  @behaviour MctlContract.Provider

  alias MctlContract.Jobs.Ecto, as: Jobs
  alias Ssm.{Activity, Customers, Groups, Hosts}
  alias Ssm.Hosts.{HostKeys, MachineId}
  alias Ssm.Ssh.ErrorCode
  alias SsmWeb.Mctl.{HostParams, HostView}

  require Logger

  @task_supervisor Ssm.Mctl.TaskSupervisor

  @impl true
  def product, do: %{product: "ssm", version: to_string(Application.spec(:ssm, :vsn))}

  @impl true
  def cursor_types(collection) when collection in ~w(hosts jobs), do: [:integer]
  def cursor_types(_collection), do: [:string]

  @impl true
  def attributes_schema, do: HostParams.attributes_schema()

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

  @impl true
  def create_host(principal, params) do
    with {:ok, attrs, membership} <- HostParams.create(params),
         {:ok, host} <- insert_host(attrs, membership) do
      audit(principal, "create", host)

      {:ok, job} =
        Jobs.run("create_host", to_string(host.id), &create_job(host.id, principal, &1),
          task_supervisor: @task_supervisor
        )

      {:ok, Jobs.to_map(job)}
    end
  end

  defp insert_host(attrs, membership) do
    case Hosts.create_host_with_membership(attrs, membership) do
      {:ok, host} -> {:ok, host}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, HostParams.changeset_error(changeset)}
      {:error, {:validation, _}} = error -> error
    end
  end

  @impl true
  def update_host(principal, id, params) do
    with {:ok, host} <- fetch_host(id),
         {:ok, updated} <- update_membership(host, HostParams.membership(params)) do
      audit(principal, "update", updated)
      {:ok, HostView.render(updated)}
    end
  end

  defp update_membership(host, attrs) do
    case Hosts.update_membership(host, attrs) do
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

  # The create_host job's work. A failed job removes the host again, so the
  # same name/address can be posted again (no orphan row with a rejected pin).
  defp create_job(host_id, principal, job_id) do
    case pin_job(host_id, principal, job_id) do
      {:ok, _} = ok ->
        ok

      {:error, _code, _message} = failure ->
        roll_back(host_id, principal)
        failure
    end
  end

  defp roll_back(host_id, principal) do
    with %{} = host <- Hosts.get_host(host_id),
         {:ok, _} <- Hosts.delete_host(host) do
      audit(principal, "create_rolled_back", host)
    end

    :ok
  end

  # Pin the new host's key (the only TOFU path).
  defp pin_job(host_id, principal, job_id) do
    case Hosts.get_host(host_id) do
      nil ->
        {:error, "not_found", "the host was deleted before its key was pinned"}

      %{disabled: true} ->
        {:ok, %{"pin" => "skipped_disabled", "ssh_host_key" => nil}}

      host ->
        Jobs.progress(job_id, "probing SSH host key")
        pin_result(HostKeys.pin(host, actor: actor(principal), ip: principal.ip))
    end
  end

  defp pin_result({:ok, status, host}) do
    # identity-claims-v1: learn the machine-id HMAC now that the key is
    # pinned and SSH is allowed; a failure never fails the job.
    host = MachineId.refresh(host, [])
    {:ok, %{"pin" => Atom.to_string(status), "ssh_host_key" => host.key_fingerprint}}
  end

  defp pin_result({:error, {:host_key_changed, %{pinned: pinned, offered: offered}}}) do
    {:error, "host_key_changed",
     "host key differs from the pinned one: pinned #{pinned}, offered #{offered.fingerprint}"}
  end

  # Raw SSH detail (addresses, Erlang terms) goes to the log only; the
  # client gets a short code and a fixed sentence.
  defp pin_result({:error, reason}) do
    {code, message} = ErrorCode.classify(reason)
    Logger.warning("mctl create_host: host key probe failed (#{code}): #{inspect(reason)}")
    {:error, code, message}
  end

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
  def update_customer(_principal, slug, params) do
    case Customers.get_customer_by_slug(slug) do
      nil -> {:error, :not_found}
      customer -> customer |> Customers.update_customer(named_attrs(params)) |> named_result()
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

  defp actor(principal), do: "mctl:#{principal.name}"

  defp audit(principal, action, host) do
    Activity.log(%{
      activity_type: "host",
      action: action,
      target: host.name,
      actor_username: actor(principal),
      details: %{address: host.address, port: host.port, via: "mctl", ip: principal.ip}
    })
  end
end
