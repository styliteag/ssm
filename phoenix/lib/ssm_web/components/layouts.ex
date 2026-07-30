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
          <div class="flex flex-1 items-center gap-2">
            <details :if={@current_user} data-popover class="relative sm:hidden">
              <summary class="btn btn-ghost btn-sm list-none" aria-label="Navigation">
                <.icon name="hero-bars-3" class="size-5" />
              </summary>
              <ul class="menu absolute left-0 z-30 mt-2 w-52 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg">
                <li :for={{label, path, icon, _key} <- nav_items()}>
                  <.link navigate={path} class="flex items-center gap-2">
                    <.icon name={icon} class="size-4" />
                    {label}
                  </.link>
                </li>
              </ul>
            </details>
            <a :if={!@current_user} href="/" class="flex w-fit items-center gap-2">
              <.icon name="hero-key" class="size-5 text-primary" />
              <span class="font-semibold">SSM</span>
            </a>
          </div>
          <div class="flex-none">
            <ul class="flex items-center gap-3 px-1">
              <li><.theme_switcher /></li>
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
  Design × mode theme switcher (SsmWeb.Design). Plain POST forms — no JS
  needed to switch; app.js only marks the active buttons client-side from
  the html element's data-theme (LiveViews don't carry the design assigns,
  and the DOM attribute is the single truth anyway).
  """
  def theme_switcher(assigns) do
    ~H"""
    <details data-popover class="relative">
      <summary class="btn btn-ghost btn-sm list-none" title="Theme">
        <.icon name="hero-swatch" class="size-4" />
        <span class="hidden sm:inline">Theme</span>
      </summary>
      <div class="absolute right-0 z-30 mt-2 w-60 rounded-box border border-base-300 bg-base-100 p-3 shadow-lg">
        <div class="mb-1 text-xs font-semibold uppercase tracking-wide opacity-60">Design</div>
        <div class="grid grid-cols-2 gap-1">
          <form :for={design <- SsmWeb.Design.all()} method="post" action={~p"/design"}>
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <input type="hidden" name="design" value={design.id} />
            <button data-theme-design={design.id} class="btn btn-ghost btn-sm w-full justify-start">
              {design.name}
            </button>
          </form>
        </div>
        <div class="mt-3 mb-1 text-xs font-semibold uppercase tracking-wide opacity-60">Mode</div>
        <div class="grid grid-cols-3 gap-1">
          <form
            :for={{label, value} <- [{"Auto", ""}, {"Light", "light"}, {"Dark", "dark"}]}
            method="post"
            action={~p"/design/mode"}
          >
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <input type="hidden" name="mode" value={value} />
            <button data-theme-mode={value} class="btn btn-ghost btn-sm w-full">
              {label}
            </button>
          </form>
        </div>
      </div>
    </details>
    """
  end
end
