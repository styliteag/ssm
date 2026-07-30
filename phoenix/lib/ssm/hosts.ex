defmodule Ssm.Hosts do
  @moduledoc """
  Managed SSH hosts — the context behind `/api/v2/hosts` and the Hosts page.
  Every SSH operation elsewhere resolves its `Ssm.Ssh.Target` through
  `target_for/1`, which walks the `jump_via` chain.
  """

  import Ecto.Query

  alias Ssm.Hosts.Host
  alias Ssm.Repo
  alias Ssm.Ssh.Target

  @spec list_hosts() :: [Host.t()]
  def list_hosts, do: Repo.all(from h in Host, order_by: h.id)

  @spec get_host(integer()) :: Host.t() | nil
  def get_host(id), do: Repo.get(Host, id)

  @spec fetch_host(integer()) :: {:ok, Host.t()} | {:error, :not_found}
  def fetch_host(id) do
    case Repo.get(Host, id) do
      nil -> {:error, :not_found}
      host -> {:ok, host}
    end
  end

  @spec create_host(map()) :: {:ok, Host.t()} | {:error, Ecto.Changeset.t()}
  def create_host(attrs) do
    %Host{} |> Host.changeset(attrs) |> Repo.insert()
  end

  @spec update_host(Host.t(), map()) :: {:ok, Host.t()} | {:error, Ecto.Changeset.t()}
  def update_host(%Host{} = host, attrs) do
    host |> Host.changeset(attrs) |> Repo.update()
  end

  @spec delete_host(Host.t()) :: {:ok, Host.t()} | {:error, Ecto.Changeset.t()}
  def delete_host(%Host{} = host), do: Repo.delete(host)

  @spec change_host(Host.t(), map()) :: Ecto.Changeset.t()
  def change_host(%Host{} = host, attrs \\ %{}), do: Host.changeset(host, attrs)

  @spec count_hosts() :: non_neg_integer()
  def count_hosts, do: Repo.aggregate(Host, :count)

  @spec count_disabled_hosts() :: non_neg_integer()
  def count_disabled_hosts,
    do: Repo.aggregate(from(h in Host, where: h.disabled == true), :count)

  @doc "Hosts eligible to be a jump host for `host` (any other host)."
  @spec jump_candidates(Host.t() | nil) :: [Host.t()]
  def jump_candidates(nil), do: list_hosts()

  def jump_candidates(%Host{id: id}),
    do: Repo.all(from h in Host, where: h.id != ^id, order_by: h.name)

  @doc "Build the SSH target for `host`, resolving its jump chain from the DB."
  @spec target_for(Host.t()) :: Target.t()
  def target_for(%Host{} = host), do: Target.from_host(host, &get_host/1)
end
