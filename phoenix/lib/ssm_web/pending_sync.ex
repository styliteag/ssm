defmodule SsmWeb.PendingSync do
  @moduledoc """
  Keeps `@pending_sync` — how many hosts in the user's scope wait for a sync
  after a change that took access away (`Ssm.Diffs.Revocations`) — current
  on every signed-in LiveView, for the header badge in `SsmWeb.Layouts.app/1`.

  Recounted after each event and async result of the page (a write on this
  page marks or clears hosts), and every 30 seconds (syncs and marks made
  elsewhere). A recount is a message to the LiveView itself, so it runs after
  the handler that caused it has committed; several in a row collapse into one.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias Ssm.Diffs.Revocations
  alias Ssm.Scope

  @tick_ms 30_000

  @doc "Assigns the count and, on a connected socket, the hooks that keep it current."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket = socket |> assign(:pending_sync_queued, false) |> recount()

    if connected?(socket) do
      Process.send_after(self(), :pending_sync_tick, @tick_ms)

      socket
      |> attach_hook(:pending_sync_event, :handle_event, fn _event, _params, socket ->
        {:cont, queue(socket)}
      end)
      |> attach_hook(:pending_sync_async, :handle_async, fn _name, _result, socket ->
        {:cont, queue(socket)}
      end)
      |> attach_hook(:pending_sync_info, :handle_info, &handle_info/2)
    else
      socket
    end
  end

  defp handle_info(:pending_sync_recount, socket),
    do: {:halt, socket |> assign(:pending_sync_queued, false) |> recount()}

  defp handle_info(:pending_sync_tick, socket) do
    Process.send_after(self(), :pending_sync_tick, @tick_ms)
    {:halt, recount(socket)}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  defp queue(%{assigns: %{pending_sync_queued: true}} = socket), do: socket

  defp queue(socket) do
    send(self(), :pending_sync_recount)
    assign(socket, :pending_sync_queued, true)
  end

  defp recount(socket) do
    scope = Scope.of(socket.assigns.current_user)
    assign(socket, :pending_sync, Revocations.count(scope))
  end
end
