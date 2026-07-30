defmodule Ssm.Fixtures do
  @moduledoc "Minimal entity builders for context and LiveView tests."

  alias Ssm.{Authorizations, Hosts, Users}

  def host_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, host} =
      attrs
      |> Enum.into(%{
        name: "host-#{n}",
        username: "root",
        address: "10.0.0.#{rem(n, 250) + 1}",
        port: 22
      })
      |> Hosts.create_host()

    host
  end

  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, user} = attrs |> Enum.into(%{username: "user-#{n}"}) |> Users.create_user()
    user
  end

  def key_fixture(user, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, key} =
      attrs
      |> Enum.into(%{
        user_id: user.id,
        key_type: "ssh-ed25519",
        key_base64: "AAAAKEY#{n}",
        name: "key-#{n}"
      })
      |> Users.create_key()

    key
  end

  def authorization_fixture(user, host, attrs \\ %{}) do
    {:ok, auth} =
      attrs
      |> Enum.into(%{user_id: user.id, host_id: host.id, login: "deploy"})
      |> Authorizations.create_authorization()

    auth
  end
end
