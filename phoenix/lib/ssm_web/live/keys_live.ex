defmodule SsmWeb.KeysLive do
  @moduledoc "SSH keys page. Scaffold; full CRUD lands next."

  use SsmWeb, :live_view

  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "SSH Keys")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:keys}>
      <.header>SSH Keys</.header>
    </Layouts.app>
    """
  end
end
