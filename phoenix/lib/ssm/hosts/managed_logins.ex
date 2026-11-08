defmodule Ssm.Hosts.ManagedLogins do
  @moduledoc """
  Pruning of `managed_logins` (`Ssm.Authorizations.ManagedLogin`): a sync
  keeps rewriting the file of every login that ever held a grant on a host,
  so a revocation reaches it. `forget/4` removes such a row once nothing is
  left to revoke: the login has no authorization on the host and the host
  has no `authorized_keys` for it (asked fresh through `script.sh
  has_keyfile`; a link counts as a file; a login the host cannot resolve
  or whose home is missing is never forgotten — ssm cannot tell). A disabled host is never
  contacted. The check of the authorizations and the delete run in one
  IMMEDIATE transaction, after the host answered.

  Admin only — the hosts page checks the role, `/api/v2` is global. Every
  attempt is audit-logged (`activity_type` `host`, action `forget_login` or
  `forget_login_failed`).
  """

  import Ecto.Query

  alias Ssm.Activity
  alias Ssm.Authorizations.{Authorization, ManagedLogin}
  alias Ssm.Hosts
  alias Ssm.Hosts.Host
  alias Ssm.Repo
  alias Ssm.Ssh.ScriptRunner

  @doc "The managed logins of a host with their number of authorizations, by login."
  @spec list(integer()) :: [%{login: String.t(), authorizations: non_neg_integer()}]
  def list(host_id) do
    counts =
      from(a in Authorization,
        where: a.host_id == ^host_id,
        group_by: a.login,
        select: {a.login, count(a.id)}
      )
      |> Repo.all()
      |> Map.new()

    from(m in ManagedLogin, where: m.host_id == ^host_id, order_by: m.login, select: m.login)
    |> Repo.all()
    |> Enum.map(&%{login: &1, authorizations: Map.get(counts, &1, 0)})
  end

  @doc """
  Forget `login` on `host`: `{:ok, login}`, or `{:error, reason}` with
  `:managed_login_not_found`, `{:conflict, message}` (authorizations left,
  or a file on the host), `{:host_disabled, message}` or
  `{:ssh_connect_failed, message}`.
  """
  @spec forget(module(), Host.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def forget(client \\ Ssm.Ssh, %Host{} = host, login, actor) do
    with true <- managed?(host.id, login) || {:error, :managed_login_not_found} do
      host
      |> do_forget(client, login)
      |> tap(&audit(&1, host, login, actor))
    end
  end

  defp do_forget(host, client, login) do
    with :ok <- no_authorizations(host.id, login),
         :ok <- ensure_enabled(host),
         :ok <- no_file(client, host, login) do
      delete(host.id, login)
    end
  end

  defp managed?(host_id, login),
    do: Repo.exists?(from m in ManagedLogin, where: m.host_id == ^host_id and m.login == ^login)

  defp no_authorizations(host_id, login) do
    case Repo.aggregate(authorizations(host_id, login), :count) do
      0 ->
        :ok

      n ->
        {:error,
         {:conflict,
          "#{inspect(login)} still has #{n} authorization(s) on this host; revoke them first"}}
    end
  end

  defp authorizations(host_id, login),
    do: from(a in Authorization, where: a.host_id == ^host_id and a.login == ^login)

  defp ensure_enabled(%Host{disabled: true, name: name}),
    do: {:error, {:host_disabled, "host #{inspect(name)} is disabled"}}

  defp ensure_enabled(_host), do: :ok

  defp no_file(client, host, login) do
    case ScriptRunner.has_keyfile(client, Hosts.target_for(host), login) do
      {:ok, false} ->
        :ok

      {:ok, true} ->
        {:error,
         {:conflict,
          "#{inspect(login)} still has an authorized_keys on #{inspect(host.name)}; " <>
            "a sync keeps it empty — remove the file on the host first"}}

      {:error, _} = error ->
        error
    end
  end

  # a grant created meanwhile keeps the login managed
  defp delete(host_id, login) do
    Repo.transaction(
      fn ->
        if Repo.exists?(authorizations(host_id, login)) do
          Repo.rollback({:conflict, "#{inspect(login)} was granted meanwhile; not forgotten"})
        else
          Repo.delete_all(
            from m in ManagedLogin, where: m.host_id == ^host_id and m.login == ^login
          )

          login
        end
      end,
      mode: :immediate
    )
  end

  defp audit(result, host, login, actor) do
    Activity.log(%{
      activity_type: "host",
      action: if(match?({:ok, _}, result), do: "forget_login", else: "forget_login_failed"),
      target: host.name,
      host_id: host.id,
      actor_username: actor,
      details: details(result, login)
    })
  end

  defp details({:ok, _}, login), do: %{login: login}

  defp details({:error, {_tag, message}}, login),
    do: %{login: login, error: String.slice(message, 0, 500)}
end
