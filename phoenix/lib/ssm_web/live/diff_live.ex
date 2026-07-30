defmodule SsmWeb.DiffLive do
  @moduledoc "Diff viewer — expected vs actual authorized_keys. Scaffold; full page lands next."

  use SsmWeb, :live_view

  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Diff Viewer")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:diff}>
      <.header>Diff Viewer</.header>
    </Layouts.app>
    """
  end
end
