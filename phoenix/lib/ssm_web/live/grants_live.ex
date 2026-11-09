defmodule SsmWeb.GrantsLive do
  @moduledoc """
  Grants page (ADR-0012 §5): SSH access for an SSH user per customer or host
  group. Two entry points share it:

    * the customer/group view — pick a customer or group (`?customer_id=` /
      `?group_id=`) to see and manage its grants;
    * the SSH user's grants — `?user_id=` (linked from the Users page).

  Create and delete go through `Ssm.Grants` with the current user: admins
  any target, scoped operators only targets in their scope (the grant keeps
  their scope), viewers none (also refused by `SsmWeb.ReadOnly`). A scoped
  operator sees only grants that stay inside its scope. Grant-made
  authorization rows are read-only on the Authorizations page.
  """

  use SsmWeb, :live_view

  alias Ssm.{Grants, Scope, Users}
  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Grants", form: nil, target: nil, sort: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      user_id: parse_id(params["user_id"]),
      customer_id: parse_id(params["customer_id"]),
      group_id: parse_id(params["group_id"])
    }

    socket = assign(socket, :q, params["q"])

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:targets, Grants.targets(scope(socket)))
     |> assign(:users, Users.list_users())
     |> assign(:writer, Grants.writer?(socket.assigns.current_user))
     |> reload()}
  end

  defp scope(socket), do: Scope.of(socket.assigns.current_user)

  defp target_path(%{customer_id: id}) when is_integer(id), do: ~p"/grants?customer_id=#{id}"
  defp target_path(%{group_id: id}) when is_integer(id), do: ~p"/grants?group_id=#{id}"
  defp target_path(_grant), do: ~p"/grants"

  defp parse_id(nil), do: nil

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp reload(socket) do
    %{user_id: user_id, customer_id: customer_id, group_id: group_id} = socket.assigns.filters

    grants =
      socket
      |> scope()
      |> Grants.list_grants(ssh_user_id: user_id, customer_id: customer_id, group_id: group_id)
      |> Enum.filter(fn g ->
        matches?(socket.assigns[:q], [
          g.ssh_user.username,
          Grants.target_label(g),
          g.login,
          g.comment,
          g.created_by
        ])
      end)
      |> SsmWeb.TableSort.sort(socket.assigns.sort, sorters())

    assign(socket,
      grants: grants,
      limits: Grants.limit_labels(scope(socket), grants),
      heading: heading(socket.assigns)
    )
  end

  defp sorters do
    %{
      "user" => &SsmWeb.TableSort.string(&1.ssh_user.username),
      "target" => &SsmWeb.TableSort.string(Grants.target_label(&1)),
      "login" => &SsmWeb.TableSort.string(&1.login)
    }
  end

  defp heading(%{filters: %{user_id: id}, users: users}) when is_integer(id) do
    case Enum.find(users, &(&1.id == id)) do
      nil -> "Grants"
      user -> "Grants of #{user.username}"
    end
  end

  defp heading(%{filters: %{customer_id: id}, targets: t}) when is_integer(id),
    do: named("Grants on customer", Enum.find(t.customers, &(&1.id == id)))

  defp heading(%{filters: %{group_id: id}, targets: t}) when is_integer(id),
    do: named("Grants on group", Enum.find(t.groups, &(&1.id == id)))

  defp heading(_assigns), do: "Grants"

  defp named(_prefix, nil), do: "Grants"
  defp named(prefix, item), do: "#{prefix} #{item.name}"

  ## Events

  @impl true
  def handle_event("search", params, socket) do
    %{user_id: u, customer_id: c, group_id: g} = socket.assigns.filters

    query =
      %{"user_id" => u, "customer_id" => c, "group_id" => g, "q" => params["q"]}
      |> Map.new(fn {k, v} -> {k, v && to_string(v)} end)
      |> query_params(~w(user_id customer_id group_id q))

    {:noreply, push_patch(socket, to: ~p"/grants?#{query}")}
  end

  def handle_event("sort", %{"key" => key}, socket) do
    sort = SsmWeb.TableSort.toggle(socket.assigns.sort, key)
    {:noreply, socket |> assign(:sort, sort) |> reload()}
  end

  def handle_event("new", _params, socket) do
    %{user_id: user_id} = filters = socket.assigns.filters
    attrs = if user_id, do: %{"ssh_user_id" => user_id}, else: %{}

    {:noreply,
     assign(socket,
       form: to_form(Grants.change_grant(attrs), as: "grant"),
       target: target_of(filters)
     )}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, form: nil)}

  def handle_event("validate", %{"grant" => params}, socket) do
    changeset = params |> with_target() |> Grants.change_grant() |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(changeset, as: "grant"), target: params["target"])}
  end

  def handle_event("save", %{"grant" => params}, socket) do
    case Grants.create_grant(socket.assigns.current_user, with_target(params)) do
      {:ok, grant} ->
        {:noreply,
         socket
         |> assign(form: nil)
         |> put_flash(:info, "Grant for #{grant.ssh_user.username} created.")
         |> reload()}

      {:error, %Ecto.Changeset{} = changeset} ->
        form = changeset |> Map.put(:action, :insert) |> to_form(as: "grant")
        {:noreply, assign(socket, form: form, target: params["target"])}

      {:error, reason} ->
        {:noreply, socket |> assign(form: nil) |> put_flash(:error, refusal(reason))}
    end
  end

  def handle_event("delete-grant", %{"id" => id}, socket) do
    with %Grants.Grant{} = grant <- Grants.get_grant(scope(socket), parse_id(id)),
         {:ok, _} <- Grants.delete_grant(socket.assigns.current_user, grant) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Grant deleted. Removed access stays on the hosts until the next sync."
       )
       |> reload()}
    else
      nil -> {:noreply, put_flash(socket, :error, "Grant not found.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  defp refusal(:forbidden), do: "Your account cannot change grants."
  defp refusal(:out_of_scope), do: "That customer or group is outside your scope."
  defp refusal(:not_found), do: "Grant not found."
  defp refusal(_other), do: "The grant could not be saved."

  defp target_of(%{customer_id: id}) when is_integer(id), do: "customer:#{id}"
  defp target_of(%{group_id: id}) when is_integer(id), do: "group:#{id}"
  defp target_of(_filters), do: nil

  # "customer:<id>" / "group:<id>" from the form's target select
  defp with_target(params) do
    base = Map.take(params, ~w(ssh_user_id login comment))

    case String.split(params["target"] || "", ":", parts: 2) do
      ["customer", id] -> Map.put(base, "customer_id", id)
      ["group", id] -> Map.put(base, "group_id", id)
      _ -> base
    end
  end

  defp target_options(targets) do
    [
      {"Customers", Enum.map(targets.customers, &{&1.name, "customer:#{&1.id}"})},
      {"Host groups", Enum.map(targets.groups, &{&1.name, "group:#{&1.id}"})}
    ]
  end

  defp target_errors(form) do
    for {field, error} <- form.errors,
        field in [:customer_id, :group_id],
        do: translate_error(error)
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      pending_sync={@pending_sync}
      active={:grants}
    >
      <.header>
        {@heading}
        <:subtitle>
          SSH access per customer or host group. Every host of the target gets an
          authorization; removed access leaves a host at the next sync.
        </:subtitle>
        <:actions>
          <.button :if={@writer} id="new-grant" variant="primary" phx-click="new">
            <.icon name="hero-plus" class="size-4" /> New grant
          </.button>
        </:actions>
      </.header>

      <nav id="grant-targets" class="flex flex-wrap items-center gap-1 text-sm">
        <.link
          patch={~p"/grants"}
          class={[
            "badge",
            (@filters == %{user_id: nil, customer_id: nil, group_id: nil} && "badge-primary") ||
              "badge-ghost"
          ]}
        >
          All
        </.link>
        <span :if={@targets.customers != []} class="ml-2 opacity-60">Customers:</span>
        <.link
          :for={c <- @targets.customers}
          id={"target-customer-#{c.id}"}
          patch={~p"/grants?customer_id=#{c.id}"}
          class={["badge", (@filters.customer_id == c.id && "badge-primary") || "badge-ghost"]}
        >
          {c.name}
        </.link>
        <span :if={@targets.groups != []} class="ml-2 opacity-60">Groups:</span>
        <.link
          :for={g <- @targets.groups}
          id={"target-group-#{g.id}"}
          patch={~p"/grants?group_id=#{g.id}"}
          class={["badge", (@filters.group_id == g.id && "badge-primary") || "badge-ghost"]}
        >
          {g.name}
        </.link>
      </nav>

      <.list_search id="grants-search" q={@q} placeholder="Search user, target, login, comment" />

      <p :if={@grants == []} id="no-grants" class="text-sm opacity-60">No grants here.</p>

      <div :if={@grants != []} class="overflow-x-auto">
        <.table id="grants" rows={@grants} sort={@sort} row_id={&"grants-#{&1.id}"}>
          <:col :let={grant} label="SSH user" sort="user">
            <.link patch={~p"/grants?user_id=#{grant.ssh_user_id}"} class="link link-hover">
              {grant.ssh_user.username}
            </.link>
            <.link
              navigate={user_path(grant.ssh_user_id)}
              class="ml-1 opacity-60 hover:opacity-100"
              title="Open the SSH user"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3" />
            </.link>
          </:col>
          <:col :let={grant} label="Target" sort="target">
            <.link patch={target_path(grant)} class="link link-hover">
              {Grants.target_label(grant)}
            </.link>
            <p :if={@limits[grant.id]} class="text-xs opacity-60">{@limits[grant.id]}</p>
          </:col>
          <:col :let={grant} label="Login" sort="login">
            <span class="font-mono text-sm">{grant.login}</span>
          </:col>
          <:col :let={grant} label="Comment">{grant.comment || "—"}</:col>
          <:col :let={grant} label="Created by">
            <span class="text-xs">{grant.created_by}</span>
          </:col>
          <:action :let={grant}>
            <.link
              navigate={~p"/authorizations?user_id=#{grant.ssh_user_id}"}
              class="btn btn-ghost btn-xs"
              title="Authorizations of this user"
            >
              <.icon name="hero-shield-check" class="size-4" />
            </.link>
            <button
              :if={@writer}
              id={"delete-grant-#{grant.id}"}
              class="btn btn-ghost btn-xs text-error"
              phx-click="delete-grant"
              phx-value-id={grant.id}
              data-confirm={"Delete the grant of #{grant.ssh_user.username} on #{Grants.target_label(grant)} (login #{grant.login})? Its access is removed from every host of the target at the next sync."}
              title="Delete grant"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </:action>
        </.table>
      </div>

      <.modal :if={@form} id="grant-modal" on_cancel={JS.push("cancel")}>
        <:title>New grant</:title>

        <.form for={@form} id="grant-form" phx-change="validate" phx-submit="save" class="space-y-2">
          <.input
            field={@form[:ssh_user_id]}
            type="select"
            label="SSH user"
            prompt="Select an SSH user"
            options={Enum.map(@users, &{&1.username, &1.id})}
            required
          />
          <.input
            id="grant_target"
            name="grant[target]"
            type="select"
            label="Customer or host group"
            prompt="Select a target"
            options={target_options(@targets)}
            value={@target}
            errors={target_errors(@form)}
            required
          />
          <.input field={@form[:login]} type="text" label="Login on the hosts" required />
          <.input field={@form[:comment]} type="text" label="Comment" />

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
            <button type="submit" class="btn btn-primary">Create grant</button>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
