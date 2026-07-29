defmodule Ssm.Activity.ActivityLog do
  @moduledoc """
  Append-only audit trail. `timestamp` is a unix epoch integer (server default
  exists in the DDL; the changeset also sets it so adopted Diesel-era rows and
  fresh rows behave identically). The `meta` field maps to a column literally
  named `metadata`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @activity_types ~w(key host user auth)

  schema "activity_log" do
    field :activity_type, :string
    field :action, :string
    field :target, :string
    field :actor_username, :string
    field :timestamp, :integer
    field :meta, :string, source: :metadata

    belongs_to :user, Ssm.Users.User
  end

  def activity_types, do: @activity_types

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:activity_type, :action, :target, :user_id, :actor_username, :meta])
    |> validate_required([:activity_type, :action, :target, :actor_username])
    |> validate_inclusion(:activity_type, @activity_types)
    |> put_timestamp()
    |> foreign_key_constraint(:user_id, name: :fk_activity_log_user_id)
  end

  defp put_timestamp(changeset) do
    case get_field(changeset, :timestamp) do
      nil -> put_change(changeset, :timestamp, System.os_time(:second))
      _set -> changeset
    end
  end
end
