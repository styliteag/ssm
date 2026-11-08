defmodule SsmWeb.ReadOnly do
  @moduledoc """
  The one central write guard for `viewer` operators (OIDC role `viewer`).

  `UserAuth.on_mount(:live_user_required, ...)` attaches `guard/3` as a
  `handle_event` hook to every authenticated LiveView. A viewer may send
  only the events in `@read_events` (sorting, filtering, searching, view
  switches, opening a key, opening a key); every other event is
  refused before the LiveView's own `handle_event` runs. An allow-list, so
  a new write event is blocked by default. The same list hides the write
  controls in the page (`hide_css/0`), so a viewer does not see buttons
  that would only answer "read-only". Diff re-checks and refreshes are
  not allowed: they open SSH connections to the hosts.

  Browser controllers behind authentication are GET-only (export); the
  `/api/v2` bearer API is a separate credential and not affected.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  @read_events ~w(
    filter load_more sort view-mode list-search search type-filter view
    diff-view diff-search diff-filter select deselect cancel
    unknown-key-cancel
  )

  # write controls that also show state: shown, but not clickable
  @display_only ~w(matrix-toggle)

  @doc """
  CSS that hides every write control for viewers (`Layouts.app` emits it
  inside `[data-read-only]`): elements whose `phx-click` / `phx-submit`
  names an event outside `@read_events`. Generated from the same allow-list
  as the server guard, so a new write button is hidden by default. JS
  command bindings (`[[…]]`, e.g. closing a flash) stay; the guard still
  refuses anything they push. Cosmetic only — `guard/3` is the control.
  """
  @spec hide_css() :: String.t()
  def hide_css do
    allowed = @read_events ++ @display_only

    hidden =
      for attr <- ~w(phx-click phx-submit) do
        nots = Enum.map_join(allowed, "", &~s|:not([#{attr}="#{&1}"])|)
        ~s|[data-read-only] [#{attr}]:not([#{attr}^="["])#{nots}|
      end

    display_only = Enum.map_join(@display_only, ",", &~s|[data-read-only] [phx-click="#{&1}"]|)

    Enum.join(hidden, ",") <>
      "{display:none !important}" <>
      display_only <> "{pointer-events:none;cursor:default}"
  end

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
