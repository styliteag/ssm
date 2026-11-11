defmodule SsmWeb.AccessMatrixComponents do
  @moduledoc """
  Rendering of the Access page's users x hosts matrix (`SsmWeb.AccessMatrix`
  holds the data and URL state). The axes are capped: `rows_limit` users and
  `cols_limit` hosts are in the DOM, with a visible count and "Show more".
  Rotated host headers only for up to 10 visible columns, beyond that the
  host filter does the narrowing.
  """

  use SsmWeb, :html

  alias SsmWeb.AccessMatrix

  @rotate_up_to 10

  @row_sorts [
    {"Users A-Z", "user:asc"},
    {"Users Z-A", "user:desc"},
    {"Most hosts first", "row_total:desc"},
    {"Fewest hosts first", "row_total:asc"}
  ]
  @col_sorts [
    {"Hosts A-Z", "host:asc"},
    {"Hosts Z-A", "host:desc"},
    {"Most users first", "col_total:desc"},
    {"Fewest users first", "col_total:asc"}
  ]

  defp rotate_up_to, do: @rotate_up_to
  defp row_sorts, do: @row_sorts
  defp col_sorts, do: @col_sorts

  attr :matrix, :map, required: true
  attr :opts, :map, required: true
  attr :login, :string, required: true
  attr :login_accounts, :list, required: true
  attr :editable, :boolean, required: true, doc: "false for the all view and for viewers"
  attr :read_only, :boolean, default: false
  attr :rows_limit, :integer, required: true
  attr :cols_limit, :integer, required: true

  def matrix_view(assigns) do
    rows = Enum.take(assigns.matrix.rows, assigns.rows_limit)
    cols = Enum.take(assigns.matrix.cols, assigns.cols_limit)

    assigns =
      assign(assigns,
        grid: grid(assigns.matrix, rows, cols),
        col_heads: Enum.map(cols, &{&1, Map.get(assigns.matrix.col_totals, &1.id, 0)}),
        rows: rows,
        cols: cols,
        rotate: length(cols) <= @rotate_up_to,
        filtered: filtered?(assigns.opts)
      )

    ~H"""
    <div id="matrix" class="space-y-3">
      <.matrix_controls
        opts={@opts}
        login={@login}
        login_accounts={@login_accounts}
        filtered={@filtered}
      />

      <p :if={@matrix.cols == [] or @matrix.rows == []} id="matrix-empty" class="text-sm opacity-60">
        {empty_text(@matrix, @filtered)}
        <.link :if={@filtered} patch={~p"/access?view=matrix&login=#{@login}"} class="link">
          Clear filters
        </.link>
      </p>

      <div
        :if={@matrix.cols != [] and @matrix.rows != []}
        id="matrix-scroll"
        class="max-h-[75vh] overflow-auto rounded-box border border-base-300"
      >
        <table class="table table-xs w-auto border-collapse">
          <thead>
            <tr>
              <th class="sticky left-0 top-0 z-30 w-44 min-w-44 max-w-44 bg-base-200 align-bottom">
                Users / Hosts
              </th>
              <th
                class="sticky left-44 top-0 z-30 w-12 min-w-12 bg-base-200 text-center align-bottom"
                title="Number of hosts per user"
              >
                Hosts
              </th>
              <.host_header
                :for={{host, total} <- @col_heads}
                host={host}
                total={total}
                rotate={@rotate}
              />
            </tr>
          </thead>
          <tbody>
            <tr
              :for={{user, total, cells} <- @grid}
              id={"matrix-row-#{user.id}"}
              class="hover:bg-base-200"
            >
              <.user_header user={user} total={total} />
              <td :for={{host, count} <- cells} class="border border-base-300/50 p-0.5 text-center">
                <.matrix_cell
                  user={user}
                  host={host}
                  count={count}
                  login={@login}
                  editable={@editable}
                  mode={@matrix.mode}
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.matrix_position
        :if={@matrix.cols != [] and @matrix.rows != []}
        rows={length(@rows)}
        rows_total={length(@matrix.rows)}
        cols={length(@cols)}
        cols_total={length(@matrix.cols)}
        total={@matrix.total}
      />

      <.matrix_legend login={@login} editable={@editable} read_only={@read_only} mode={@matrix.mode} />
    </div>
    """
  end

  # The visible cells as plain data, so the template never reads the big
  # `cells` map through an assign (LiveView's change tracking would compare it
  # on every access: 450 ms per render at 2,000 x 500).
  defp grid(matrix, rows, cols) do
    for user <- rows do
      cells = for host <- cols, do: {host, Map.get(matrix.cells, {user.id, host.id}, 0)}
      {user, Map.get(matrix.row_totals, user.id, 0), cells}
    end
  end

  defp filtered?(opts), do: opts.q != "" or opts.host != "" or opts.hide_rows or opts.hide_cols

  defp empty_text(%{cols: [], rows: []}, true), do: "No user and no host match the filters."
  defp empty_text(%{cols: []}, true), do: "No host matches the filters."
  defp empty_text(%{rows: []}, true), do: "No user matches the filters."
  defp empty_text(%{cols: []}, false), do: "There are no hosts in your scope."
  defp empty_text(%{rows: []}, false), do: "There are no SSH users yet."

  attr :opts, :map, required: true
  attr :login, :string, required: true
  attr :login_accounts, :list, required: true
  attr :filtered, :boolean, required: true

  defp matrix_controls(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end gap-3">
      <form
        id="matrix-form"
        phx-change="matrix-params"
        phx-submit="matrix-params"
        class="flex flex-wrap items-end gap-3"
      >
        <label class="fieldset mb-2 w-48">
          <span class="label mb-1">Search users</span>
          <input
            type="search"
            name="q"
            value={@opts.q}
            placeholder="Username…"
            class="input input-sm w-full"
            phx-debounce="300"
            autocomplete="off"
          />
        </label>
        <label class="fieldset mb-2 w-52">
          <span class="label mb-1">Filter hosts</span>
          <input
            type="search"
            name="host"
            value={@opts.host}
            placeholder="Name, address or customer…"
            class="input input-sm w-full"
            phx-debounce="300"
            autocomplete="off"
          />
        </label>
        <div class="w-52">
          <.input
            type="select"
            id="matrix-login"
            name="login"
            value={@login}
            label="Target login"
            options={
              [{"all (view only)", "all"}] ++
                Enum.map(@login_accounts, fn {login, count} -> {"#{login} (#{count})", login} end)
            }
          />
        </div>
        <div class="w-44">
          <.input
            type="select"
            id="matrix-sort-rows"
            name="sort_rows"
            value={sort_value(@opts.row_sort, "user", "row_total")}
            label="Sort users"
            options={row_sorts()}
          />
        </div>
        <div class="w-44">
          <.input
            type="select"
            id="matrix-sort-cols"
            name="sort_cols"
            value={sort_value(@opts.col_sort, "host", "col_total")}
            label="Sort hosts"
            options={col_sorts()}
          />
        </div>
      </form>
      <div class="mb-2 flex flex-wrap items-center gap-2">
        <button
          id="matrix-hide-rows"
          type="button"
          class={["btn btn-sm", @opts.hide_rows && "btn-primary"]}
          aria-pressed={to_string(@opts.hide_rows)}
          phx-click="matrix-hide"
          phx-value-axis="rows"
        >
          <.icon name="hero-eye-slash" class="size-4" /> Hide empty rows
        </button>
        <button
          id="matrix-hide-cols"
          type="button"
          class={["btn btn-sm", @opts.hide_cols && "btn-primary"]}
          aria-pressed={to_string(@opts.hide_cols)}
          phx-click="matrix-hide"
          phx-value-axis="cols"
        >
          <.icon name="hero-eye-slash" class="size-4" /> Hide empty columns
        </button>
        <.link
          :if={@filtered}
          id="matrix-clear"
          patch={~p"/access?view=matrix&login=#{@login}"}
          class="btn btn-ghost btn-sm"
        >
          Clear filters
        </.link>
      </div>
    </div>
    """
  end

  defp sort_value({:name, dir}, name_key, _total_key), do: "#{name_key}:#{dir}"
  defp sort_value({:total, dir}, _name_key, total_key), do: "#{total_key}:#{dir}"

  attr :host, :map, required: true
  attr :total, :integer, required: true
  attr :rotate, :boolean, required: true

  defp host_header(assigns) do
    ~H"""
    <th class="sticky top-0 z-20 bg-base-200 px-1 pb-1 text-center align-bottom">
      <.link
        navigate={~p"/diff?host_id=#{@host.id}"}
        class={[
          "link link-hover inline-block truncate whitespace-nowrap",
          (@rotate && "max-h-36 [writing-mode:vertical-rl] rotate-180") || "max-w-24"
        ]}
        title={"#{@host.name} (#{@host.address}) — open in the diff viewer"}
      >
        {@host.name}
      </.link>
      <div class="tabular-nums text-xs opacity-70" title="Users with access">{@total}</div>
    </th>
    """
  end

  attr :user, :map, required: true
  attr :total, :integer, required: true

  defp user_header(assigns) do
    ~H"""
    <th class="sticky left-0 z-10 w-44 min-w-44 max-w-44 bg-base-100 font-medium">
      <.link
        patch={~p"/access?user_id=#{@user.id}"}
        class="link link-hover block truncate"
        title={"#{@user.username}#{if(@user.enabled, do: "", else: " (disabled)")} — list this user's access"}
      >
        {@user.username}
      </.link>
    </th>
    <td
      class="sticky left-44 z-10 w-12 min-w-12 bg-base-100 text-center tabular-nums text-xs opacity-80"
      title="Hosts with access"
    >
      {@total}
    </td>
    """
  end

  attr :user, :map, required: true
  attr :host, :map, required: true
  attr :count, :integer, required: true
  attr :login, :string, required: true
  attr :editable, :boolean, required: true
  attr :mode, :atom, required: true

  # all view: the number of logins with access; in view-only mode a click
  # explains why nothing changes (event "matrix-toggle" answers with a flash)
  defp matrix_cell(%{mode: :all} = assigns) do
    ~H"""
    <button
      id={"matrix-cell-#{@user.id}-#{@host.id}"}
      type="button"
      class={["badge badge-sm", (@count > 0 && "badge-info") || "badge-ghost opacity-40"]}
      phx-click="matrix-toggle"
      phx-value-user-id={@user.id}
      phx-value-host-id={@host.id}
      title={"#{@user.username} on #{@host.name}: #{@count} login(s) with access"}
    >
      {@count}
    </button>
    """
  end

  defp matrix_cell(assigns) do
    ~H"""
    <button
      id={"matrix-cell-#{@user.id}-#{@host.id}"}
      type="button"
      class={[
        "btn btn-square btn-xs border-0",
        (@count > 0 && "btn-success bg-success/20 text-success hover:bg-success/40") ||
          "btn-ghost text-base-content/25 hover:text-error"
      ]}
      phx-click="matrix-toggle"
      phx-value-user-id={@user.id}
      phx-value-host-id={@host.id}
      data-confirm={
        @count > 0 &&
          "Revoke #{@user.username} on #{@host.name} as #{@login}? The key lines leave the host at its next sync."
      }
      title={"#{@user.username} on #{@host.name}: " <>
        if(@count > 0, do: "has access, click to revoke", else: "no access, click to add")}
    >
      <.icon :if={@count > 0} name="hero-check" class="size-3.5" />
      <.icon :if={@count == 0} name="hero-x-mark" class="size-3.5" />
    </button>
    """
  end

  attr :rows, :integer, required: true
  attr :rows_total, :integer, required: true
  attr :cols, :integer, required: true
  attr :cols_total, :integer, required: true
  attr :total, :integer, required: true

  defp matrix_position(assigns) do
    ~H"""
    <div id="matrix-position" class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
      <span class="opacity-70">
        {@rows} of {@rows_total} users, {@cols} of {@cols_total} hosts, {@total} with access
      </span>
      <span
        :if={@rows < @rows_total and @rows >= AccessMatrix.rows_max()}
        id="matrix-rows-capped"
        class="text-xs opacity-70"
      >
        Showing the first {@rows} users: narrow them with "Search users".
      </span>
      <span
        :if={@cols < @cols_total and @cols >= AccessMatrix.cols_max()}
        id="matrix-cols-capped"
        class="text-xs opacity-70"
      >
        Showing the first {@cols} hosts: narrow them with "Filter hosts".
      </span>
      <.button
        :if={@rows < @rows_total and @rows < AccessMatrix.rows_max()}
        id="matrix-more-rows"
        phx-click="matrix-more"
        phx-value-axis="rows"
      >
        Show more users
      </.button>
      <.button
        :if={@cols < @cols_total and @cols < AccessMatrix.cols_max()}
        id="matrix-more-cols"
        phx-click="matrix-more"
        phx-value-axis="cols"
      >
        Show more hosts
      </.button>
    </div>
    """
  end

  attr :login, :string, required: true
  attr :editable, :boolean, required: true
  attr :read_only, :boolean, required: true
  attr :mode, :atom, required: true

  defp matrix_legend(assigns) do
    ~H"""
    <div id="matrix-legend" class="space-y-1 text-xs opacity-80">
      <p class="flex flex-wrap items-center gap-x-4 gap-y-1">
        <span :if={@mode == :login} class="inline-flex items-center gap-1">
          <.icon name="hero-check" class="size-3.5 text-success" /> has access as {@login}
        </span>
        <span :if={@mode == :login} class="inline-flex items-center gap-1">
          <.icon name="hero-x-mark" class="size-3.5" /> no access
        </span>
        <span :if={@mode == :all} class="inline-flex items-center gap-1">
          <span class="badge badge-info badge-xs">n</span> n logins with access
        </span>
        <span :if={@mode == :all} class="inline-flex items-center gap-1">
          <span class="badge badge-ghost badge-xs opacity-40">0</span> no access
        </span>
        <span>Totals count hosts per user and users per host.</span>
      </p>
      <p :if={@editable} id="matrix-mode">
        <strong>Editable.</strong>
        A click on a cell adds or revokes access as {@login} (revoking asks first; a host gets the change
        at its next sync). A click on a user lists their access; a click on a host opens its sync view.
      </p>
      <p :if={not @editable and @mode == :all and not @read_only} id="matrix-mode">
        <strong>View only.</strong>
        This view counts the logins of all accounts; a click on a cell changes nothing. Pick a login to edit.
      </p>
      <p :if={@read_only} id="matrix-mode">
        <strong>View only.</strong>
        Your account cannot change access; a click on a cell changes nothing.
      </p>
      <p>
        Up to {rotate_up_to()} visible hosts have rotated names; with more, narrow the columns with "Filter hosts".
      </p>
    </div>
    """
  end
end
