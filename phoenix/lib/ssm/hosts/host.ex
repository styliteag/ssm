defmodule Ssm.Hosts.Host do
  @moduledoc """
  A managed SSH host. Table name is singular (`host`) — Diesel parity kept
  through the python stack and adopted unchanged here.

  `disabled` blocks every SSH operation (non-negotiable rule: each SSH code
  path checks it first). `jump_via` points at another host used as a jump
  host; chains are allowed (jump host may itself have a jump host).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "host" do
    field :name, :string
    field :username, :string
    field :address, :string
    field :port, :integer
    field :key_fingerprint, :string
    field :disabled, :boolean, default: false
    field :comment, :string

    belongs_to :jump_host, __MODULE__, foreign_key: :jump_via
    has_many :authorizations, Ssm.Authorizations.Authorization, foreign_key: :host_id
  end

  def changeset(host, attrs) do
    host
    |> cast(attrs, [
      :name,
      :username,
      :address,
      :port,
      :key_fingerprint,
      :jump_via,
      :disabled,
      :comment
    ])
    |> validate_required([:name, :username, :address, :port])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> unique_constraint(:name, name: :uq_host_name)
    |> unique_constraint([:address, :port], name: :unique_address_port)
    |> foreign_key_constraint(:jump_via, name: :fk_host_jump_via)
  end
end
