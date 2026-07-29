defmodule SsmWeb.DashboardLive do
  @moduledoc """
  Landing page after sign-in. Entity counts come with the domain contexts;
  this starts as the authenticated shell every other page hangs off.
  """

  use SsmWeb, :live_view

  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Dashboard")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <h1 class="text-xl font-semibold">Dashboard</h1>
      <p class="opacity-70">Signed in as {@current_user.username}.</p>
    </Layouts.app>
    """
  end
end
