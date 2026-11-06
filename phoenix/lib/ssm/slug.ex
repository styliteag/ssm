defmodule Ssm.Slug do
  @moduledoc """
  Shared changeset rules for slugged records (customers, groups): the mctl
  contract slug format `^[a-z0-9][a-z0-9-]{0,62}$`, unique, fixed after
  create (only `name` is castable on update).
  """

  import Ecto.Changeset

  @format ~r/^[a-z0-9][a-z0-9-]{0,62}$/

  @doc "Changeset for a new record: slug + name."
  def create_changeset(record, attrs) do
    record
    |> cast(attrs, [:slug, :name])
    |> validate_required([:slug, :name])
    |> validate_format(:slug, @format,
      message: "must match ^[a-z0-9][a-z0-9-]{0,62}$ (lowercase letters, digits, dashes)"
    )
    |> validate_name()
    |> unique_constraint(:slug)
  end

  @doc "Changeset for an existing record: the name only."
  def update_changeset(record, attrs) do
    record
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_name()
  end

  defp validate_name(changeset), do: validate_length(changeset, :name, min: 1, max: 255)

  @doc "True for a well-formed slug."
  def valid?(slug) when is_binary(slug), do: Regex.match?(@format, slug)
  def valid?(_), do: false
end
