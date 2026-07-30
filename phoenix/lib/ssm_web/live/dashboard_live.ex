defmodule SsmWeb.DashboardLive do
  @moduledoc """
  Landing page after sign-in: entity counts plus the most recent activity —
  parity with the React DashboardPage (stat cards + activity feed).
  """

  use SsmWeb, :live_view

  alias Ssm.{Activity, Authorizations, Hosts, Users}
  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Dashboard")
     |> assign(stats())
     |> assign(:version, to_string(Application.spec(:ssm, :vsn)))
     |> assign(:schema_version, schema_version())
     |> assign(:recent_activity, Activity.list(limit: 10))}
  end

  # Latest applied Ecto migration — the dashboard version pill's "db" part
  # (React showed the alembic revision there).
  defp schema_version do
    case Ecto.Migrator.migrated_versions(Ssm.Repo) do
      [] -> "none"
      versions -> versions |> Enum.max() |> to_string()
    end
  end

  defp stats do
    %{
      host_count: Hosts.count_hosts(),
      disabled_host_count: Hosts.count_disabled_hosts(),
      user_count: Users.count_users(),
      key_count: Users.count_keys(),
      authorization_count: Authorizations.count_authorizations()
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:dashboard}>
      <.header>
        Dashboard
        <:subtitle>Signed in as {@current_user.username}</:subtitle>
        <:actions>
          <span
            id="version-pill"
            class="badge badge-ghost font-mono text-xs"
            title={"App v#{@version} · schema revision #{@schema_version}"}
          >
            v{@version} · db {@schema_version}
          </span>
        </:actions>
      </.header>

      <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <.stat_card
          id="stat-hosts"
          navigate={~p"/hosts"}
          icon="hero-server"
          title="Hosts"
          value={@host_count}
          detail={"#{@disabled_host_count} disabled"}
        />
        <.stat_card
          id="stat-users"
          navigate={~p"/users"}
          icon="hero-users"
          title="Users"
          value={@user_count}
        />
        <.stat_card
          id="stat-keys"
          navigate={~p"/keys"}
          icon="hero-key"
          title="Keys"
          value={@key_count}
        />
        <.stat_card
          id="stat-authorizations"
          navigate={~p"/authorizations"}
          icon="hero-shield-check"
          title="Authorizations"
          value={@authorization_count}
        />
      </div>

      <section class="card bg-base-200">
        <div class="card-body">
          <h2 class="card-title text-base">Recent activity</h2>

          <p :if={@recent_activity == []} class="text-sm opacity-60">No activity yet.</p>

          <ul id="recent-activity" class="space-y-1">
            <li
              :for={entry <- @recent_activity}
              class="flex items-center gap-3 rounded px-2 py-1.5 text-sm"
            >
              <.activity_badge type={entry.activity_type} />
              <span class="font-medium">{entry.action}</span>
              <span class="opacity-75">{entry.target}</span>
              <span class="ml-auto flex-none text-xs opacity-60">
                {format_timestamp(entry.timestamp)} · {entry.actor_username}
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

  defp stat_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      id={@id}
      class="stat rounded-box bg-base-200 transition hover:bg-base-300"
    >
      <div class="stat-figure text-primary">
        <.icon name={@icon} class="size-6" />
      </div>
      <div class="stat-title">{@title}</div>
      <div class="stat-value text-3xl">{@value}</div>
      <div :if={@detail} class="stat-desc">{@detail}</div>
    </.link>
    """
  end

  attr :type, :string, required: true

  defp activity_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm flex-none",
      activity_badge_class(@type)
    ]}>
      {@type}
    </span>
    """
  end

  defp activity_badge_class("host"), do: "badge-info"
  defp activity_badge_class("user"), do: "badge-success"
  defp activity_badge_class("key"), do: "badge-warning"
  defp activity_badge_class("auth"), do: "badge-secondary"
  defp activity_badge_class(_), do: "badge-ghost"

  defp format_timestamp(nil), do: ""

  defp format_timestamp(unix) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%d %H:%M")
  end
end
