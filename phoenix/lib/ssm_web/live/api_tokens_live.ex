defmodule SsmWeb.ApiTokensLive do
  @moduledoc """
  Setup → API tokens → "Connect Mission Control" (US-API-09). Admin only,
  checked on mount and in every event. The token is shown once in the
  `:secret` assign (cleared by "Done"); it is never persisted, logged,
  flashed or put in the URL.
  """

  use SsmWeb, :live_view

  alias Ssm.Mctl.Connect
  alias SsmWeb.Layouts

  @not_admin "Only administrators can manage API tokens."

  @impl true
  def mount(_params, _session, socket) do
    if admin?(socket) do
      {:ok, socket |> assign(page_title: "API tokens", secret: nil) |> load_status()}
    else
      {:ok, socket |> put_flash(:error, @not_admin) |> redirect(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event(event, params, socket) do
    if admin?(socket) do
      {:noreply, act(event, params, socket)}
    else
      {:noreply, put_flash(socket, :error, @not_admin)}
    end
  end

  defp act("create", params, socket) do
    scopes = List.wrap(params["scopes"])

    case Connect.create(actor(socket), scopes) do
      {:ok, plain} -> show_secret(socket, plain)
      {:error, :no_scopes} -> put_flash(socket, :error, "Choose at least one scope.")
      {:error, _reason} -> put_flash(socket, :error, "Could not create the token.")
    end
  end

  defp act("rotate", _params, socket) do
    case Connect.rotate(actor(socket)) do
      {:ok, plain} -> show_secret(socket, plain)
      {:error, _reason} -> put_flash(socket, :error, "No token to rotate.")
    end
  end

  defp act("revoke", _params, socket) do
    case Connect.revoke(actor(socket)) do
      :revoked -> socket |> assign(secret: nil) |> load_status()
      :none -> put_flash(socket, :error, "No active token to revoke.")
    end
  end

  defp act("done", _params, socket), do: assign(socket, secret: nil)
  defp act(_event, _params, socket), do: socket

  defp show_secret(socket, plain) do
    socket
    |> assign(secret: %{token: plain, base_url: Connect.base_url(), snippet: Connect.snippet()})
    |> load_status()
  end

  defp load_status(socket), do: assign(socket, status: Connect.status())

  defp admin?(socket), do: match?(%{role: "admin"}, socket.assigns[:current_user])
  defp actor(socket), do: socket.assigns.current_user.actor

  defp can_create?(nil), do: true
  defp can_create?(%{state: state}), do: state != "active"

  defp format_time(nil, _zone), do: "never"
  defp format_time(%DateTime{} = dt, zone), do: SsmWeb.TimeZone.format(dt, zone, "datetime")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      pending_sync={@pending_sync}
      active={:api_tokens}
    >
      <.header>
        API tokens
        <:subtitle>Tokens other tools use to call ssm (Mission Control)</:subtitle>
      </.header>

      <section id="connect-mctl" class="card border border-base-300 bg-base-100">
        <div class="card-body gap-4">
          <h2 class="card-title">Connect Mission Control</h2>
          <p class="text-sm opacity-75">
            Creates the service token <code>mission-control</code>
            for Mission Control. The token comes from here; the <code>mission-control-env</code>
            token set by the environment is separate.
          </p>

          <.status_line status={@status} zone={@time_zone} />

          <.secret_box :if={@secret} secret={@secret} />

          <form :if={can_create?(@status)} id="connect-form" phx-submit="create" class="space-y-3">
            <fieldset class="flex flex-wrap gap-4">
              <legend class="mb-1 text-sm font-medium">Scopes</legend>
              <label :for={scope <- Connect.scopes()} class="label cursor-pointer gap-2">
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  name="scopes[]"
                  value={scope}
                  checked
                />
                <span>{scope}</span>
              </label>
            </fieldset>
            <button type="submit" id="connect-create" class="btn btn-primary btn-sm">
              Connect Mission Control
            </button>
          </form>

          <div :if={@status && @status.state == "active"} class="flex gap-2">
            <button
              id="connect-rotate"
              type="button"
              phx-click="rotate"
              class="btn btn-sm"
              data-confirm="Rotate the token? The current secret stops working at once."
            >
              Rotate
            </button>
            <button
              id="connect-revoke"
              type="button"
              phx-click="revoke"
              class="btn btn-error btn-outline btn-sm"
              data-confirm="Revoke the token? Mission Control loses access to ssm."
            >
              Revoke
            </button>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :status, :any, required: true
  attr :zone, :string, required: true

  defp status_line(%{status: nil} = assigns) do
    ~H"""
    <p id="connect-status" class="text-sm">No token yet.</p>
    """
  end

  defp status_line(assigns) do
    ~H"""
    <p id="connect-status" class="text-sm">
      <span class={[
        "badge badge-sm",
        if(@status.state == "active", do: "badge-success", else: "badge-warning")
      ]}>
        {String.capitalize(@status.state)}
      </span>
      Prefix <code>{@status.prefix}</code>, scopes {Enum.join(@status.scopes, ", ")}.
      Last used {format_time(@status.last_used_at, @zone)}{if @status.last_used_ip,
        do: " from #{@status.last_used_ip}"}. Updated {format_time(@status.updated_at, @zone)}.
    </p>
    """
  end

  attr :secret, :map, required: true

  defp secret_box(assigns) do
    ~H"""
    <div id="connect-secret-box" class="space-y-3 rounded-box border border-warning p-4">
      <p id="connect-secret-note" class="text-sm font-medium">
        This token is shown once; put the token into the token_file. It cannot be displayed again.
      </p>
      <div>
        <div class="text-xs opacity-60">Token</div>
        <code id="connect-secret" class="break-all">{@secret.token}</code>
        <.copy id="copy-connect-token" text={@secret.token} />
      </div>
      <div>
        <div class="text-xs opacity-60">ssm base URL</div>
        <code id="connect-base-url">{@secret.base_url}</code>
      </div>
      <div>
        <div class="text-xs opacity-60">Entry for MCTL_CONNECTORS_FILE</div>
        <pre id="connect-snippet" class="overflow-x-auto rounded bg-base-200 p-3 text-xs">{@secret.snippet}</pre>
        <.copy id="copy-connect-snippet" text={@secret.snippet} />
      </div>
      <button
        id="connect-done"
        type="button"
        phx-click="done"
        class="btn btn-sm btn-primary"
        data-confirm="Did you copy the token? It is shown only once; after this it can only be rotated."
        data-confirm-label="Close, I copied it"
      >
        Done
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true

  defp copy(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class="btn btn-ghost btn-xs"
      phx-hook="CopyToClipboard"
      data-copy={@text}
      title="Copy"
      aria-label="Copy"
    >
      <.icon name="hero-clipboard" class="size-4 [[data-copied]_&]:hidden" />
      <.icon name="hero-check" class="hidden size-4 text-success [[data-copied]_&]:inline-block" />
    </button>
    """
  end
end
