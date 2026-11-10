defmodule SsmWeb.DashboardLive do
  @moduledoc """
  Landing page after sign-in: what needs attention (`SsmWeb.Attention`),
  entity counts and the most recent activity.
  """

  use SsmWeb, :live_view

  alias Ssm.{Activity, Authorizations, Hosts, HostStatus, Scope, Users}
  alias Ssm.Diffs.{HostChecks, Revocations, StatusCache}
  alias SsmWeb.Attention
  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    scope = Scope.of(user)

    {:ok,
     socket
     |> assign(page_title: "Dashboard")
     |> assign(stats(scope))
     |> assign(:attention, attention(scope))
     |> assign(:version, to_string(Application.spec(:ssm, :vsn)))
     |> assign(:schema_version, schema_version())
     |> assign(:system, false)}
  end

  # ?system=1 shows machine actors (Mission Control's service token) too
  @impl true
  def handle_params(params, _uri, socket) do
    user = socket.assigns.current_user
    system = params["system"] == "1"

    entries =
      Activity.list(Scope.of(user),
        actor: user.actor,
        limit: 10,
        exclude_system: not system
      )

    {:noreply, assign(socket, system: system, recent_activity: entries)}
  end

  # What a stat card flags: the attention items that belong to hosts
  defp host_actions(attention) do
    for %{id: id} = item <- attention, id in ["pending", "unreachable"] do
      case id do
        "pending" -> %{text: "#{item.count} pending sync", path: ~p"/hosts?filter=pending"}
        "unreachable" -> %{text: "#{item.count} unreachable", path: ~p"/hosts?filter=offline"}
      end
    end
  end

  # Latest applied Ecto migration — the dashboard version pill's "db" part
  # (React showed the alembic revision there).
  defp schema_version do
    case Ecto.Migrator.migrated_versions(Ssm.Repo) do
      [] -> "none"
      versions -> versions |> Enum.max() |> to_string()
    end
  end

  defp attention(scope) do
    hosts = Hosts.list_hosts(scope)
    cached = StatusCache.all()
    stored = HostChecks.stored(scope)
    statuses = Map.new(hosts, &{&1.id, HostStatus.derive(&1, cached[&1.id], stored[&1.id])})
    Attention.items(hosts, statuses, Revocations.pending(scope))
  end

  # Host and authorization counts follow the user's scope (ADR-0012); the
  # SSH user catalog (users, keys) is readable in full.
  defp stats(scope) do
    %{
      host_count: Hosts.count_hosts(scope),
      disabled_host_count: Hosts.count_disabled_hosts(scope),
      user_count: Users.count_users(),
      key_count: Users.count_keys(),
      authorization_count: Authorizations.count_authorizations(scope)
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      pending_sync={@pending_sync}
      active={:dashboard}
    >
      <.header>
        Dashboard
        <:subtitle>What needs attention, and the latest changes</:subtitle>
        <:actions>
          <span
            id="version-pill"
            class="badge badge-ghost font-mono text-xs"
            title={"App v#{@version} · schema revision #{@schema_version}"}
          >
            v{@version} · schema {@schema_version}
          </span>
        </:actions>
      </.header>

      <section id="attention" class="card bg-base-200">
        <div class="card-body gap-2">
          <h2 class="card-title text-base">Needs attention</h2>
          <p :if={@attention == []} id="attention-none" class="text-sm opacity-70">
            <.icon name="hero-check-circle" class="size-4 text-success" />
            Nothing needs attention: every checked host is in sync.
          </p>
          <ul class="space-y-1">
            <li :for={item <- @attention} id={"attention-#{item.id}"}>
              <.link
                navigate={item.path}
                class="flex items-center gap-2 rounded px-2 py-1 hover:bg-base-300"
              >
                <.icon
                  name={
                    if item.tone == :error,
                      do: "hero-exclamation-triangle",
                      else: "hero-exclamation-circle"
                  }
                  class={["size-4", if(item.tone == :error, do: "text-error", else: "text-warning")]}
                />
                <span class="font-semibold">{item.title}:</span>
                <span>{item.count} {if item.count == 1, do: "host", else: "hosts"}</span>
                <span class="hidden opacity-60 sm:inline">— {item.hint}</span>
                <.icon name="hero-chevron-right" class="ml-auto size-4 opacity-50" />
              </.link>
            </li>
          </ul>
        </div>
      </section>

      <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <.stat_card
          id="stat-hosts"
          navigate={~p"/hosts"}
          icon="hero-server"
          title="Hosts"
          value={@host_count}
          detail={"#{@disabled_host_count} disabled"}
          actions={host_actions(@attention)}
        />
        <.stat_card
          id="stat-users"
          navigate={~p"/users"}
          icon="hero-users"
          title="SSH users"
          value={@user_count}
        />
        <.stat_card
          id="stat-keys"
          navigate={~p"/keys"}
          icon="hero-key"
          title="SSH keys"
          value={@key_count}
        />
        <.stat_card
          id="stat-authorizations"
          navigate={~p"/authorizations"}
          icon="hero-shield-check"
          title="Access entries"
          value={@authorization_count}
        />
      </div>

      <section class="card bg-base-200">
        <div class="card-body">
          <div class="flex items-center justify-between gap-2">
            <h2 class="card-title text-base">Recent activity</h2>
            <.link
              id="toggle-system-activity"
              patch={if @system, do: ~p"/dashboard", else: ~p"/dashboard?system=1"}
              class="link link-hover text-xs opacity-70"
            >
              {if @system, do: "Hide system activity", else: "Show system activity"}
            </.link>
          </div>

          <p :if={@recent_activity == []} class="text-sm opacity-60">No activity yet.</p>

          <ul id="recent-activity" class="space-y-1">
            <li
              :for={entry <- @recent_activity}
              class="flex items-center gap-3 rounded px-2 py-1.5 text-sm"
            >
              <.activity_badge type={entry.activity_type} />
              <span class="font-medium" title={entry.action}>
                {SsmWeb.ActivityText.action(entry.action)}
              </span>
              <span class="opacity-75">{entry.target}</span>
              <span class="ml-auto flex-none text-xs opacity-60">
                <.local_time at={entry.timestamp} /> · {entry.actor_username}
              </span>
            </li>
          </ul>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :value, :integer, required: true
  attr :detail, :string, default: nil
  attr :actions, :list, default: []

  # The card is a div: its main link and the action links must not nest.
  defp stat_card(assigns) do
    ~H"""
    <div id={@id} class="stat rounded-box bg-base-200 transition hover:bg-base-300">
      <div class="stat-figure text-primary">
        <.icon name={@icon} class="size-6" />
      </div>
      <.link navigate={@navigate} class="contents">
        <div class="stat-title">{@title}</div>
        <div class="stat-value text-3xl">{@value}</div>
      </.link>
      <div :if={@detail} class="stat-desc">{@detail}</div>
      <div :if={@actions != []} class="stat-desc flex flex-wrap gap-x-3">
        <.link
          :for={action <- @actions}
          navigate={action.path}
          class="link font-medium text-base-content underline decoration-warning decoration-2 underline-offset-2"
        >
          {action.text}
        </.link>
      </div>
    </div>
    """
  end

  attr :type, :string, required: true

  defp activity_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm flex-none",
      SsmWeb.ActivityText.type_class(@type)
    ]}>
      {@type}
    </span>
    """
  end
end
