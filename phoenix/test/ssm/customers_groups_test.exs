defmodule Ssm.CustomersGroupsTest do
  use Ssm.DataCase, async: false

  alias Ssm.{Customers, Groups}

  for {context, create, update, page, get} <- [
        {Customers, :create_customer, :update_customer, :page_customers, :get_customer_by_slug},
        {Groups, :create_group, :update_group, :page_groups, :get_group_by_slug}
      ] do
    describe "#{inspect(context)}" do
      test "create + get by slug" do
        assert {:ok, item} =
                 apply(unquote(context), unquote(create), [
                   %{slug: "kunde-a", name: "Kunde A GmbH"}
                 ])

        assert item.slug == "kunde-a"
        assert apply(unquote(context), unquote(get), ["kunde-a"]).id == item.id
        assert apply(unquote(context), unquote(get), ["nope"]) == nil
      end

      test "slug format is enforced" do
        for bad <- ["", "Upper", "-lead", "a b", String.duplicate("a", 64), "ü"] do
          assert {:error, changeset} =
                   apply(unquote(context), unquote(create), [%{slug: bad, name: "X"}])

          assert %{slug: [_ | _]} = errors_on(changeset), "accepted #{inspect(bad)}"
        end

        assert {:ok, _} =
                 apply(unquote(context), unquote(create), [
                   %{slug: "a" <> String.duplicate("b", 62), name: "max"}
                 ])
      end

      test "slug is unique" do
        {:ok, _} = apply(unquote(context), unquote(create), [%{slug: "dup", name: "One"}])

        assert {:error, changeset} =
                 apply(unquote(context), unquote(create), [%{slug: "dup", name: "Two"}])

        assert %{slug: ["has already been taken"]} = errors_on(changeset)
      end

      test "name is required" do
        assert {:error, changeset} = apply(unquote(context), unquote(create), [%{slug: "x"}])
        assert %{name: [_]} = errors_on(changeset)
      end

      test "update changes the name only; the slug is fixed after create" do
        {:ok, item} = apply(unquote(context), unquote(create), [%{slug: "fixed", name: "Old"}])

        {:ok, updated} =
          apply(unquote(context), unquote(update), [item, %{name: "New", slug: "moved"}])

        assert updated.name == "New"
        assert updated.slug == "fixed"
      end

      test "keyset paging by slug" do
        for slug <- ~w(c a b d),
            do: {:ok, _} = apply(unquote(context), unquote(create), [%{slug: slug, name: slug}])

        assert {[%{slug: "a"}, %{slug: "b"}], "b"} =
                 apply(unquote(context), unquote(page), [nil, 2])

        assert {[%{slug: "c"}, %{slug: "d"}], nil} =
                 apply(unquote(context), unquote(page), ["b", 2])

        assert {[], nil} = apply(unquote(context), unquote(page), ["d", 2])
      end
    end
  end
end
