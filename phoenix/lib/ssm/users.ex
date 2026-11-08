defmodule Ssm.Users do
  @moduledoc """
  Managed key owners and their public keys — the context behind
  `/api/v2/users` and `/api/v2/keys` (Users + Keys pages).

  The SSH user catalog is readable in full by every web user (ADR-0012 §3).
  Writes that take an `Ssm.Scope` first serve the web UI: they change a
  user or its keys only when the user is `writable?/2` – every one of its
  authorizations is on a host in scope, because a key change lands on every
  host of that user. Otherwise `{:error, :out_of_scope}`. The scope-less
  writes stay global (`/api/v2`, mctl contract). Creating an SSH user stays
  open; its keys follow once it holds an authorization in scope.

  A key that lands in a user inherits that user's grants, options
  included: the scoped writes also take `opts` (`role:`, `actor:`) and
  refuse a non-admin a key added, moved or re-keyed into a user holding a
  grant with admin-only options (`check_admin_only/3`).

  Every write that takes access away (disable or delete a user, delete,
  move or re-key a key) marks the user's hosts "revocation pending"
  (`Ssm.Diffs.Revocations.mark_user_hosts/2`) in the same transaction.
  """

  import Ecto.Query

  alias Ssm.Activity
  alias Ssm.Authorizations.{Authorization, Options}
  alias Ssm.Diffs.Revocations
  alias Ssm.Repo
  alias Ssm.Users.{User, UserKey}

  ## Users

  @spec list_users() :: [User.t()]
  def list_users, do: Repo.all(from u in User, order_by: u.username)

  @spec get_user(integer()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @doc """
  May a user with `scope` change this SSH user (or user id) and its keys?
  A global scope may always. A scoped one only when the user has at least
  one authorization and all of them are on hosts in scope: a user without
  authorizations is read-only until it is authorized in scope. Grants of
  deleted hosts count as outside. A grant (ADR-0012 §5) whose reach is not
  inside the scope also makes the user read-only: its future hosts would get
  the user's keys too.
  """
  @spec writable?(Ssm.Scope.t(), User.t() | integer()) :: boolean()
  def writable?(%Ssm.Scope{} = scope, %User{id: id}), do: writable?(scope, id)

  def writable?(%Ssm.Scope{} = scope, user_id) when is_integer(user_id) do
    Ssm.Scope.global?(scope) or
      (Repo.exists?(from a in Authorization, where: a.user_id == ^user_id) and
         not Repo.exists?(
           from a in Authorization,
             where: a.user_id == ^user_id and a.host_id not in subquery(Ssm.Scope.host_ids(scope))
         ) and
         grants_inside?(scope, user_id))
  end

  def writable?(_scope, _user_id), do: false

  defp grants_inside?(scope, user_id) do
    from(g in Ssm.Grants.Grant, where: g.ssh_user_id == ^user_id)
    |> Repo.all()
    |> Enum.all?(&Ssm.Grants.manageable?(scope, &1))
  end

  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs), do: %User{} |> User.changeset(attrs) |> Repo.insert()

  @doc "Update an SSH user; disabling it marks its hosts \"revocation pending\"."
  @spec update_user(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user(%User{} = user, attrs) do
    changeset = User.changeset(user, attrs)

    if Ecto.Changeset.get_change(changeset, :enabled) == false,
      do: write_revoking(changeset, &Repo.update/1, [user.id], "SSH user disabled"),
      else: Repo.update(changeset)
  end

  # `write` and the marks commit together; the marks are made first, while
  # the user's authorizations and keys are still where they were. An invalid
  # changeset never opens a transaction (a caller's would roll back).
  defp write_revoking(%Ecto.Changeset{valid?: false} = changeset, write, _user_ids, _reason),
    do: write.(changeset)

  defp write_revoking(changeset, write, user_ids, reason) do
    Ssm.Grants.transaction(fn ->
      :ok = Revocations.mark_user_hosts(user_ids, reason)

      case write.(changeset) do
        {:ok, written} -> written
        {:error, failed} -> Repo.rollback(failed)
      end
    end)
  end

  @doc """
  Delete an SSH user (keys and authorizations cascade). Its grants are
  dropped first through `Ssm.Grants.drop_for_users/2` in the same
  transaction: audited, hosts marked "revocation pending" — every host of
  the user, also those of its manual rows.
  """
  @spec delete_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def delete_user(%User{} = user) do
    Ssm.Grants.transaction(fn ->
      :ok = Revocations.mark_user_hosts([user.id], "SSH user deleted")

      with {:ok, _} <- Ssm.Grants.drop_for_users([user.id], %{trigger: "user_delete"}),
           {:ok, deleted} <- Repo.delete(user) do
        deleted
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "`update_user/2` for a web user: only a `writable?/2` user."
  @spec update_user(Ssm.Scope.t(), User.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | :out_of_scope}
  def update_user(%Ssm.Scope{} = scope, %User{} = user, attrs),
    do: if(writable?(scope, user), do: update_user(user, attrs), else: {:error, :out_of_scope})

  @doc "`delete_user/1` for a web user: only a `writable?/2` user."
  @spec delete_user(Ssm.Scope.t(), User.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | :out_of_scope}
  def delete_user(%Ssm.Scope{} = scope, %User{} = user),
    do: if(writable?(scope, user), do: delete_user(user), else: {:error, :out_of_scope})

  @spec change_user(User.t(), map()) :: Ecto.Changeset.t()
  def change_user(%User{} = user, attrs \\ %{}), do: User.changeset(user, attrs)

  @doc """
  Every user with their key count and the count of their authorizations on
  hosts in `scope` (Users page rows; the SSH user catalog is readable in
  full, ADR-0012 §3, host data is not).
  """
  @spec list_users_with_counts(Ssm.Scope.t()) :: [
          %{user: User.t(), key_count: non_neg_integer(), authorization_count: non_neg_integer()}
        ]
  def list_users_with_counts(%Ssm.Scope{} = scope \\ Ssm.Scope.global()) do
    key_counts = per_user_counts(UserKey)
    auth_counts = per_user_counts(Ssm.Scope.filter(Authorization, scope))

    Enum.map(list_users(), fn user ->
      %{
        user: user,
        key_count: Map.get(key_counts, user.id, 0),
        authorization_count: Map.get(auth_counts, user.id, 0)
      }
    end)
  end

  defp per_user_counts(schema) do
    from(r in schema, group_by: r.user_id, select: {r.user_id, count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  @spec count_users() :: non_neg_integer()
  def count_users, do: Repo.aggregate(User, :count)

  @spec count_keys() :: non_neg_integer()
  def count_keys, do: Repo.aggregate(UserKey, :count)

  ## Keys

  @spec list_keys(keyword()) :: [UserKey.t()]
  def list_keys(opts \\ []) do
    query = from k in UserKey, order_by: k.id, preload: [:user]

    query =
      case Keyword.get(opts, :user_id) do
        nil -> query
        user_id -> where(query, [k], k.user_id == ^user_id)
      end

    Repo.all(query)
  end

  @spec get_key(integer()) :: UserKey.t() | nil
  def get_key(id), do: UserKey |> Repo.get(id) |> Repo.preload(:user)

  @doc "Look a key up by its base64 material (unique) — diff owner resolution."
  @spec get_key_by_base64(String.t()) :: UserKey.t() | nil
  def get_key_by_base64(base64) do
    UserKey |> Repo.get_by(key_base64: base64) |> Repo.preload(:user)
  end

  @doc """
  Stored keys with control characters (`Ssm.ControlChars`) in type,
  material, comment or extra comment — rows of
  `Ssm.Release.invalid_stored_rows/0` (`table: "user_key"`, one per field).
  """
  @spec invalid_stored_keys() :: [map()]
  def invalid_stored_keys do
    from(k in UserKey, order_by: k.id, preload: :user)
    |> Repo.all()
    |> Enum.flat_map(fn key ->
      for field <- [:key_type, :key_base64, :name, :extra_comment],
          Ssm.ControlChars.present?(Map.get(key, field)) do
        %{
          table: "user_key",
          id: key.id,
          field: Atom.to_string(field),
          user: key.user && key.user.username,
          host: nil,
          login: nil,
          reason: "must not contain control characters"
        }
      end
    end)
  end

  @spec create_key(map()) :: {:ok, UserKey.t()} | {:error, Ecto.Changeset.t()}
  def create_key(attrs), do: %UserKey{} |> UserKey.changeset(attrs) |> Repo.insert()

  @doc """
  Update a key; a move to another user or new key material takes the old
  key away from the old owner's hosts: they are marked "revocation pending".
  """
  @spec update_key(UserKey.t(), map()) :: {:ok, UserKey.t()} | {:error, Ecto.Changeset.t()}
  def update_key(%UserKey{} = key, attrs) do
    changeset = UserKey.changeset(key, attrs)

    if Enum.any?([:user_id, :key_type, :key_base64], &Map.has_key?(changeset.changes, &1)),
      do: write_revoking(changeset, &Repo.update/1, [key.user_id], "key moved or replaced"),
      else: Repo.update(changeset)
  end

  @doc "Delete a key; the owner's hosts are marked \"revocation pending\"."
  @spec delete_key(UserKey.t()) :: {:ok, UserKey.t()} | {:error, Ecto.Changeset.t()}
  def delete_key(%UserKey{} = key),
    do: write_revoking(key, &Repo.delete/1, [key.user_id], "key deleted")

  @doc """
  `create_key/1` for a web user: the owner must be `writable?/2`, and for
  a non-admin hold no admin-only options (`check_admin_only/3`).
  """
  @spec create_key(Ssm.Scope.t(), map(), keyword()) ::
          {:ok, UserKey.t()} | {:error, Ecto.Changeset.t() | :out_of_scope | :admin_only_options}
  def create_key(%Ssm.Scope{} = scope, attrs, opts \\ []) do
    owner = %UserKey{} |> UserKey.changeset(attrs) |> Ecto.Changeset.get_field(:user_id)

    cond do
      is_nil(owner) -> create_key(attrs)
      not writable?(scope, owner) -> {:error, :out_of_scope}
      true -> with :ok <- check_admin_only([owner], "add key", opts), do: create_key(attrs)
    end
  end

  @doc """
  `update_key/2` for a web user: the old and the new owner must be
  `writable?/2`; a move or a new key material also needs `check_admin_only/3`
  for the new owner (a rename does not).
  """
  @spec update_key(Ssm.Scope.t(), UserKey.t(), map(), keyword()) ::
          {:ok, UserKey.t()} | {:error, Ecto.Changeset.t() | :out_of_scope | :admin_only_options}
  def update_key(%Ssm.Scope{} = scope, %UserKey{} = key, attrs, opts \\ []) do
    changeset = UserKey.changeset(key, attrs)
    new_owner = Ecto.Changeset.get_field(changeset, :user_id)
    rekeyed? = Enum.any?([:user_id, :key_type, :key_base64], &Map.has_key?(changeset.changes, &1))

    cond do
      not (writable?(scope, key.user_id) and writable?(scope, new_owner)) ->
        {:error, :out_of_scope}

      rekeyed? ->
        with :ok <- check_admin_only([new_owner], "move or re-key key", opts),
             do: update_key(key, attrs)

      true ->
        update_key(key, attrs)
    end
  end

  @doc """
  `:ok`, or `{:error, :admin_only_options}` when `opts[:role]` is not
  `"admin"` and one of `users` (structs or ids) holds a grant whose options
  carry an admin-only option (`Options.admin_only/1`): a key landing there
  would inherit it. Fails closed without a role. A refusal is audited
  (`admin_only_refused`, `opts[:actor]`, `op`).
  """
  @spec check_admin_only([User.t() | integer() | nil], String.t(), keyword()) ::
          :ok | {:error, :admin_only_options}
  def check_admin_only(users, op, opts) do
    ids = users |> Enum.map(&user_id/1) |> Enum.reject(&is_nil/1)

    if Keyword.get(opts, :role) == "admin" or not permissive_grants?(ids) do
      :ok
    else
      audit_admin_only(ids, op, opts)
      {:error, :admin_only_options}
    end
  end

  defp user_id(%User{id: id}), do: id
  defp user_id(id), do: id

  defp permissive_grants?([]), do: false

  defp permissive_grants?(ids) do
    from(a in Authorization,
      where: a.user_id in ^ids and not is_nil(a.options) and a.options != "",
      select: a.options
    )
    |> Repo.all()
    |> Enum.any?(&(Options.admin_only(&1) != []))
  end

  defp audit_admin_only(ids, op, opts) do
    names =
      Repo.all(from u in User, where: u.id in ^ids, order_by: u.username, select: u.username)

    Activity.log(%{
      activity_type: "user",
      action: "admin_only_refused",
      target: Enum.join(names, ", "),
      actor_username: Keyword.get(opts, :actor) || "unknown",
      details: %{op: op, reason: "the user holds a grant with admin-only options"}
    })
  end

  @doc "`delete_key/1` for a web user: the owner must be `writable?/2`."
  @spec delete_key(Ssm.Scope.t(), UserKey.t()) ::
          {:ok, UserKey.t()} | {:error, Ecto.Changeset.t() | :out_of_scope}
  def delete_key(%Ssm.Scope{} = scope, %UserKey{} = key),
    do: if(writable?(scope, key.user_id), do: delete_key(key), else: {:error, :out_of_scope})

  @spec change_key(UserKey.t(), map()) :: Ecto.Changeset.t()
  def change_key(%UserKey{} = key, attrs \\ %{}), do: UserKey.changeset(key, attrs)
end
