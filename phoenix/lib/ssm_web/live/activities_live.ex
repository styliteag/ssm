defmodule SsmWeb.ActivitiesLive do
  @moduledoc "Activity log page. Scaffold; filtering lands next."

  use SsmWeb, :live_view

  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Activities")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:activities}>
      <.header>Activities</.header>
    </Layouts.app>
    """
  end
end
