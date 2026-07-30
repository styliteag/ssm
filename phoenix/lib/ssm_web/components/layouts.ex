defmodule SsmWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SsmWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_user, :map,
    default: nil,
    doc: "the logged-in web user (%{username: ...}) or nil"

  attr :active, :atom,
    default: nil,
    doc: "which sidebar entry to highlight (:dashboard, :hosts, ...)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <aside
        :if={@current_user}
        class="hidden w-56 flex-none flex-col border-r border-base-300 bg-base-200 sm:flex"
      >
        <a href="/" class="flex items-center gap-2 px-4 py-4">
          <.icon name="hero-key" class="size-5 text-primary" />
          <span class="font-semibold">SSM</span>
          <span class="text-xs opacity-60">v{Application.spec(:ssm, :vsn)}</span>
        </a>

        <ul class="menu w-full flex-1 gap-1 px-2" id="sidebar-nav">
          <li :for={{label, path, icon, key} <- nav_items()}>
            <.link
              navigate={path}
              class={["flex items-center gap-2", @active == key && "menu-active"]}
              aria-current={@active == key && "page"}
            >
              <.icon name={icon} class="size-4" />
              {label}
            </.link>
          </li>
        </ul>
      </aside>

      <div class="flex min-w-0 flex-1 flex-col">
        <header class="navbar border-b border-base-300 bg-base-100 px-4 sm:px-6">
          <div class="flex-1">
            <a :if={!@current_user} href="/" class="flex w-fit items-center gap-2">
              <.icon name="hero-key" class="size-5 text-primary" />
              <span class="font-semibold">SSM</span>
            </a>
          </div>
          <div class="flex-none">
            <ul class="flex items-center gap-3 px-1">
              <li><.theme_toggle /></li>
              <li :if={@current_user} class="text-sm opacity-75">{@current_user.username}</li>
              <li :if={@current_user}>
                <.link href={~p"/sign-out"} method="delete" class="btn btn-ghost btn-sm">
                  Sign out
                </.link>
              </li>
            </ul>
          </div>
        </header>

        <main class="flex-1 px-4 py-6 sm:px-6 lg:px-8">
          <div class="mx-auto max-w-7xl space-y-4">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp nav_items do
    [
      {"Dashboard", ~p"/dashboard", "hero-squares-2x2", :dashboard},
      {"Hosts", ~p"/hosts", "hero-server", :hosts},
      {"Users", ~p"/users", "hero-users", :users},
      {"SSH Keys", ~p"/keys", "hero-key", :keys},
      {"Authorizations", ~p"/authorizations", "hero-shield-check", :authorizations},
      {"Diff Viewer", ~p"/diff", "hero-arrows-right-left", :diff},
      {"Activities", ~p"/activities", "hero-clock", :activities}
    ]
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
