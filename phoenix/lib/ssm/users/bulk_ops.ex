defmodule Ssm.Users.BulkOps do
  @moduledoc """
  Multi-user maintenance operations behind the Users page: split a user's
  keys into a new user, merge several users into one, and bulk deletion.

  Split and merge run inside `Ecto.Multi` transactions — they either happen
  completely or leave the database untouched. Bulk delete is deliberately
  per-user (one transaction each) so partial failures can be reported
  honestly instead of rolling everything back.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Ssm.Authorizations
  alias Ssm.Authorizations.Authorization
  alias Ssm.Diffs.Revocations
  alias Ssm.Repo
  alias Ssm.Users.{User, UserKey}

  @type split_result :: %{
          new_user: User.t(),
          moved_keys: non_neg_integer(),
          copied_authorizations: non_neg_integer()
        }

  @type merge_result :: %{
          target: User.t(),
          moved_keys: non_neg_integer(),
          copied_authorizations: non_neg_integer(),
          skipped_authorizations: non_neg_integer(),
          deleted_users: [String.t()]
        }

  @type bulk_delete_result :: %{deleted: [User.t()], failed: [{User.t(), term()}]}

  ## Split

  @doc """
  `split_user/3` for a web user (ADR-0012 §3): the user must be
  `Ssm.Users.writable?/2` in `scope`, else `{:error, :out_of_scope}`; for
  a non-admin (`opts[:role]`) it must hold no admin-only options
  (`Ssm.Users.check_admin_only/3`), else `{:error, :admin_only_options}`.
  """
  @spec split_user(Ssm.Scope.t(), User.t(), String.t(), [integer()], keyword()) ::
          {:ok, split_result()} | {:error, term()}
  def split_user(%Ssm.Scope{} = scope, %User{} = user, new_username, key_ids, opts \\ []) do
    # the new user's keys would inherit the copied grants' options
    Ssm.Users.if_writable(
      scope,
      [user],
      fn -> split_user(user, new_username, key_ids) end,
      {[user], "split", opts}
    )
  end

  @doc """
  Moves the keys in `key_ids` from `user` to a freshly created user named
  `new_username` and copies the original user's manual authorizations to
  the new user. Rows made by a grant stay with the original user, so the
  moved keys lose those hosts: they are marked "revocation pending". At
  least one key must remain with the original user.
  """
  @spec split_user(User.t(), String.t(), [integer()]) :: {:ok, split_result()} | {:error, term()}
  def split_user(%User{} = user, new_username, key_ids) when is_list(key_ids) do
    key_ids = Enum.uniq(key_ids)

    Multi.new()
    |> Multi.run(:validate_keys, fn repo, _changes -> validate_split_keys(repo, user, key_ids) end)
    |> Multi.insert(:new_user, split_target_changeset(user, new_username))
    |> Multi.update_all(
      :move_keys,
      fn %{new_user: new_user} -> move_keys_query(key_ids, new_user.id) end,
      []
    )
    |> Multi.run(:authorizations, fn repo, %{new_user: new_user} ->
      copy_authorizations(repo, [user.id], new_user.id)
    end)
    |> Multi.run(:revocations, fn _repo, _changes -> mark_grant_hosts(user.id) end)
    |> Ssm.Grants.transaction()
    |> case do
      {:ok, changes} ->
        {moved, _} = changes.move_keys
        {copied, _skipped} = changes.authorizations
        {:ok, %{new_user: changes.new_user, moved_keys: moved, copied_authorizations: copied}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # grant rows are not copied: the moved keys lose the user's grant hosts
  defp mark_grant_hosts(user_id) do
    from(a in Authorization,
      where: a.user_id == ^user_id and not is_nil(a.grant_id),
      distinct: true,
      select: a.host_id
    )
    |> Repo.all()
    |> Enum.each(&Revocations.mark(&1, "SSH user split"))

    {:ok, nil}
  end

  defp validate_split_keys(repo, user, key_ids) do
    owned = repo.all(from k in UserKey, where: k.user_id == ^user.id, select: k.id)

    cond do
      key_ids == [] -> {:error, :no_keys_selected}
      not MapSet.subset?(MapSet.new(key_ids), MapSet.new(owned)) -> {:error, :keys_not_owned}
      length(owned) - length(key_ids) < 1 -> {:error, :must_keep_one_key}
      true -> {:ok, owned}
    end
  end

  defp split_target_changeset(user, new_username) do
    User.changeset(%User{}, %{
      username: new_username,
      enabled: user.enabled,
      comment: "Split from #{user.username}"
    })
  end

  defp move_keys_query(key_ids, new_user_id) do
    from k in UserKey, where: k.id in ^key_ids, update: [set: [user_id: ^new_user_id]]
  end

  ## Merge

  @doc """
  `merge_users/2` for a web user: every source user and an existing target
  must be `Ssm.Users.writable?/2` in `scope`, else `{:error, :out_of_scope}`;
  for a non-admin none may hold admin-only options, else `{:error,
  :admin_only_options}`.
  """
  @spec merge_users(Ssm.Scope.t(), [User.t()], User.t() | map(), keyword()) ::
          {:ok, merge_result()} | {:error, term()}
  def merge_users(%Ssm.Scope{} = scope, users, target, opts \\ []) do
    involved = if match?(%User{}, target), do: [target | users], else: users

    # keys and grants meet in the target: no admin-only options on either side
    Ssm.Users.if_writable(
      scope,
      involved,
      fn -> merge_users(users, target) end,
      {involved, "merge", opts}
    )
  end

  @doc """
  Merges `users` into a target. The target is either one of the passed users
  (`%User{}`) or attrs for a brand-new user (map with `:username` etc.).

  All keys of the source users move to the target; authorizations are copied
  and deduplicated by `{host_id, login, options}` (a source authorization
  whose `{host_id, login}` pair the target already holds is also skipped —
  the DB is unique per user/host/login); the source users are then deleted
  (cascading their old authorizations).

  Refused with `{:error, {:conflicting_options, [{host_name, login}]}}`
  (nothing changed) when the target's rows and the sources' manual rows
  carry different `options` for one host and login: only one row can stay,
  and the keys of the other side would silently get its (possibly wider)
  options. nil and "" count as the same.
  """
  @spec merge_users([User.t()], User.t() | map()) :: {:ok, merge_result()} | {:error, term()}
  def merge_users(users, %User{} = target) do
    users
    |> Enum.reject(&(&1.id == target.id))
    |> do_merge(Multi.put(Multi.new(), :target, target))
  end

  def merge_users(users, new_user_attrs) when is_map(new_user_attrs) do
    do_merge(users, Multi.insert(Multi.new(), :target, User.changeset(%User{}, new_user_attrs)))
  end

  defp do_merge([], _multi), do: {:error, :nothing_to_merge}

  defp do_merge(sources, multi) do
    source_ids = Enum.map(sources, & &1.id)

    multi
    |> Multi.run(:options, fn repo, %{target: target} ->
      check_option_conflicts(repo, source_ids, target)
    end)
    |> Multi.update_all(
      :move_keys,
      fn %{target: target} ->
        from k in UserKey, where: k.user_id in ^source_ids, update: [set: [user_id: ^target.id]]
      end,
      []
    )
    |> Multi.run(:authorizations, fn repo, %{target: target} ->
      copy_authorizations(repo, source_ids, target.id)
    end)
    |> Multi.run(:deleted_users, fn repo, _changes -> delete_sources(repo, sources) end)
    |> Ssm.Grants.transaction()
    |> case do
      {:ok, changes} ->
        {moved, _} = changes.move_keys
        {copied, skipped} = changes.authorizations

        {:ok,
         %{
           target: changes.target,
           moved_keys: moved,
           copied_authorizations: copied,
           skipped_authorizations: skipped,
           deleted_users: changes.deleted_users
         }}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # the rows that meet on one (host, login): every row of the target (a new
  # one has none) and the sources' manual rows (grant rows are not copied)
  defp check_option_conflicts(repo, source_ids, target) do
    rows =
      repo.all(
        from a in Authorization,
          join: h in assoc(a, :host),
          where: a.user_id == ^target.id or (a.user_id in ^source_ids and is_nil(a.grant_id)),
          select: {h.name, a.login, a.options}
      )

    conflicts =
      rows
      |> Enum.group_by(fn {host, login, _} -> {host, login} end, fn {_, _, o} -> o || "" end)
      |> Enum.filter(fn {_pair, options} -> length(Enum.uniq(options)) > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if conflicts == [], do: {:ok, nil}, else: {:error, {:conflicting_options, conflicts}}
  end

  # Copies every manual authorization of `source_ids` onto `target_id`,
  # skipping duplicates. Rows made by a grant (ADR-0012 §5) are not copied:
  # they follow their grant, which stays with its SSH user.
  # Returns {:ok, {copied, skipped}} or {:error, changeset}.
  defp copy_authorizations(repo, source_ids, target_id) do
    target_auths = repo.all(from a in Authorization, where: a.user_id == ^target_id)
    seen = MapSet.new(target_auths, &fingerprint/1)
    taken = MapSet.new(target_auths, &{&1.host_id, &1.login})

    # inner join: a Diesel-era DB may still hold rows of deleted hosts (no FK
    # enforcement then); copying one would fail the foreign key
    source_auths =
      repo.all(
        from a in Authorization,
          join: h in assoc(a, :host),
          where: a.user_id in ^source_ids and is_nil(a.grant_id),
          order_by: a.id
      )

    source_auths
    |> Enum.reduce_while(
      {:ok, {0, 0, seen, taken}},
      &copy_one_authorization(repo, target_id, &1, &2)
    )
    |> case do
      {:ok, {copied, skipped, _seen, _taken}} -> {:ok, {copied, skipped}}
      {:error, _} = error -> error
    end
  end

  defp copy_one_authorization(repo, target_id, auth, {:ok, {copied, skipped, seen, taken}}) do
    pair = {auth.host_id, auth.login}

    if MapSet.member?(seen, fingerprint(auth)) or MapSet.member?(taken, pair) do
      {:cont, {:ok, {copied, skipped + 1, seen, taken}}}
    else
      case repo.insert(authorization_copy_changeset(auth, target_id)) do
        {:ok, copy} ->
          :ok = Authorizations.record_managed_login(copy.host_id, copy.login)

          {:cont,
           {:ok,
            {copied + 1, skipped, MapSet.put(seen, fingerprint(auth)), MapSet.put(taken, pair)}}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end
  end

  defp fingerprint(auth), do: {auth.host_id, auth.login, auth.options}

  defp authorization_copy_changeset(auth, user_id) do
    Authorization.copy_changeset(%Authorization{}, %{
      user_id: user_id,
      host_id: auth.host_id,
      login: auth.login,
      options: auth.options,
      comment: auth.comment
    })
  end

  defp delete_sources(repo, sources) do
    sources
    |> Enum.reduce_while({:ok, []}, fn user, {:ok, deleted} ->
      case repo.get(User, user.id) do
        nil ->
          {:halt, {:error, {:user_not_found, user.username}}}

        current ->
          # grants first, so their removals carry the merge as trigger
          {:ok, _} = Ssm.Grants.drop_for_users([current.id], %{trigger: "user_merge"})

          case Ssm.Users.delete_user(current) do
            {:ok, gone} -> {:cont, {:ok, [gone.username | deleted]}}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end
      end
    end)
    |> case do
      {:ok, deleted} -> {:ok, Enum.reverse(deleted)}
      {:error, _} = error -> error
    end
  end

  ## Bulk delete

  @doc """
  `bulk_delete/1` for a web user: users that are not `Ssm.Users.writable?/2`
  in `scope` are kept and reported as `{user, :out_of_scope}` failures.
  """
  @spec bulk_delete(Ssm.Scope.t(), [User.t()]) :: bulk_delete_result()
  def bulk_delete(%Ssm.Scope{} = scope, users) do
    # one transaction per user, the scope check inside it
    {deleted, failed} =
      Enum.reduce(users, {[], []}, fn user, {deleted, failed} ->
        case Ssm.Users.if_writable(scope, [user], fn -> delete_current(user) end) do
          {:ok, gone} -> {[gone | deleted], failed}
          {:error, reason} -> {deleted, [{user, reason} | failed]}
        end
      end)

    {refused, other} = Enum.split_with(Enum.reverse(failed), &match?({_, :out_of_scope}, &1))
    %{deleted: Enum.reverse(deleted), failed: other ++ refused}
  end

  @doc """
  Deletes every user in `users` (cascading keys and authorizations), one
  transaction per user. Failures do not abort the rest; both outcomes are
  reported so the caller can be honest about partial results.
  """
  @spec bulk_delete([User.t()]) :: bulk_delete_result()
  def bulk_delete(users) do
    {deleted, failed} = Enum.reduce(users, {[], []}, &delete_one/2)
    %{deleted: Enum.reverse(deleted), failed: Enum.reverse(failed)}
  end

  defp delete_one(user, {deleted, failed}) do
    case delete_current(user) do
      {:ok, gone} -> {[gone | deleted], failed}
      {:error, reason} -> {deleted, [{user, reason} | failed]}
    end
  end

  defp delete_current(user) do
    case Repo.get(User, user.id) do
      nil -> {:error, :not_found}
      current -> Ssm.Users.delete_user(current)
    end
  end

  ## Username suggestions

  @doc ~S(First free "<user> copy", "<user> copy2", … name — split default.)
  @spec suggest_split_username(String.t(), [String.t()]) :: String.t()
  def suggest_split_username(username, existing_usernames) do
    first_free("#{username} copy", existing_usernames, fn base, n -> "#{base}#{n}" end)
  end

  @doc ~S(Strips a trailing " copy<N>" and finds a free name — merge default.)
  @spec suggest_merge_username(String.t(), [String.t()]) :: String.t()
  def suggest_merge_username(username, existing_usernames) do
    trimmed = String.trim(username)
    base = String.replace(trimmed, ~r/\s+copy\d*$/i, "")
    base = if base == "", do: "#{trimmed}-merged", else: base
    first_free(base, existing_usernames, fn b, n -> "#{b}-#{n}" end)
  end

  defp first_free(base, existing, numbered) do
    taken = MapSet.new(existing, &String.downcase/1)

    [base]
    |> Stream.concat(Stream.map(Stream.iterate(2, &(&1 + 1)), &numbered.(base, &1)))
    |> Enum.find(&(not MapSet.member?(taken, String.downcase(&1))))
  end
end
