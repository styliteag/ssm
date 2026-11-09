defmodule SsmWeb.UserLive do
  @moduledoc """
  One SSH user (`/users/:id`): its keys (short, copyable, linked to the keys
  page), its access per host and login (host → diff, grant rows → the
  user's grants) with the host's last key check, and its grants. Read-only.
  Host data goes through the viewer's scope (ADR-0012): access on a host out
  of scope is not shown; the user and its keys are catalog data.
  """
  use SsmWeb, :live_view

  alias Ssm.{Authorizations, Diffs, Grants, Users}
  alias Ssm.Diffs.{HostCheck, HostChecks}

  @impl true
  def mount(%{"id" => raw}, _session, socket) do
    with {id, ""} <- Integer.parse(raw),
         %Users.User{} = user <- Users.get_user(id) do
      {:ok, load(socket, user)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "SSH user not found.")
         |> push_navigate(to: ~p"/users")}
    end
  end

  defp load(socket, user) do
    scope = Ssm.Scope.of(socket.assigns.current_user)
    auths = Authorizations.list_authorizations(scope, user_id: user.id)
    checks = HostChecks.stored(scope)

    assign(socket,
      page_title: user.username,
      user: user,
      keys: Users.list_keys(user_id: user.id),
      auths: Enum.sort_by(auths, &{&1.host.name, &1.login}),
      checks: checks,
      grants: Grants.list_grants(scope, ssh_user_id: user.id)
    )
  end

  defp key_line(key), do: Diffs.format_key_line(key.key_type, key.key_base64, key.name)

  defp check_label(nil), do: {"unchecked", "badge-ghost"}
  defp check_label(%HostCheck{state: "synced"}), do: {"synced", "badge-success"}
  defp check_label(%HostCheck{state: "drift"}), do: {"needs sync", "badge-warning"}
  defp check_label(%HostCheck{}), do: {"error", "badge-error"}

  defp grant_target(%{customer: %{name: name}}), do: "customer " <> name
  defp grant_target(%{group: %{name: name}}), do: "group " <> name
  defp grant_target(_grant), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      pending_sync={@pending_sync}
      active={:users}
    >
      <div class="space-y-6">
        <div class="flex flex-wrap items-center gap-3">
          <.link navigate={~p"/users"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> SSH users
          </.link>
          <h1 id="user-name" class="text-2xl font-semibold">{@user.username}</h1>
          <span :if={!@user.enabled} class="badge badge-error">disabled</span>
          <span :if={@user.comment} class="text-sm opacity-60">{@user.comment}</span>
          <div class="ml-auto flex gap-2">
            <.link id="user-keys-link" navigate={keys_path(@user.id)} class="btn btn-sm">
              <.icon name="hero-key" class="size-4" /> Keys
            </.link>
            <.link id="user-grants-link" navigate={grants_path(@user.id)} class="btn btn-sm">
              <.icon name="hero-squares-2x2" class="size-4" /> Grants
            </.link>
          </div>
        </div>

        <section class="space-y-2">
          <h2 class="font-semibold">Keys ({length(@keys)})</h2>
          <p :if={@keys == []} class="text-sm opacity-60">No keys.</p>
          <ul id="user-keys" class="space-y-1">
            <li
              :for={key <- @keys}
              id={"user-key-#{key.id}"}
              class="flex items-center gap-2 rounded bg-base-200 px-2 py-1"
            >
              <span class="badge badge-ghost badge-sm">{key.key_type}</span>
              <code class="min-w-0 truncate font-mono text-xs" title={key_line(key)}>
                {short_base64(key.key_base64)}
              </code>
              <span class="text-sm">{key.name}</span>
              <.copy_text
                id={"copy-user-key-#{key.id}"}
                text={key_line(key)}
                class="ml-auto"
                title="Copy the full key line"
              />
            </li>
          </ul>
        </section>

        <section class="space-y-2">
          <h2 class="font-semibold">Access ({length(@auths)})</h2>
          <p :if={@auths == []} class="text-sm opacity-60">No access on hosts you can see.</p>
          <table :if={@auths != []} id="user-access" class="table table-sm">
            <thead>
              <tr>
                <th>Host</th>
                <th>Login</th>
                <th>Options</th>
                <th>Source</th>
                <th>Host check</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={auth <- @auths} id={"user-auth-#{auth.id}"}>
                <td><.host_link id={auth.host_id} name={auth.host.name} /></td>
                <td>
                  <.link
                    navigate={host_path(auth.host_id)}
                    class="link link-hover font-mono text-xs"
                  >
                    {auth.login}
                  </.link>
                </td>
                <td class="max-w-xs truncate font-mono text-xs" title={auth.options}>
                  {auth.options}
                </td>
                <td>
                  <.link
                    :if={auth.grant_id}
                    navigate={grants_path(@user.id)}
                    class="badge badge-ghost badge-sm"
                  >
                    grant
                  </.link>
                  <span :if={!auth.grant_id} class="text-xs opacity-60">manual</span>
                </td>
                <td>
                  <% {label, class} = check_label(@checks[auth.host_id]) %>
                  <.link navigate={host_path(auth.host_id)} class={["badge badge-sm", class]}>
                    {label}
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section class="space-y-2">
          <h2 class="font-semibold">Grants ({length(@grants)})</h2>
          <p :if={@grants == []} class="text-sm opacity-60">No grants you can see.</p>
          <ul id="user-grants" class="space-y-1">
            <li :for={grant <- @grants} id={"user-grant-#{grant.id}"} class="text-sm">
              <.link navigate={grants_path(@user.id)} class="link link-hover">
                {grant_target(grant)}
              </.link>
              <span class="font-mono text-xs opacity-70">→ {grant.login}</span>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
