defmodule SsmWeb.AccessMatrix do
  @moduledoc """
  The users x hosts matrix of the Access page (ADR-0014 "Matrix"), pure data:
  URL state, filters, hide-empty, sort and totals. `SsmWeb.AccessMatrixComponents`
  renders it.

  URL parameters (defaults are not written):

    * `?q=` search over user names (rows)
    * `?f[host]=` filter over host name, address and customer (columns)
    * `?sort=user:desc,col_total:desc` - `user` / `row_total` sort the rows,
      `host` / `col_total` the columns; per axis the first key counts,
      default `user:asc` and `host:asc`
    * `?hide=rows,cols` - hide rows / columns without access
    * `?login=` the target login, `all` is the view-only count over all logins

  Totals are the number of hosts per user (row) and of users per host
  (column), over the filtered axes and computed once in `build/6`, not per
  cell. Hiding empty rows and columns follows from those totals.
  """

  @type dir :: :asc | :desc
  @type opts :: %{
          q: String.t(),
          host: String.t(),
          row_sort: {:name | :total, dir()},
          col_sort: {:name | :total, dir()},
          hide_rows: boolean(),
          hide_cols: boolean()
        }

  @sort_keys %{
    "user" => {:row, :name},
    "row_total" => {:row, :total},
    "host" => {:col, :name},
    "col_total" => {:col, :total}
  }
  @default_sort {:name, :asc}

  @doc "Matrix options from the URL params of the page."
  @spec parse(map()) :: opts()
  def parse(params) do
    sorts = parse_sort(params["sort"])
    hide = parse_hide(params["hide"])

    %{
      q: text(params["q"]),
      host: text(get_in_map(params["f"], "host")),
      row_sort: Map.get(sorts, :row, @default_sort),
      col_sort: Map.get(sorts, :col, @default_sort),
      hide_rows: "rows" in hide or params["authorized"] == "1",
      hide_cols: "cols" in hide
    }
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""

  defp get_in_map(%{} = map, key), do: map[key]
  defp get_in_map(_other, _key), do: nil

  defp parse_hide(value) when is_binary(value), do: String.split(value, ",", trim: true)
  defp parse_hide(_value), do: []

  # first valid key per axis wins
  defp parse_sort(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce(%{}, fn entry, acc ->
      with [key, dir] <- String.split(entry, ":"),
           {axis, field} <- Map.get(@sort_keys, key),
           {:ok, dir} <- direction(dir) do
        Map.put_new(acc, axis, {field, dir})
      else
        _ -> acc
      end
    end)
  end

  defp parse_sort(_value), do: %{}

  defp direction("asc"), do: {:ok, :asc}
  defp direction("desc"), do: {:ok, :desc}
  defp direction(_other), do: :error

  @doc "URL query of `opts` and `login` (nil: the page picks), defaults left out."
  @spec to_query(opts(), String.t() | nil) :: map()
  def to_query(opts, login) do
    %{"view" => "matrix"}
    |> put_present("login", login)
    |> put_present("q", opts.q)
    |> put_present("f", host_filter(opts.host))
    |> put_present("sort", sort_param(opts))
    |> put_present("hide", hide_param(opts))
  end

  defp put_present(map, _key, value) when value in ["", nil, %{}], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp host_filter(""), do: nil
  defp host_filter(host), do: %{"host" => host}

  defp sort_param(opts) do
    [{"user", "row_total", opts.row_sort}, {"host", "col_total", opts.col_sort}]
    |> Enum.reject(fn {_name, _total, sort} -> sort == @default_sort end)
    |> Enum.map_join(",", fn
      {name, _total, {:name, dir}} -> "#{name}:#{dir}"
      {_name, total, {:total, dir}} -> "#{total}:#{dir}"
    end)
  end

  defp hide_param(opts) do
    [{opts.hide_rows, "rows"}, {opts.hide_cols, "cols"}]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map_join(",", &elem(&1, 1))
  end

  @doc """
  Rows, columns, cells and totals. `users` have `id` and `username`, `hosts`
  `id`, `name`, `address` and `customer_id` (named by `customers`), `entries`
  are `{user_id, host_id, login}`. `login` is one login or `"all"`.

  Returns `%{mode, cells, rows, cols, row_totals, col_totals, total}`; `cells`
  maps `{user_id, host_id}` to the number of entries (always 1 for one login).
  """
  @spec build(opts(), String.t(), [map()], [map()], [tuple()], map()) :: map()
  def build(opts, login, users, hosts, entries, customers \\ %{}) do
    users = Enum.filter(users, &contains?(&1.username, opts.q))
    hosts = Enum.filter(hosts, &host_matches?(&1, opts.host, customers))
    cells = tally(entries, login, ids(users), ids(hosts))
    {row_totals, col_totals} = totals(cells)

    %{
      mode: if(login == "all", do: :all, else: :login),
      cells: cells,
      rows: arrange(users, row_totals, opts.row_sort, opts.hide_rows, & &1.username),
      cols: arrange(hosts, col_totals, opts.col_sort, opts.hide_cols, & &1.name),
      row_totals: row_totals,
      col_totals: col_totals,
      total: map_size(cells)
    }
  end

  defp ids(items), do: MapSet.new(items, & &1.id)

  defp contains?(_text, ""), do: true

  defp contains?(text, needle),
    do: String.contains?(String.downcase(text), String.downcase(needle))

  defp host_matches?(host, needle, customers) do
    contains?(
      "#{host.name} #{host.address} #{Map.get(customers, host.customer_id)}",
      needle
    )
  end

  defp tally(entries, login, user_ids, host_ids) do
    Enum.reduce(entries, %{}, fn {user_id, host_id, entry_login}, cells ->
      if (login == "all" or entry_login == login) and
           MapSet.member?(user_ids, user_id) and MapSet.member?(host_ids, host_id) do
        Map.update(cells, {user_id, host_id}, 1, &(&1 + 1))
      else
        cells
      end
    end)
  end

  defp totals(cells) do
    Enum.reduce(cells, {%{}, %{}}, fn {{user_id, host_id}, _count}, {rows, cols} ->
      {Map.update(rows, user_id, 1, &(&1 + 1)), Map.update(cols, host_id, 1, &(&1 + 1))}
    end)
  end

  defp arrange(items, totals, sort, hide?, name_fun) do
    items
    |> Enum.reject(&(hide? and not Map.has_key?(totals, &1.id)))
    |> sorted(totals, sort, name_fun)
  end

  defp sorted(items, _totals, {:name, dir}, name_fun),
    do: Enum.sort_by(items, &{String.downcase(name_fun.(&1)), &1.id}, dir)

  # ties stay in name order whichever way the totals run
  defp sorted(items, totals, {:total, dir}, name_fun) do
    sign = if dir == :asc, do: 1, else: -1

    Enum.sort_by(
      items,
      &{sign * Map.get(totals, &1.id, 0), String.downcase(name_fun.(&1)), &1.id}
    )
  end

  # DOM bounds: a page of users / hosts, and the most a "Show more" reaches
  @rows_page 50
  @rows_max 100
  @cols_page 20
  @cols_max 50

  @doc "Users per page of the matrix and the most that \"Show more\" reaches."
  @spec rows_page() :: pos_integer()
  def rows_page, do: @rows_page
  def rows_max, do: @rows_max

  @doc "Hosts per page of the matrix and the most that \"Show more\" reaches."
  @spec cols_page() :: pos_integer()
  def cols_page, do: @cols_page
  def cols_max, do: @cols_max
end
