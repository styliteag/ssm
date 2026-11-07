defmodule Ssm.Groups do
  @moduledoc "Host groups (mctl contract v1): slug + name, keyset-paged by slug."

  import Ecto.Query

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

  @doc "Rename only — the slug is fixed after create."
  @spec update_group(Group.t(), map()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def update_group(%Group{} = group, attrs) do
    group |> Group.update_changeset(attrs) |> Repo.update()
  end

  @doc """
  Deletes an unused group (mctl contract 0.3.0, `delete_group`). A group
  that hosts still carry is `{:error, {:conflict, message}}` and stays;
  hosts are never taken out of a group. `{:error, :not_found}` for an
  unknown slug (also on a repeat).
  """
  @spec delete_group(String.t()) :: :ok | {:error, :not_found | {:conflict, String.t()}}
  def delete_group(slug) do
    case get_group_by_slug(slug) do
      nil ->
        {:error, :not_found}

      group ->
        case Repo.aggregate(from(hg in "host_groups", where: hg.group_id == ^group.id), :count) do
          0 ->
            {:ok, _} = Repo.delete(group)
            :ok

          n ->
            {:error, {:conflict, "group #{slug} is used by #{n} hosts"}}
        end
    end
  end

  @doc "Groups after `after_slug` (exclusive), sorted by slug; next key or nil."
  @spec page_groups(String.t() | nil, pos_integer()) :: {[Group.t()], String.t() | nil}
  def page_groups(after_slug, limit), do: Group |> Ssm.Keyset.page(:slug, after_slug, limit)
end
