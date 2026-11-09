defmodule Ssm.Hosts.ManagedLogins do
  @moduledoc """
  Pruning of `managed_logins` (`Ssm.Authorizations.ManagedLogin`): a sync
  keeps rewriting the file of every login that ever held a grant on a host,
  so a revocation reaches it. `forget/4` removes such a row once nothing is
  left to revoke: the login has no authorization on the host and the host
  has no `authorized_keys` for it (asked fresh through `script.sh
  has_keyfile`; a link counts as a file; a login the host cannot resolve
  or whose home is missing is never forgotten — ssm cannot tell — unless the
  caller passes `unknown_login: :forget` and a fresh listing says the host
  does not know the login (`home_state` `unknown_login`; a missing or
  unreadable home is still refused). That is an admin's explicit choice in
  the diff page ("Remove login from host"): a directory outage
  (LDAP/AD/SSSD) looks the same, and a file that comes back with the login
  is then no longer emptied by a sync. A disabled host is never
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
  alias Ssm.Hosts.{Host, WriteLock}
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

  Option `unknown_login: :forget` also forgets a login the host reports
  unknown (see the moduledoc); the audit entry then carries
  `login_unknown_on_host: true`.
  """
  @spec forget(module(), Host.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def forget(client \\ Ssm.Ssh, %Host{} = host, login, actor, opts \\ []) do
    unknown? = Keyword.get(opts, :unknown_login) == :forget

    with true <- managed?(host.id, login) || {:error, :managed_login_not_found} do
      result = do_forget(host, client, login, unknown?)
      audit(result, host, login, actor)

      case result do
        {:ok, login, _how} -> {:ok, login}
        {:error, _} = error -> error
      end
    end
  end

  # The host is asked twice: once up front, then again under the host's
  # write lock right before the delete — no sync, removal or offboarding of
  # ssm can create the file in between. A file created on the host by
  # someone else after that last answer is not seen (residual race,
  # AGENTS.md).
  defp do_forget(host, client, login, unknown?) do
    with :ok <- no_authorizations(host.id, login),
         :ok <- ensure_enabled(host),
         {:ok, _how} <- no_file(client, host, login, unknown?) do
      WriteLock.run(host.id, fn ->
        with {:ok, how} <- no_file(client, host, login, unknown?),
             {:ok, login} <- delete(host.id, login),
             do: {:ok, login, how}
      end)
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

  # {:ok, :no_file} | {:ok, :unknown_login} (only with `unknown?`) | {:error, _}
  defp no_file(client, host, login, unknown?) do
    case ScriptRunner.has_keyfile(client, Hosts.target_for(host), login) do
      {:ok, false} ->
        {:ok, :no_file}

      {:ok, true} ->
        {:error,
         {:conflict,
          "#{inspect(login)} still has an authorized_keys on #{inspect(host.name)}; " <>
            "a sync keeps it empty — remove the file on the host first"}}

      {:error, _} = error when unknown? ->
        unknown_login(client, host, login, error)

      {:error, _} = error ->
        error
    end
  end

  # has_keyfile answers "unknown" for an unknown login and a missing home
  # alike; the listing tells them apart. Anything but `unknown_login` keeps
  # the original error.
  defp unknown_login(client, host, login, error) do
    case ScriptRunner.get_ssh_keyfiles(client, Hosts.target_for(host), [login]) do
      {:ok, entries} ->
        if Enum.any?(entries, &(&1.login == login and &1.home_state == "unknown_login")),
          do: {:ok, :unknown_login},
          else: error

      {:error, _} ->
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
      action: if(match?({:ok, _, _}, result), do: "forget_login", else: "forget_login_failed"),
      target: host.name,
      host_id: host.id,
      actor_username: actor,
      details: details(result, login)
    })
  end

  defp details({:ok, _, :unknown_login}, login), do: %{login: login, login_unknown_on_host: true}
  defp details({:ok, _, _how}, login), do: %{login: login}

  defp details({:error, {_tag, message}}, login),
    do: %{login: login, error: String.slice(message, 0, 500)}
end
