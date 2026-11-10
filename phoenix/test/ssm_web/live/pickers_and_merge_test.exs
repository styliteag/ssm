defmodule SsmWeb.PickersAndMergeTest do
  @moduledoc """
  Searchable, sorted pickers for SSH users, hosts and grant targets; the
  merge dialog says what the merge deletes, moves, copies and drops.
  """
  use SsmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.{Customers, Grants, Groups, Scope}

  setup [:setup_htpasswd, :log_in]

  defp option_labels(view, select) do
    view
    |> element(select)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option")
    |> Enum.map(&LazyHTML.text/1)
    |> Enum.map(&String.trim/1)
  end

  describe "pickers" do
    test "the access form picks SSH user and host by search, sorted by name", %{conn: conn} do
      user_fixture(%{username: "zed"})
      user_fixture(%{username: "Alice"})
      user_fixture(%{username: "bob"})
      host_fixture(%{name: "web2"})
      host_fixture(%{name: "db1"})

      {:ok, view, _html} = live(conn, ~p"/authorizations")
      view |> element("button", "New authorization") |> render_click()

      assert has_element?(view, ~s([phx-hook="Combobox"] input[data-combobox-input]))

      assert option_labels(view, "#authorization_user_id") == [
               "Select a user",
               "Alice",
               "bob",
               "zed"
             ]

      assert option_labels(view, "#authorization_host_id") == ["Select a host", "db1", "web2"]
    end

    test "list filters are searchable and sorted", %{conn: conn} do
      user_fixture(%{username: "zed"})
      user_fixture(%{username: "amy"})

      {:ok, view, _html} = live(conn, ~p"/keys")

      assert has_element?(view, ~s(#keys-filter [phx-hook="Combobox"]))
      assert option_labels(view, "#keys-filter-user") == ["All users", "amy", "zed"]
    end

    test "grant targets are sorted inside their groups", %{conn: conn} do
      {:ok, _} = Customers.create_customer(%{slug: "zeta", name: "Zeta"})
      {:ok, _} = Customers.create_customer(%{slug: "acme", name: "Acme"})
      {:ok, _} = Groups.create_group(%{slug: "web", name: "Webservers"})
      {:ok, _} = Groups.create_group(%{slug: "db", name: "Databases"})

      {:ok, view, _html} = live(conn, ~p"/grants")
      view |> element("#new-grant") |> render_click()

      assert option_labels(view, "#grant_target") ==
               ["Select a target", "Acme", "Zeta", "Databases", "Webservers"]

      assert has_element?(view, ~s(#grant_target-picker input[data-combobox-input]))
    end
  end

  describe "merge preview" do
    test "names who is deleted, what moves and which grants are lost", %{conn: conn} do
      {:ok, acme} = Customers.create_customer(%{slug: "acme", name: "Acme"})
      target = user_fixture(%{username: "canonical"})
      source = user_fixture(%{username: "dupe"})
      key_fixture(source)
      key_fixture(source)
      authorization_fixture(source, host_fixture(), %{login: "deploy"})

      {:ok, _grant} =
        Grants.create_grant(%{role: "admin", scope: Scope.global(), actor: "admin"}, %{
          ssh_user_id: source.id,
          customer_id: acme.id,
          login: "ops"
        })

      {:ok, view, _html} = live(conn, ~p"/users")
      view |> element("#select-user-#{target.id}") |> render_click()
      view |> element("#select-user-#{source.id}") |> render_click()
      view |> element("#bulk-merge") |> render_click()

      view
      |> element("#merge-form")
      |> render_change(%{merge: %{mode: "existing", target_id: target.id}})

      assert has_element?(view, "#merge-preview", "Deletes 1 SSH user: dupe")
      assert has_element?(view, "#merge-preview", "Moves 2 keys to canonical")
      assert has_element?(view, "#merge-preview", "Copies up to 1 access entry")
      assert has_element?(view, "#merge-lost-grants", "1 customer/group grant")
    end
  end
end
