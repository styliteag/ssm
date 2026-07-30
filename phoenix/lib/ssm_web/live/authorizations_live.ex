defmodule SsmWeb.AuthorizationsLive do
  @moduledoc "Authorizations page — user↔host grants. Scaffold; full CRUD lands next."

  use SsmWeb, :live_view

  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Authorizations")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:authorizations}>
      <.header>Authorizations</.header>
    </Layouts.app>
    """
  end
end
