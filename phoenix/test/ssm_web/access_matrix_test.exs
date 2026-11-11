defmodule SsmWeb.AccessMatrixTest do
  use ExUnit.Case, async: true

  alias SsmWeb.AccessMatrix

  @users [
    %{id: 1, username: "alice"},
    %{id: 2, username: "bob"},
    %{id: 3, username: "carol"},
    %{id: 4, username: "idle"}
  ]

  @hosts [
    %{id: 10, name: "web1", address: "10.0.0.1", customer_id: 1},
    %{id: 11, name: "db1", address: "10.0.0.2", customer_id: 2},
    %{id: 12, name: "unused", address: "10.0.0.3", customer_id: nil}
  ]

  # {user_id, host_id, login}
  @entries [
    {1, 10, "root"},
    {1, 11, "root"},
    {2, 10, "root"},
    {2, 10, "deploy"},
    {3, 11, "deploy"}
  ]

  @customers %{1 => "Acme", 2 => "Beta"}

  defp build(params, login \\ "root") do
    AccessMatrix.build(AccessMatrix.parse(params), login, @users, @hosts, @entries, @customers)
  end

  defp names(items, key), do: Enum.map(items, &Map.fetch!(&1, key))

  describe "totals" do
    test "per user the hosts with access, per host the users, computed once" do
      m = build(%{})

      assert m.row_totals == %{1 => 2, 2 => 1}
      assert m.col_totals == %{10 => 2, 11 => 1}
      assert m.total == 3
    end

    test "the all view counts distinct pairs, cells hold the number of logins" do
      m = build(%{}, "all")

      assert m.row_totals[2] == 1
      assert m.cells[{2, 10}] == 2
      assert m.total == 4
    end

    test "totals follow the filters of the other axis" do
      m = build(%{"f" => %{"host" => "acme"}})

      assert names(m.cols, :name) == ["web1"]
      assert m.row_totals == %{1 => 1, 2 => 1}
    end
  end

  describe "filter, hide, sort" do
    test "users: search by name; hosts: filter by name, address or customer" do
      assert names(build(%{"q" => "AL"}).rows, :username) == ["alice"]
      assert names(build(%{"f" => %{"host" => "db"}}).cols, :name) == ["db1"]
      assert names(build(%{"f" => %{"host" => "10.0.0.3"}}).cols, :name) == ["unused"]
      assert names(build(%{"f" => %{"host" => "beta"}}).cols, :name) == ["db1"]
    end

    test "hide empty rows and columns" do
      assert names(build(%{}).rows, :username) == ~w(alice bob carol idle)
      assert names(build(%{}).cols, :name) == ~w(db1 unused web1)

      hidden = build(%{"hide" => "rows,cols"})
      assert names(hidden.rows, :username) == ~w(alice bob)
      assert names(hidden.cols, :name) == ~w(db1 web1)
    end

    test "sort by name or by total, both directions, ties by name" do
      assert names(build(%{"sort" => "user:desc"}).rows, :username) == ~w(idle carol bob alice)

      by_total = build(%{"sort" => "row_total:desc,col_total:asc"})
      assert names(by_total.rows, :username) == ~w(alice bob carol idle)
      assert names(by_total.cols, :name) == ~w(unused db1 web1)

      assert names(build(%{"sort" => "row_total:asc"}).rows, :username) ==
               ~w(carol idle bob alice)
    end
  end

  describe "URL state" do
    test "defaults are not written" do
      assert AccessMatrix.to_query(AccessMatrix.parse(%{}), "root") == %{
               "view" => "matrix",
               "login" => "root"
             }
    end

    test "parse and to_query round-trip the ADR names" do
      params = %{
        "view" => "matrix",
        "login" => "deploy",
        "q" => "ali",
        "f" => %{"host" => "web"},
        "sort" => "row_total:desc,host:desc",
        "hide" => "rows,cols"
      }

      assert AccessMatrix.to_query(AccessMatrix.parse(params), "deploy") == params
    end

    test "garbage is ignored, the old ?authorized=1 still hides empty rows" do
      opts = AccessMatrix.parse(%{"sort" => "zzz:up,user", "hide" => "x", "f" => "str", "q" => 5})

      assert AccessMatrix.to_query(opts, "root") == %{"view" => "matrix", "login" => "root"}
      assert AccessMatrix.parse(%{"authorized" => "1"}).hide_rows
    end
  end
end
