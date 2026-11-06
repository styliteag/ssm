defmodule SsmWeb.ReadOnly do
  @moduledoc """
  The one central write guard for `viewer` operators (OIDC role `viewer`).

  `UserAuth.on_mount(:live_user_required, ...)` attaches `guard/3` as a
  `handle_event` hook to every authenticated LiveView. A viewer may send
  only the events in `@read_events` (sorting, filtering, searching, view
  switches, opening a key, opening a key); every other event is
  refused before the LiveView's own `handle_event` runs. An allow-list, so
  a new write event is blocked by default. Diff re-checks and refreshes are
  not allowed: they open SSH connections to the hosts.

  Browser controllers behind authentication are GET-only (export); the
  `/api/v2` bearer API is a separate credential and not affected.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  @read_events ~w(
    filter load_more sort view-mode list-search search type-filter view
    diff-view diff-search select deselect cancel
    unknown-key-cancel
  )

  @doc "Can a user with `role` send this LiveView event?"
  @spec allowed?(String.t() | nil, String.t()) :: boolean()
  def allowed?("viewer", event), do: event in @read_events
  def allowed?(_role, _event), do: true

  @doc "Attach the guard for viewers; other roles pass through untouched."
  def attach(%{assigns: %{current_user: %{role: "viewer"}}} = socket),
    do: attach_hook(socket, :read_only_guard, :handle_event, &guard/3)

  def attach(socket), do: socket

  @doc false
  def guard(event, _params, socket) do
    if allowed?("viewer", event) do
      {:cont, socket}
    else
      {:halt, put_flash(socket, :error, "Your account is read-only.")}
    end
  end
end
