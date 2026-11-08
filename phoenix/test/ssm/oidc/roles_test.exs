defmodule Ssm.OIDC.RolesTest do
  use Ssm.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ssm.OIDC.{Config, Roles}

  @config %Config{issuer: "https://idp.test", client_id: "ssm", client_secret: "x"}

  setup do
    {:ok, _} = Ssm.Customers.create_customer(%{slug: "acme", name: "Acme"})
    {:ok, _} = Ssm.Groups.create_group(%{slug: "web", name: "Web"})
    :ok
  end

  defp claims(role, extra \\ %{}) do
    %{"orbit_role" => role, "orbit_customers" => ["*"], "orbit_groups" => ["*"]}
    |> Map.merge(extra)
    |> Map.reject(fn {_k, v} -> v == :drop end)
  end

  describe "scope claims (ADR-0012 §1)" do
    test "wildcards in both dimensions" do
      assert {:ok, "operator", %{customers: ["*"], groups: ["*"]}} =
               Roles.resolve(claims("operator"), @config)
    end

    test "slug lists are kept (deduplicated)" do
      c = claims("viewer", %{"orbit_customers" => ["acme", "acme"], "orbit_groups" => ["web"]})
      assert {:ok, "viewer", %{customers: ["acme"], groups: ["web"]}} = Roles.resolve(c, @config)
    end

    for role <- ~w(operator viewer) do
      test "#{role}: missing customers claim refuses" do
        c = claims(unquote(role), %{"orbit_customers" => :drop})
        assert {:error, :customers_missing} = Roles.resolve(c, @config)
      end

      test "#{role}: missing groups claim refuses" do
        c = claims(unquote(role), %{"orbit_groups" => :drop})
        assert {:error, :groups_missing} = Roles.resolve(c, @config)
      end
    end

    for {label, value} <- [
          {"mixed wildcard", ["*", "acme"]},
          {"empty list", []},
          {"string instead of list", "acme"},
          {"non-string entry", ["acme", 1]},
          {"empty slug", [""]},
          {"null", nil}
        ] do
      test "malformed customers (#{label}) refuses" do
        c = claims("operator", %{"orbit_customers" => unquote(Macro.escape(value))})
        assert {:error, :customers_malformed} = Roles.resolve(c, @config)
      end

      test "malformed groups (#{label}) refuses" do
        c = claims("operator", %{"orbit_groups" => unquote(Macro.escape(value))})
        assert {:error, :groups_malformed} = Roles.resolve(c, @config)
      end
    end

    test "OIDC_GROUPS_DEFAULT=* lets a missing groups claim count as *" do
      c = claims("operator", %{"orbit_groups" => :drop})
      config = %{@config | groups_default: :all}
      assert {:ok, "operator", %{groups: ["*"]}} = Roles.resolve(c, config)
    end

    test "OIDC_GROUPS_DEFAULT does not excuse a malformed groups claim" do
      c = claims("operator", %{"orbit_groups" => ["*", "web"]})
      config = %{@config | groups_default: :all}
      assert {:error, :groups_malformed} = Roles.resolve(c, config)
    end

    test "OIDC_GROUPS_DEFAULT does not excuse a missing customers claim" do
      c = claims("operator", %{"orbit_customers" => :drop, "orbit_groups" => :drop})
      config = %{@config | groups_default: :all}
      assert {:error, :customers_missing} = Roles.resolve(c, config)
    end

    test "configurable groups claim name" do
      c = claims("operator", %{"orbit_groups" => :drop, "hostgroups" => ["web"]})
      config = %{@config | groups_claim: "hostgroups"}
      assert {:ok, "operator", %{groups: ["web"]}} = Roles.resolve(c, config)
    end

    test "unknown slugs grant nothing and are logged" do
      c = claims("operator", %{"orbit_customers" => ["ghost"], "orbit_groups" => ["nogroup"]})

      log =
        capture_log(fn ->
          assert {:ok, "operator", %{customers: [], groups: []}} = Roles.resolve(c, @config)
        end)

      assert log =~ "ghost"
      assert log =~ "nogroup"
    end
  end

  describe "admin" do
    test "with * scope signs in" do
      assert {:ok, "admin", %{customers: ["*"], groups: ["*"]}} =
               Roles.resolve(claims("admin"), @config)
    end

    test "without scope claims counts as global" do
      c = claims("admin", %{"orbit_customers" => :drop, "orbit_groups" => :drop})
      assert {:ok, "admin", %{customers: ["*"], groups: ["*"]}} = Roles.resolve(c, @config)
    end

    test "with a customer restriction is refused, never downgraded" do
      c = claims("admin", %{"orbit_customers" => ["acme"]})
      assert {:error, :admin_scoped} = Roles.resolve(c, @config)
    end

    test "with a group restriction is refused" do
      c = claims("admin", %{"orbit_groups" => ["web"]})
      assert {:error, :admin_scoped} = Roles.resolve(c, @config)
    end

    test "with an unknown-slug restriction is refused too" do
      c = claims("admin", %{"orbit_customers" => ["ghost"]})
      capture_log(fn -> assert {:error, :admin_scoped} = Roles.resolve(c, @config) end)
    end

    test "with a malformed claim is refused" do
      c = claims("admin", %{"orbit_groups" => ["*", "web"]})
      assert {:error, :groups_malformed} = Roles.resolve(c, @config)
    end
  end

  test "customer role and unknown roles stay refused" do
    assert {:error, :customer_role} = Roles.resolve(claims("customer"), @config)
    assert {:error, :unknown_role} = Roles.resolve(claims("wizard"), @config)
  end
end
