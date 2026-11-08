defmodule Ssm.Authorizations do
  @moduledoc """
  User↔host grants under a remote login — the context behind
  `/api/v2/authorizations` and the Authorizations page.

  Functions that take an `Ssm.Scope` first serve the web UI (ADR-0012): rows
  on out-of-scope hosts are invisible, and a write that names such a host is
  refused like a missing host. The scope-less ones are global (`/api/v2`,
  mctl contract).
  """

  import Ecto.Query

  alias Ssm.Authorizations.{Authorization, ManagedLogin, Options}
  alias Ssm.Diffs.Revocations
  alias Ssm.Grants.Expansion
  alias Ssm.{Repo, Scope}

  @spec list_authorizations(keyword()) :: [Authorization.t()]
  def list_authorizations(opts \\ []), do: list_authorizations(Scope.global(), opts)

  @doc "Grants on hosts in `scope`; `opts` filter by `:host_id` / `:user_id`."
  @spec list_authorizations(Scope.t(), keyword()) :: [Authorization.t()]
  def list_authorizations(%Scope{} = scope, opts) do
    query =
      from(a in Authorization, order_by: a.id, preload: [:user, :host])
      |> Scope.filter(scope)

    query =
      Enum.reduce(opts, query, fn
        {:host_id, host_id}, q -> where(q, [a], a.host_id == ^host_id)
        {:user_id, user_id}, q -> where(q, [a], a.user_id == ^user_id)
        _other, q -> q
      end)

    Repo.all(query)
  end

  @spec count_authorizations(Scope.t()) :: non_neg_integer()
  def count_authorizations(%Scope{} = scope \\ Scope.global()),
    do: Authorization |> Scope.filter(scope) |> Repo.aggregate(:count)

  @spec get_authorization(integer()) :: Authorization.t() | nil
  def get_authorization(id), do: Repo.get(Authorization, id)

  @doc "A grant on a host in `scope`, or nil."
  @spec get_authorization(Scope.t(), term()) :: Authorization.t() | nil
  def get_authorization(%Scope{} = scope, id) when is_integer(id),
    do: Authorization |> Scope.filter(scope) |> Repo.get(id)

  def get_authorization(_scope, _id), do: nil

  @doc "True when a grant with exactly this (user, host, login) exists."
  @spec exists?(integer(), integer(), String.t()) :: boolean()
  def exists?(user_id, host_id, login) do
    Repo.exists?(
      from a in Authorization,
        where: a.user_id == ^user_id and a.host_id == ^host_id and a.login == ^login
    )
  end

  @doc "Fetch the grant for exactly this (user, host, login) on a host in `scope`, or nil."
  @spec get_by_grant(Scope.t(), integer(), integer(), String.t()) :: Authorization.t() | nil
  def get_by_grant(%Scope{} = scope, user_id, host_id, login) do
    Authorization
    |> Scope.filter(scope)
    |> Repo.get_by(user_id: user_id, host_id: host_id, login: login)
  end

  @doc """
  The subset of `user_ids × host_ids` pairs that already hold a grant under
  `login`, as a MapSet of `{user_id, host_id}` tuples.
  """
  @spec existing_grant_pairs([integer()], [integer()], String.t()) :: MapSet.t()
  def existing_grant_pairs(user_ids, host_ids, login) do
    from(a in Authorization,
      where: a.user_id in ^user_ids and a.host_id in ^host_ids and a.login == ^login,
      select: {a.user_id, a.host_id}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "`existing_grant_pairs/3` limited to hosts in `scope`."
  @spec existing_grant_pairs(Scope.t(), [integer()], [integer()], String.t()) :: MapSet.t()
  def existing_grant_pairs(%Scope{} = scope, user_ids, host_ids, login) do
    from(a in Authorization,
      where: a.user_id in ^user_ids and a.host_id in ^host_ids and a.login == ^login,
      select: {a.user_id, a.host_id}
    )
    |> Scope.filter(scope)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Grant `login` (with optional `options`) to every user in `user_ids` on every
  host in `host_ids`. Pairs that already hold an identical (user, host, login)
  grant are skipped. Runs in one transaction: any changeset failure rolls the
  whole batch back and returns `{:error, changeset}`.

  Returns `{:ok, %{created: [auth], skipped: n}}` on success. With a scope,
  a host outside it refuses the whole batch: `{:error, :out_of_scope}`, and
  permissive options need `role: "admin"` in `opts` (else `{:error,
  changeset}` with an `:options` error, nothing created).
  """
  @spec bulk_grant(Scope.t(), [integer()], [integer()], String.t(), String.t() | nil, keyword()) ::
          {:ok, %{created: [Authorization.t()], skipped: non_neg_integer()}}
          | {:error, Ecto.Changeset.t() | :out_of_scope}
  def bulk_grant(%Scope{} = scope, user_ids, host_ids, login, options, opts \\ []) do
    cond do
      not Scope.all_in_scope?(scope, host_ids) ->
        {:error, :out_of_scope}

      Options.admin_only(options) != [] and opts[:role] != "admin" ->
        {:error, role_error(options)}

      true ->
        bulk_grant(user_ids, host_ids, login, options)
    end
  end

  defp role_error(options) do
    %Authorization{}
    |> Ecto.Changeset.change(%{options: options})
    |> Ecto.Changeset.add_error(:options, Options.role_message(Options.admin_only(options)))
  end

  @spec bulk_grant([integer()], [integer()], String.t(), String.t() | nil) ::
          {:ok, %{created: [Authorization.t()], skipped: non_neg_integer()}}
          | {:error, Ecto.Changeset.t()}
  def bulk_grant(user_ids, host_ids, login, options \\ nil) do
    existing = existing_grant_pairs(user_ids, host_ids, login)
    pairs = for user_id <- user_ids, host_id <- host_ids, do: {user_id, host_id}
    new_pairs = Enum.reject(pairs, &MapSet.member?(existing, &1))

    Ssm.Grants.transaction(fn ->
      created =
        Enum.map(new_pairs, fn {user_id, host_id} ->
          attrs = %{user_id: user_id, host_id: host_id, login: login, options: options}

          case create_authorization(attrs) do
            {:ok, auth} -> auth
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      %{created: created, skipped: length(pairs) - length(new_pairs)}
    end)
  end

  @doc """
  Create a grant and record its login as managed (`managed_logins`) in the
  same transaction — every creation path (UI, `/api/v2`, `bulk_grant/4`,
  key assignment, diff page "Allow") goes through here.
  """
  @spec create_authorization(map()) :: {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()}
  def create_authorization(attrs),
    do: %Authorization{} |> Authorization.changeset(attrs) |> write_managed(&Repo.insert/1)

  @doc """
  `create_authorization/1` for a web user: a host outside `scope` is
  refused like a missing one (`host_id` "does not exist"). `opts[:role]`
  is the web user's role: only `"admin"` may set permissive options
  (`Options.validate_role/2`); without a role the check fails closed.
  """
  @spec create_authorization(Scope.t(), map(), keyword()) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t()}
  def create_authorization(%Scope{} = scope, attrs, opts \\ []) do
    %Authorization{}
    |> Authorization.changeset(attrs)
    |> Options.validate_role(opts[:role])
    |> check_scope(scope)
    |> write_managed(&Repo.insert/1)
  end

  @doc """
  `update_authorization/2` for a web user: old and new host must be in
  `scope`; `opts[:role]` as in `create_authorization/3`. A row made by a
  grant is read-only (`{:error, :grant_row}`).
  """
  @spec update_authorization(Scope.t(), Authorization.t(), map(), keyword()) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t() | :grant_row}
  def update_authorization(scope, auth, attrs, opts \\ [])

  def update_authorization(%Scope{}, %Authorization{grant_id: grant_id}, _attrs, _opts)
      when not is_nil(grant_id),
      do: {:error, :grant_row}

  def update_authorization(%Scope{} = scope, %Authorization{} = auth, attrs, opts) do
    changeset =
      auth
      |> Authorization.changeset(attrs)
      |> Options.validate_role(opts[:role])
      |> check_scope(scope)

    if Scope.in_scope?(scope, auth.host_id),
      do: write_managed(changeset, &Repo.update/1, auth.host_id),
      else: {:error, Ecto.Changeset.add_error(changeset, :host_id, "does not exist")}
  end

  @doc "`delete_authorization/1` for a web user: the grant's host must be in `scope`."
  @spec delete_authorization(Scope.t(), Authorization.t()) ::
          {:ok, Authorization.t()} | {:error, :not_found | :grant_row | Ecto.Changeset.t()}
  def delete_authorization(%Scope{} = scope, %Authorization{} = auth) do
    if Scope.in_scope?(scope, auth.host_id),
      do: delete_authorization(auth),
      else: {:error, :not_found}
  end

  defp check_scope(changeset, scope) do
    host_id = Ecto.Changeset.get_field(changeset, :host_id)

    if is_nil(host_id) or Scope.in_scope?(scope, host_id),
      do: changeset,
      else: Ecto.Changeset.add_error(changeset, :host_id, "does not exist")
  end

  @doc """
  Update a grant; a new host/login pair is recorded as managed too. A row
  made by a grant (`grant_id`) is read-only: `{:error, :grant_row}`. The
  old host is reconciled in the same transaction (a grant row comes back
  when this manual row had won over a grant).
  """
  @spec update_authorization(Authorization.t(), map()) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t() | :grant_row}
  def update_authorization(%Authorization{grant_id: grant_id}, _attrs) when not is_nil(grant_id),
    do: {:error, :grant_row}

  def update_authorization(%Authorization{} = auth, attrs),
    do: auth |> Authorization.changeset(attrs) |> write_managed(&Repo.update/1, auth.host_id)

  # an invalid changeset never reaches the DB: no transaction, so a caller's
  # outer transaction is not rolled back by a plain validation error
  defp write_managed(changeset, write, reconcile_host_id \\ nil)

  defp write_managed(%Ecto.Changeset{valid?: false} = changeset, write, _host_id),
    do: write.(changeset)

  defp write_managed(changeset, write, reconcile_host_id) do
    Ssm.Grants.transaction(fn ->
      with :ok <- ensure_manual(reconcile_host_id, changeset.data),
           {:ok, auth} <- write.(changeset),
           :ok <- mark_reduced(changeset.data, auth),
           :ok <- record_managed_login(auth.host_id, auth.login),
           {:ok, _} <- reconcile_after_manual(reconcile_host_id, auth) do
        auth
      else
        {:error, failed} -> Repo.rollback(failed)
      end
    end)
  end

  # an update re-reads the row in the write transaction: a stale struct must
  # not overwrite a row that is (now) made by a grant
  defp ensure_manual(nil, _data), do: :ok

  defp ensure_manual(_host_id, %Authorization{id: id}) do
    case Repo.one(from a in Authorization, where: a.id == ^id, select: a.grant_id) do
      nil -> :ok
      _grant_id -> {:error, :grant_row}
    end
  end

  # a row that leaves its (user, host, login) takes that access away, and so
  # do options that grant less than before (a restriction added or changed,
  # a permissive option removed): the old host is "revocation pending"
  # (ADR-0012 §6). A new row has no old place.
  defp mark_reduced(%Authorization{id: nil}, _auth), do: :ok

  defp mark_reduced(%Authorization{} = old, auth) do
    cond do
      {old.user_id, old.host_id, old.login} != {auth.user_id, auth.host_id, auth.login} ->
        Revocations.mark(old.host_id, "authorization moved")

      Options.weaker?(old.options, auth.options) ->
        Revocations.mark(old.host_id, "authorization options restricted")

      true ->
        :ok
    end
  end

  defp reconcile_after_manual(nil, _auth), do: {:ok, nil}

  defp reconcile_after_manual(host_id, auth),
    do: Expansion.reconcile([host_id, auth.host_id], %{trigger: "authorization_update"})

  @doc """
  Mark `login` on `host_id` as managed by ssm (idempotent). A sync keeps
  writing a managed login's file even after its last grant is gone.
  """
  @spec record_managed_login(integer(), String.t()) :: :ok
  def record_managed_login(host_id, login) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all(ManagedLogin, [%{host_id: host_id, login: login, inserted_at: now}],
      on_conflict: :nothing,
      conflict_target: [:host_id, :login]
    )

    :ok
  end

  @doc """
  Stored grants whose `options` fail today's rules (`Options.validate/1`),
  e.g. written before the options were validated: `%{authorization_id, host,
  login, user, options, reason}` sorted by id — rows of
  `Ssm.Release.invalid_stored_rows/0` (`table: "authorization"`). A sync keeps the host's line
  of such a key instead of writing it; fix or clear the options.
  """
  @spec invalid_stored_options() :: [map()]
  def invalid_stored_options do
    from(a in Authorization,
      where: not is_nil(a.options) and a.options != "",
      order_by: a.id,
      preload: [:host, :user]
    )
    |> Repo.all()
    |> Enum.flat_map(fn auth ->
      case Options.validate(auth.options) do
        :ok -> []
        {:error, reason} -> [invalid_row(auth, reason)]
      end
    end)
  end

  defp invalid_row(auth, reason) do
    %{
      table: "authorization",
      id: auth.id,
      field: "options",
      host: auth.host && auth.host.name,
      login: auth.login,
      user: auth.user && auth.user.username,
      options: auth.options,
      reason: reason
    }
  end

  @doc "The managed logins of a host, sorted."
  @spec managed_logins(integer()) :: [String.t()]
  def managed_logins(host_id) do
    Repo.all(
      from m in ManagedLogin, where: m.host_id == ^host_id, order_by: m.login, select: m.login
    )
  end

  @doc """
  Delete a manual row. A row made by a grant is read-only (`{:error,
  :grant_row}`; delete the grant instead). The host is marked "revocation
  pending" (ADR-0012 §6) and reconciled in the same transaction: when this
  manual row had won over a grant, the grant row comes back.
  """
  @spec delete_authorization(Authorization.t()) ::
          {:ok, Authorization.t()} | {:error, Ecto.Changeset.t() | :grant_row}
  def delete_authorization(%Authorization{} = auth) do
    Ssm.Grants.transaction(fn ->
      stored = Repo.one(from a in Authorization, where: a.id == ^auth.id, select: a.grant_id)

      with nil <- stored || auth.grant_id,
           {:ok, deleted} <- Repo.delete(auth),
           :ok <- Revocations.mark(deleted.host_id, "authorization deleted"),
           {:ok, _} <-
             Expansion.reconcile([deleted.host_id], %{trigger: "authorization_delete"}) do
        deleted
      else
        grant_id when is_integer(grant_id) -> Repo.rollback(:grant_row)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec change_authorization(Authorization.t(), map()) :: Ecto.Changeset.t()
  def change_authorization(%Authorization{} = auth, attrs \\ %{}),
    do: Authorization.changeset(auth, attrs)
end
