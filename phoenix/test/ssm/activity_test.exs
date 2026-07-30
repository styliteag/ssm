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

  test "list/1 search matches action, target, and actor case-insensitively" do
    Activity.log(%{
      activity_type: "host",
      action: "create",
      target: "Prod-Web1",
      actor_username: "a"
    })

    Activity.log(%{
      activity_type: "host",
      action: "delete",
      target: "db",
      actor_username: "Admin"
    })

    Activity.log(%{activity_type: "key", action: "import", target: "k", actor_username: "b"})

    assert [%{target: "Prod-Web1"}] = Activity.list(search: "prod-web")
    assert [%{actor_username: "Admin"}] = Activity.list(search: "admin")
    assert [%{action: "import"}] = Activity.list(search: "IMPORT")
    assert Activity.list(search: "nothing-here") == []
  end

  test "list/1 search escapes LIKE wildcards" do
    Activity.log(%{
      activity_type: "host",
      action: "create",
      target: "pct%host",
      actor_username: "a"
    })

    Activity.log(%{
      activity_type: "host",
      action: "create",
      target: "plainhost",
      actor_username: "a"
    })

    assert [%{target: "pct%host"}] = Activity.list(search: "pct%")
    assert Activity.list(search: "___n") == []
  end

  test "classify_details/1 shapes decoded metadata for rendering" do
    assert Activity.classify_details(nil) == :none
    assert Activity.classify_details(%{}) == :none

    assert Activity.classify_details(%{
             "name" => %{"old" => "a", "new" => "b"},
             "port" => %{"old" => 22, "new" => 2222}
           }) == {:field_changes, [{"name", "a", "b"}, {"port", 22, 2222}]}

    assert Activity.classify_details(%{"address" => "10.0.0.1", "port" => 22}) ==
             {:summary, [{"address", "10.0.0.1"}, {"port", 22}]}

    raw = %{"nested" => %{"deep" => true}, "flag" => 1}
    assert Activity.classify_details(raw) == {:raw, raw}
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
