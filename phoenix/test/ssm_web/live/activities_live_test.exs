defmodule SsmWeb.ActivitiesLiveTest do
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ssm.Activity

  setup [:setup_htpasswd, :log_in]

  defp log_entry(attrs) do
    {:ok, entry} =
      Activity.log(
        Enum.into(attrs, %{
          activity_type: "host",
          action: "create",
          target: "web1",
          actor_username: "admin"
        })
      )

    entry
  end

  test "redirects anonymous visitors" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/activities")
  end

  test "lists entries newest first with type badges", %{conn: conn} do
    old = log_entry(%{target: "older", timestamp: 1_000})
    new = log_entry(%{activity_type: "key", target: "newer", timestamp: 2_000})

    {:ok, view, html} = live(conn, ~p"/activities")

    assert has_element?(view, "#activities-#{old.id}", "older")
    assert has_element?(view, "#activities-#{new.id} .badge", "key")

    assert [_, first_id | _] = Regex.run(~r/id="activities-(\d+)"/, html)
    assert String.to_integer(first_id) == new.id
  end

  test "filters by type via the select", %{conn: conn} do
    host_entry = log_entry(%{activity_type: "host", target: "host-thing"})
    key_entry = log_entry(%{activity_type: "key", target: "key-thing"})

    {:ok, view, _html} = live(conn, ~p"/activities?type=key")

    assert has_element?(view, "#activities-#{key_entry.id}")
    refute has_element?(view, "#activities-#{host_entry.id}")
  end

  test "toggle shows the decoded details JSON", %{conn: conn} do
    entry = log_entry(%{details: %{address: "10.0.0.1"}})

    {:ok, view, _html} = live(conn, ~p"/activities")

    view
    |> element("#activities-#{entry.id} button")
    |> render_click()

    assert has_element?(view, "#activities-#{entry.id} pre", "10.0.0.1")
  end

  test "load more extends the visible window", %{conn: conn} do
    oldest = log_entry(%{target: "the-oldest", timestamp: 1})

    for n <- 2..56 do
      log_entry(%{target: "entry-#{n}", timestamp: n})
    end

    {:ok, view, _html} = live(conn, ~p"/activities")

    refute has_element?(view, "#activities-#{oldest.id}")
    assert has_element?(view, "#load-more")

    view |> element("#load-more") |> render_click()

    assert has_element?(view, "#activities-#{oldest.id}")
    refute has_element?(view, "#load-more")
  end
end
