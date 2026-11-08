defmodule Ssm.Groups do
  @moduledoc "Host groups (mctl contract v1): slug + name, keyset-paged by slug."

  import Ecto.Query

  alias Ssm.Grants
  alias Ssm.Grants.{Expansion, Grant}
  alias Ssm.Groups.Group
  alias Ssm.Repo

  @spec get_group_by_slug(String.t()) :: Group.t() | nil
  def get_group_by_slug(slug) when is_binary(slug), do: Repo.get_by(Group, slug: slug)
  def get_group_by_slug(_), do: nil

  @doc "The groups for `slugs`, plus the slugs that do not exist."
  @spec fetch_by_slugs([String.t()]) :: {[Group.t()], missing :: [String.t()]}
  def fetch_by_slugs(slugs) do
    slugs = Enum.uniq(slugs)
    found = Repo.all(from g in Group, where: g.slug in ^slugs)
    known = MapSet.new(found, & &1.slug)
    {found, Enum.reject(slugs, &MapSet.member?(known, &1))}
  end

  @spec create_group(map()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def create_group(attrs) do
    %Group{} |> Group.create_changeset(attrs) |> Repo.insert()
  end

  @doc """
  Rename only — the slug is fixed after create. Grants reference groups by
  id, so a rename changes no access; the group's hosts are still reconciled
  in the same transaction (trigger `group_rename`).
  """
  @spec update_group(Group.t(), map(), Expansion.ctx()) ::
          {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def update_group(%Group{} = group, attrs, ctx \\ %{}) do
    Grants.transaction(fn ->
      with {:ok, updated} <- group |> Group.update_changeset(attrs) |> Repo.update(),
           {:ok, _} <-
             Expansion.reconcile(host_ids(group.id), Map.put(ctx, :trigger, "group_rename")) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp host_ids(group_id) do
    Repo.all(
      from hg in "host_groups",
        where: hg.group_id == ^group_id,
        select: type(hg.host_id, :integer)
    )
  end

  @doc """
  Deletes an unused group (mctl contract 0.3.0, `delete_group`). A group
  that hosts still carry is `{:error, {:conflict, message}}` and stays;
  hosts are never taken out of a group. `{:error, :not_found}` for an
  unknown slug (also on a repeat).
  """
  @spec delete_group(String.t(), Expansion.ctx()) ::
          :ok | {:error, :not_found | {:conflict, String.t()}}
  def delete_group(slug, ctx \\ %{}) do
    Grants.transaction(fn ->
      case get_group_by_slug(slug) do
        nil ->
          Repo.rollback(:not_found)

        group ->
          case Repo.aggregate(from(hg in "host_groups", where: hg.group_id == ^group.id), :count) do
            0 ->
              {:ok, _} = drop_grants_of(group.id, Map.put(ctx, :trigger, "group_delete"))
              {:ok, _} = Repo.delete(group)
              :ok

            n ->
              Repo.rollback({:conflict, "group #{slug} is used by #{n} hosts"})
          end
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  # grants that target the group go with it (ON DELETE CASCADE): reconcile
  # their hosts without them first, so the removals are audited and marked
  defp drop_grants_of(group_id, ctx) do
    grants = Repo.all(from g in Grant, where: g.group_id == ^group_id)

    Expansion.reconcile(
      Expansion.affected_host_ids(grants),
      Map.put(ctx, :exclude, Enum.map(grants, & &1.id))
    )
  end

  @doc "Groups after `after_slug` (exclusive), sorted by slug; next key or nil."
  @spec page_groups(String.t() | nil, pos_integer()) :: {[Group.t()], String.t() | nil}
  def page_groups(after_slug, limit), do: Group |> Ssm.Keyset.page(:slug, after_slug, limit)
end
