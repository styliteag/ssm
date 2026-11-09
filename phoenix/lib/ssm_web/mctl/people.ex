defmodule SsmWeb.Mctl.People do
  @moduledoc """
  People of the mctl contract (section 10, capability `people`): what ssm
  knows about a person (`Ssm.People`) and offboarding.

  `remove/3` changes the database only — it never writes to a host (in ssm
  only a user's "Sync" does that). It deletes the person's authorizations
  (all hosts, or `params["hosts"]`), without `hosts` also the shared keys
  (other users' keys carrying the person's e-mail), and disables the
  operator. Every host that loses access is marked "revocation pending"
  (`Ssm.Diffs.Revocations`) until a sync. The `remove_person` job result
  keeps the contract shape: `%{"hosts" => [] (nothing written),
  "pending_keys" => [], "kept_shared_keys" => [fingerprint],
  "revocation_pending" => [host_id]}`.

  Key material never leaves ssm: the person is described by fingerprints.
  """

  alias MctlContract.Jobs.Ecto, as: Jobs
  alias Ssm.{Accounts, Activity, People}
  alias SsmWeb.Mctl.{Audit, HostParams}

  @task_supervisor Ssm.Mctl.TaskSupervisor

  @doc "`{:ok, person}` (contract `Person`), `{:error, :not_found}` or a conflict."
  def get(key) do
    with {:ok, match} <- People.find(key), do: {:ok, render(match)}
  end

  @doc """
  `{:ok, job}`, `{:error, :not_found}`, a conflict (ambiguous `email:` key)
  or a validation error on `hosts`. Database only; see the moduledoc.
  With `hosts` the shared keys stay (a shared key cannot leave single hosts
  only) and are reported as `kept_shared_keys`.
  """
  def remove(principal, key, params) do
    with {:ok, match} <- People.find(key),
         {:ok, host_ids} <- host_ids(params["hosts"]) do
      plan = plan(match, host_ids)

      {:ok, touched} =
        People.remove_authorizations(match, host_ids, %{actor: Audit.actor(principal)})

      audit(principal, match, host_ids)
      work = fn _job_id -> run(match, plan, touched) end

      {:ok, job} = Jobs.run("remove_person", nil, work, task_supervisor: @task_supervisor)
      {:ok, Jobs.to_map(job)}
    end
  end

  # computed before the authorizations go
  defp plan(match, host_ids) do
    %{
      shared: if(host_ids, do: [], else: match.shared_keys),
      kept: if(host_ids, do: match.shared_keys, else: [])
    }
  end

  defp host_ids(nil), do: {:ok, nil}

  defp host_ids(ids) do
    parsed = Enum.map(ids, &HostParams.parse_id/1)

    if Enum.all?(parsed, &match?({:ok, _}, &1)),
      do: {:ok, parsed |> Enum.map(fn {:ok, id} -> id end) |> Enum.uniq()},
      else: {:error, {:validation, %{"hosts" => ["must be host ids"]}}}
  end

  # database only: shared keys go now (their hosts are marked by
  # People.delete_keys/1), the operator is disabled; nothing is written
  defp run(match, plan, touched) do
    _ = if plan.shared != [], do: People.delete_keys(Enum.map(plan.shared, & &1.id))
    _ = disable_operator(match.operator)

    {:ok,
     %{
       "hosts" => [],
       "pending_keys" => [],
       "kept_shared_keys" => fingerprints(plan.kept),
       "revocation_pending" => touched |> Enum.uniq() |> Enum.map(&to_string/1)
     }}
  end

  defp fingerprints(keys), do: Enum.map(keys, &People.fingerprint(&1.key_base64))

  defp disable_operator(nil), do: :ok
  defp disable_operator(%{disabled_at: at}) when not is_nil(at), do: :ok
  defp disable_operator(operator), do: Accounts.set_disabled(operator, true)

  @doc "The contract `Person` of a match: fingerprints and comments only."
  def render(%People.Match{} = match) do
    %{
      key: match.key,
      operator: operator(match.operator),
      emails: List.wrap(match.email),
      keys:
        Enum.map(People.all_keys(match), fn k ->
          %{
            fingerprint: People.fingerprint(k.key_base64),
            comment: k.name,
            hosts: People.key_hosts(k),
            matched_by: People.key_reason(match, k)
          }
        end),
      authorizations:
        Enum.map(People.authorizations(match), fn a ->
          %{
            host_id: a.host_id,
            remote_user: a.login,
            matched_by: People.authorization_reason(match, a)
          }
        end)
    }
  end

  defp operator(nil), do: nil

  defp operator(op) do
    %{
      "id" => op.id,
      "name" => op.name,
      "email" => op.email,
      "verified_email" => op.verified_email,
      "role" => op.role,
      "disabled" => op.disabled_at != nil
    }
  end

  defp audit(principal, match, host_ids) do
    Activity.log(%{
      activity_type: "user",
      action: "mctl_remove_person",
      target: match.key,
      actor_username: Audit.actor(principal),
      details: %{
        via: "mctl",
        ip: principal.ip,
        hosts: host_ids || "all",
        keys: fingerprints(People.all_keys(match))
      }
    })
  end
end
