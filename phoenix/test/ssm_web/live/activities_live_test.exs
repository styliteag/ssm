defmodule SsmWeb.ActivitiesLiveTest do
  use SsmWeb.ConnCase, async: false

  import Ecto.Query
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

  test "renders flat scalar details as summary chips", %{conn: conn} do
    entry = log_entry(%{details: %{address: "10.0.0.1", port: 2222}})

    {:ok, view, _html} = live(conn, ~p"/activities")

    chips = "#activities-#{entry.id} [data-details=summary]"
    assert has_element?(view, chips, "address: 10.0.0.1")
    assert has_element?(view, chips, "port: 2222")
  end

  test "renders old/new maps as field-change chips", %{conn: conn} do
    entry = log_entry(%{details: %{name: %{old: "web1", new: "web2"}}})

    {:ok, view, _html} = live(conn, ~p"/activities")

    chips = "#activities-#{entry.id} [data-details=changes]"
    assert has_element?(view, chips, "name:")
    assert has_element?(view, "#{chips} s", "web1")
    assert has_element?(view, chips, "web2")
  end

  test "renders nested details as a collapsible JSON block", %{conn: conn} do
    entry = log_entry(%{details: %{nested: %{deep: "value"}, flag: true}})

    {:ok, view, _html} = live(conn, ~p"/activities")

    assert has_element?(view, "#activities-#{entry.id} details[data-details=raw] pre", "value")
  end

  test "open details and popovers keep their open state across re-renders", %{conn: conn} do
    entry = log_entry(%{details: %{nested: %{deep: "value"}}})

    {:ok, view, _html} = live(conn, ~p"/activities")

    # the stream is reset on every refresh; `open` must stay client-owned
    selectors = [
      "#activities-#{entry.id} details[data-details=raw]",
      "details#theme-switcher"
    ]

    for selector <- selectors do
      mounted = view |> element(selector) |> render() |> attribute("phx-mounted")
      assert mounted =~ "ignore_attrs", "#{selector} lacks JS.ignore_attributes"
      assert mounted =~ "open"
    end
  end

  defp attribute(html, name) do
    html |> LazyHTML.from_fragment() |> LazyHTML.attribute(name) |> List.first("")
  end

  test "search narrows by action, target, or actor", %{conn: conn} do
    hit = log_entry(%{target: "prod-web1"})
    miss = log_entry(%{target: "db-box"})

    {:ok, view, _html} = live(conn, ~p"/activities?q=prod-web")

    assert has_element?(view, "#activities-#{hit.id}")
    refute has_element?(view, "#activities-#{miss.id}")
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

  test "load more stops at a fixed maximum", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/activities")

    for _ <- 1..40, do: render_click(view, "load_more", %{})

    assert :sys.get_state(view.pid).socket.assigns.limit == 1000
  end

  test "filters by actor and day range", %{conn: conn} do
    a = log_entry(%{target: "by-alice", actor_username: "alice"})
    b = log_entry(%{target: "by-bob", actor_username: "bob"})

    Ssm.Repo.update_all(
      from(l in Ssm.Activity.ActivityLog, where: l.id == ^a.id),
      set: [timestamp: 1_700_000_000]
    )

    {:ok, view, _} = live(conn, ~p"/activities?actor=alice")
    assert has_element?(view, "#activities-#{a.id}")
    refute has_element?(view, "#activities-#{b.id}")

    # 2023-11-14 22:13:20 UTC
    {:ok, view, _} = live(conn, ~p"/activities?from=2023-11-14&to=2023-11-14")
    assert has_element?(view, "#activities-#{a.id}")
    refute has_element?(view, "#activities-#{b.id}")

    {:ok, view, _} = live(conn, ~p"/activities?from=2023-11-15")
    refute has_element?(view, "#activities-#{a.id}")
    assert has_element?(view, "#activities-#{b.id}")

    # garbage dates are ignored
    {:ok, view, _} = live(conn, ~p"/activities?from=nope")
    assert has_element?(view, "#activities-#{a.id}")
  end

  describe "date filter in the viewer's time zone" do
    # 2026-06-30 21:30 UTC = 23:30 in Berlin (June 30), 22:30 UTC = 00:30 (July 1)
    setup %{conn: conn} do
      before_midnight = log_entry(%{target: "before-midnight"})
      after_midnight = log_entry(%{target: "after-midnight"})
      set_timestamp(before_midnight, ~U[2026-06-30 21:30:00Z])
      set_timestamp(after_midnight, ~U[2026-06-30 22:30:00Z])

      %{conn: conn, before: before_midnight, after: after_midnight}
    end

    defp set_timestamp(entry, utc) do
      Ssm.Repo.update_all(
        from(l in Ssm.Activity.ActivityLog, where: l.id == ^entry.id),
        set: [timestamp: DateTime.to_unix(utc)]
      )
    end

    defp live_in(conn, zone, path),
      do: live(put_connect_params(conn, %{"tz" => zone}), path)

    test "Europe/Berlin: July 1 starts at 22:00 UTC", ctx do
      {:ok, view, html} = live_in(ctx.conn, "Europe/Berlin", ~p"/activities?from=2026-07-01")
      assert html =~ "From (Europe/Berlin)"
      assert has_element?(view, "#activities-#{ctx.after.id}")
      refute has_element?(view, "#activities-#{ctx.before.id}")

      {:ok, view, _} = live_in(ctx.conn, "Europe/Berlin", ~p"/activities?to=2026-06-30")
      assert has_element?(view, "#activities-#{ctx.before.id}")
      refute has_element?(view, "#activities-#{ctx.after.id}")
    end

    test "the same day in another zone is another UTC range", ctx do
      # Tokyo (UTC+9): July 1 starts at 15:00 UTC on June 30, both entries are in
      {:ok, view, _} = live_in(ctx.conn, "Asia/Tokyo", ~p"/activities?from=2026-07-01")
      assert has_element?(view, "#activities-#{ctx.before.id}")
      assert has_element?(view, "#activities-#{ctx.after.id}")
    end
  end
end
