defmodule SsmWeb.UsersLive do
  @moduledoc "Users page — managed key owners. Scaffold; full CRUD lands next."

  use SsmWeb, :live_view

  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Users")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:users}>
      <.header>Users</.header>
    </Layouts.app>
    """
  end
end
