defmodule SsmWeb.ScopeCatalogTest do
  @moduledoc """
  ADR-0012 §3, SSH user catalog: a scoped operator reads every SSH user but
  changes users and keys only of SSH users whose authorizations are all in
  its scope (a key change lands on every host of that user).
  """
  use SsmWeb.OIDCCase

  import Phoenix.LiveViewTest
  import Ssm.Fixtures

  alias Ssm.{Hosts, Scope, Users}
  alias Ssm.Users.{BulkOps, KeyAssignment}

  setup do
    {:ok, _} = Ssm.Customers.create_customer(%{slug: "acme", name: "Acme"})
    {:ok, _} = Ssm.Customers.create_customer(%{slug: "beta", name: "Beta"})
    in_host = member(host_fixture(%{name: "in-host"}), "acme")
    out_host = member(host_fixture(%{name: "out-host"}), "beta")

    # alice: only in scope; bob: only outside; dave: both; carol: no grants
    alice = user_fixture(%{username: "alice"})
    bob = user_fixture(%{username: "bob"})
    dave = user_fixture(%{username: "dave"})
    carol = user_fixture(%{username: "carol"})
    authorization_fixture(alice, in_host)
    authorization_fixture(bob, out_host)
    authorization_fixture(dave, in_host)
    authorization_fixture(dave, out_host)

    keys =
      Map.new([alice, bob, dave, carol], fn u ->
        key_fixture(u)
        {u.username, key_fixture(u)}
      end)

    %{
      in_host: in_host,
      out_host: out_host,
      alice: alice,
      bob: bob,
      dave: dave,
      carol: carol,
      keys: keys,
      scope: Scope.new(["acme"], ["*"])
    }
  end

  defp member(host, customer) do
    {:ok, host} = Hosts.update_membership(host, %{customer: customer})
    host
  end

  defp scoped(conn, p),
    do: sso_login(conn, p, %{"orbit_role" => "operator", "orbit_customers" => ["acme"]})

  defp unscoped(conn, p), do: sso_login(conn, p, %{"orbit_role" => "operator"})

  describe "context" do
    test "writable?/2: at least one authorization, all of them in scope", c do
      assert Users.writable?(c.scope, c.alice)
      refute Users.writable?(c.scope, c.carol)
      refute Users.writable?(c.scope, c.bob)
      refute Users.writable?(c.scope, c.dave)
      assert Users.writable?(Scope.global(), c.dave)
      assert Users.writable?(Scope.global(), c.carol)
      refute Users.writable?(Scope.none(), c.alice)
      refute Users.writable?(Scope.none(), c.carol)
    end

    test "user and key writes are refused outside the scope", c do
      assert {:error, :out_of_scope} = Users.update_user(c.scope, c.bob, %{comment: "x"})
      assert {:error, :out_of_scope} = Users.delete_user(c.scope, c.dave)
      assert {:error, :out_of_scope} = Users.delete_key(c.scope, c.keys["bob"])
      assert {:error, :out_of_scope} = Users.update_key(c.scope, c.keys["dave"], %{name: "n"})

      assert {:error, :out_of_scope} =
               Users.create_key(c.scope, %{
                 user_id: c.bob.id,
                 key_type: "ssh-ed25519",
                 key_base64: "AAAANEW"
               })

      # moving a key to an out-of-scope user is a write on that user too
      assert {:error, :out_of_scope} =
               Users.update_key(c.scope, c.keys["alice"], %{user_id: c.bob.id})

      # a user without authorizations is read-only until authorized in scope
      assert {:error, :out_of_scope} = Users.delete_key(c.scope, c.keys["carol"])
      assert {:error, :out_of_scope} = Users.delete_user(c.scope, c.carol)

      assert {:ok, _} = Users.update_user(c.scope, c.alice, %{comment: "ok"})
      assert {:ok, _} = Users.delete_key(c.scope, c.keys["alice"])
    end

    test "bulk ops are refused when any user is outside the scope", c do
      assert {:error, :out_of_scope} = BulkOps.split_user(c.scope, c.bob, "bob2", [])
      assert {:error, :out_of_scope} = BulkOps.merge_users(c.scope, [c.alice, c.bob], c.alice)
      assert {:error, :out_of_scope} = BulkOps.merge_users(c.scope, [c.alice, c.carol], c.bob)

      result = BulkOps.bulk_delete(c.scope, [c.alice, c.bob, c.carol])
      assert Enum.map(result.deleted, & &1.username) == ["alice"]

      assert [{%{username: "bob"}, :out_of_scope}, {%{username: "carol"}, :out_of_scope}] =
               result.failed

      assert Users.get_user(c.bob.id)
    end

    test "key assignment needs a writable user and an in-scope host", c do
      parsed = %{key_type: "ssh-ed25519", key_base64: "AAAAASSIGN", name: "laptop"}
      base = %{parsed: parsed, login: "ops", username: nil, key_name: nil, scope: c.scope}

      assert {:error, {:key, msg}} =
               KeyAssignment.assign(Map.merge(base, %{user: c.bob, host_id: c.in_host.id}))

      assert msg =~ "outside your scope"

      assert {:error, {:authorization, _}} =
               KeyAssignment.assign(Map.merge(base, %{user: c.alice, host_id: c.out_host.id}))

      refute Users.get_key_by_base64("AAAAASSIGN")

      assert {:ok, %{granted?: true}} =
               KeyAssignment.assign(Map.merge(base, %{user: c.alice, host_id: c.in_host.id}))
    end
  end

  describe "users page" do
    test "lists every SSH user, read-only outside the scope", %{conn: conn, provider: p} = c do
      {:ok, lv, html} = live(scoped(conn, p), ~p"/users")
      for name <- ~w(alice bob carol dave), do: assert(html =~ name)

      for event <- ~w(edit delete toggle_enabled split-open) do
        assert render_click(lv, event, %{"id" => to_string(c.bob.id)}) =~ "outside your scope"
      end

      assert %{enabled: true} = Users.get_user(c.bob.id)

      render_click(lv, "toggle-select", %{"id" => to_string(c.alice.id)})
      render_click(lv, "toggle-select", %{"id" => to_string(c.dave.id)})
      render_click(lv, "merge-open", %{})
      assert render_click(lv, "merge-save", %{}) =~ "outside your scope"
      assert Users.get_user(c.dave.id)

      render_click(lv, "bulk-delete-open", %{})
      html = render_click(lv, "bulk-delete-confirm", %{})
      assert html =~ "could not be deleted"
      assert Users.get_user(c.dave.id)
      refute Users.get_user(c.alice.id)
    end

    test "users fully in scope can be changed and new ones created",
         %{conn: conn, provider: p} = c do
      {:ok, lv, _} = live(scoped(conn, p), ~p"/users")
      assert render_click(lv, "toggle_enabled", %{"id" => to_string(c.alice.id)}) =~ "disabled"
      render_click(lv, "new", %{})
      render_submit(lv, "save", %{"user" => %{"username" => "erin"}})
      erin = Enum.find(Users.list_users(), &(&1.username == "erin"))
      assert erin
      # keys only after an in-scope authorization exists
      refute Users.writable?(c.scope, erin)
      authorization_fixture(erin, c.in_host)
      assert Users.writable?(c.scope, erin)
    end

    test "an unscoped operator is unchanged", %{conn: conn, provider: p} = c do
      {:ok, lv, _} = live(unscoped(conn, p), ~p"/users")
      assert render_click(lv, "toggle_enabled", %{"id" => to_string(c.bob.id)}) =~ "disabled"
    end
  end

  describe "keys page" do
    test "keys of SSH users with grants outside the scope stay read-only", %{
      conn: conn,
      provider: p,
      keys: keys,
      bob: bob,
      alice: alice
    } do
      {:ok, lv, html} = live(scoped(conn, p), ~p"/keys")
      assert html =~ keys["bob"].name

      assert render_click(lv, "edit", %{"id" => to_string(keys["bob"].id)}) =~
               "outside your scope"

      assert render_click(lv, "delete", %{"id" => to_string(keys["bob"].id)}) =~
               "outside your scope"

      assert Users.get_key(keys["bob"].id)

      line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDe2nndD7+tlXY2983h/zouDiBPDl6Ni4YtTK7Y5TyuQ x"
      render_click(lv, "import-open", %{})

      html =
        render_submit(lv, "import", %{
          "import" => %{"user_id" => to_string(bob.id), "keys_text" => line}
        })

      assert html =~ "outside your scope"
      assert length(Users.list_keys(user_id: bob.id)) == 2

      assert render_click(lv, "delete", %{"id" => to_string(keys["alice"].id)}) =~ "deleted"
      assert length(Users.list_keys(user_id: alice.id)) == 1
    end
  end
end
