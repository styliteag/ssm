defmodule Ssm.Groups.Group do
  @moduledoc "A host group (mctl contract v1); hosts link to groups via `host_groups`."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "groups" do
    field :slug, :string
    field :name, :string
    timestamps(type: :utc_datetime)
  end

  defdelegate create_changeset(group, attrs), to: Ssm.Slug
  defdelegate update_changeset(group, attrs), to: Ssm.Slug
end
