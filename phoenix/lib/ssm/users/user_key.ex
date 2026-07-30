defmodule Ssm.Users.UserKey do
  @moduledoc """
  One public SSH key belonging to a managed user. `key_base64` is globally
  unique. The old TypeScript frontend renamed `name` to `key_name` in its
  service layer (mistake #8) — the wire/DB name is and stays `name`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @key_types ~w(ssh-rsa ssh-ed25519 ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521 ssh-dss sk-ssh-ed25519@openssh.com sk-ecdsa-sha2-nistp256@openssh.com)

  schema "user_key" do
    field :key_type, :string
    field :key_base64, :string
    field :name, :string
    field :extra_comment, :string

    belongs_to :user, Ssm.Users.User
  end

  def key_types, do: @key_types

  def changeset(user_key, attrs) do
    user_key
    |> cast(attrs, [:key_type, :key_base64, :name, :extra_comment, :user_id])
    |> validate_required([:key_type, :key_base64, :user_id])
    |> update_change(:key_base64, &String.trim/1)
    |> validate_format(:key_base64, ~r/^[A-Za-z0-9+\/]+={0,2}$/,
      message: "must be base64 key material without type prefix or comment"
    )
    # ecto_sqlite3 derives the name as <table>_<col>_index (see Ssm.Hosts.Host).
    |> unique_constraint(:key_base64)
    |> foreign_key_constraint(:user_id)
  end
end
