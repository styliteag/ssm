defmodule Ssm.Activity.Entries do
  @moduledoc """
  The activity-log entries of a host, SSH user, key or authorization write,
  shared by the web UI (hosts, users, keys and authorizations pages) and
  `/api/v2`, so both record the same shape: `action` from
  `Ssm.Activity.Actions`, `actor` the web user's audit label or the API
  token's subject. `details` is merged into the entry's details (`/api/v2`
  adds `via: "api"`). Like `Ssm.Activity.log/1`, an entry that cannot be
  written never fails the write.
  """

  alias Ssm.Activity
  alias Ssm.Activity.Actions
  alias Ssm.Authorizations.Authorization
  alias Ssm.Hosts.Host
  alias Ssm.Repo
  alias Ssm.Users.{User, UserKey}

  @spec host(Actions.t(), Host.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def host(action, %Host{} = host, actor, details \\ %{}) do
    Activity.log(%{
      activity_type: "host",
      action: Actions.name(action),
      target: host.name,
      host_id: host.id,
      actor_username: actor,
      details: Map.merge(%{address: host.address, port: host.port}, details)
    })
  end

  @doc "A `:delete` entry does not reference the removed row (FK on `user_id`)."
  @spec user(Actions.t(), User.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def user(action, %User{} = user, actor, details \\ %{}) do
    %{
      activity_type: "user",
      action: Actions.name(action),
      target: user.username,
      actor_username: actor
    }
    |> put_unless_delete(action, :user_id, user.id)
    |> put_details(details)
    |> Activity.log()
  end

  @spec key(Actions.t(), UserKey.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def key(action, %UserKey{} = key, actor, details \\ %{}) do
    Activity.log(%{
      activity_type: "key",
      action: Actions.name(action),
      target: key_label(key),
      actor_username: actor,
      user_id: key.user_id,
      details: Map.merge(%{key_type: key.key_type}, details)
    })
  end

  @doc "Target `user@host:login`; a `:delete` entry carries no `user_id`."
  @spec authorization(Actions.t(), Authorization.t(), String.t(), map()) ::
          {:ok, term()} | {:error, term()}
  def authorization(action, %Authorization{} = auth, actor, details \\ %{}) do
    auth = Repo.preload(auth, [:user, :host])

    %{
      activity_type: "auth",
      action: Actions.name(action),
      target: "#{user_label(auth)}@#{host_label(auth)}:#{auth.login}",
      host_id: auth.host_id,
      actor_username: actor
    }
    |> put_unless_delete(action, :user_id, auth.user_id)
    |> put_details(details)
    |> Activity.log()
  end

  @doc "A key's label: its name, else its type."
  @spec key_label(UserKey.t()) :: String.t()
  def key_label(%UserKey{name: name}) when is_binary(name) and name != "", do: name
  def key_label(%UserKey{key_type: type}), do: type

  defp put_unless_delete(attrs, :delete, _field, _value), do: attrs
  defp put_unless_delete(attrs, _action, field, value), do: Map.put(attrs, field, value)

  defp put_details(attrs, details) when details == %{}, do: attrs
  defp put_details(attrs, details), do: Map.put(attrs, :details, details)

  # Legacy Diesel-era DBs hold orphaned grants (user/host deleted while FK
  # enforcement was off), so a preloaded association can come back nil.
  defp user_label(%{user: %{username: username}}), do: username
  defp user_label(auth), do: "missing user ##{auth.user_id}"

  defp host_label(%{host: %{name: name}}), do: name
  defp host_label(auth), do: "missing host ##{auth.host_id}"
end
