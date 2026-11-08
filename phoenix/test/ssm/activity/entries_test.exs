defmodule Ssm.Activity.EntriesTest do
  @moduledoc """
  The shared write entries keep the shape the web UI has always stored
  (target, ids, details), so history and filters read old and new rows alike.
  """

  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Activity
  alias Ssm.Activity.Entries

  defp last do
    [entry] = Activity.list(limit: 1)

    {entry.activity_type, entry.action, entry.target, entry.host_id, entry.user_id,
     entry.actor_username, Activity.details(entry)}
  end

  test "host: name, host_id, address and port" do
    host = host_fixture(%{name: "web1", address: "10.0.0.1"})
    Entries.host(:disable, host, "ui")

    assert last() ==
             {"host", "disable", "web1", host.id, nil, "ui",
              %{"address" => "10.0.0.1", "port" => 22}}
  end

  test "user: user_id except on delete, no details unless given" do
    user = user_fixture(%{username: "alice"})
    Entries.user(:enable, user, "ui")
    assert last() == {"user", "enable", "alice", nil, user.id, "ui", nil}
    Entries.user(:delete, user, "api", %{via: "api"})
    assert last() == {"user", "delete", "alice", nil, nil, "api", %{"via" => "api"}}
  end

  test "key: name else type, owner, key_type" do
    user = user_fixture()
    key = key_fixture(user, %{key_type: "ssh-ed25519", name: nil})
    Entries.key(:import, key, "ui")

    assert last() ==
             {"key", "import", "ssh-ed25519", nil, user.id, "ui", %{"key_type" => "ssh-ed25519"}}
  end

  test "authorization: user@host:login, user_id except on delete" do
    user = user_fixture(%{username: "bob"})
    host = host_fixture(%{name: "db1"})
    auth = authorization_fixture(user, host, %{login: "deploy"})
    Entries.authorization(:create, auth, "ui")
    assert last() == {"auth", "create", "bob@db1:deploy", host.id, user.id, "ui", nil}
    Entries.authorization(:delete, auth, "ui")
    assert last() == {"auth", "delete", "bob@db1:deploy", host.id, nil, "ui", nil}
  end
end
