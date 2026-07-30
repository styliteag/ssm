defmodule Ssm.ActivityTest do
  use Ssm.DataCase, async: false

  import Ssm.Fixtures

  alias Ssm.Activity

  test "log/1 stores an entry with JSON details in the metadata column" do
    user = user_fixture()

    {:ok, entry} =
      Activity.log(%{
        activity_type: "host",
        action: "create",
        target: "web1",
        actor_username: "admin",
        user_id: user.id,
        details: %{address: "10.0.0.1"}
      })

    assert entry.timestamp > 1_700_000_000
    assert Activity.details(entry) == %{"address" => "10.0.0.1"}
  end

  test "list/1 returns newest first and filters by type" do
    Activity.log(%{activity_type: "host", action: "create", target: "h", actor_username: "a"})
    Activity.log(%{activity_type: "key", action: "create", target: "k", actor_username: "a"})
    Activity.log(%{activity_type: "host", action: "delete", target: "h", actor_username: "a"})

    all = Activity.list()
    assert length(all) == 3
    # Newest first: the last insert has the highest id (timestamps may tie).
    assert hd(all).action == "delete"

    hosts = Activity.list(activity_type: "host")
    assert length(hosts) == 2
    assert Enum.all?(hosts, &(&1.activity_type == "host"))
  end

  test "an invalid activity_type is rejected by the changeset" do
    assert {:error, _changeset} =
             Activity.log(%{
               activity_type: "bogus",
               action: "x",
               target: "y",
               actor_username: "a"
             })
  end
end
