defmodule SsmWeb.LoginLive do
  @moduledoc """
  Sign-in form. Submits as a plain POST to `SsmWeb.SessionController` because
  session cookies can only be written from a request/response cycle.
  """

  use SsmWeb, :live_view

  alias SsmWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    oidc = Ssm.OIDC.Config.get()

    {:ok,
     assign(socket,
       form: to_form(%{"username" => ""}, as: :login),
       page_title: "Sign in",
       oidc_label: oidc && oidc.login_label,
       local_form?: Ssm.OIDC.Config.local_login() != :off
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto mt-16 w-full max-w-sm">
        <div class="card bg-base-200">
          <div class="card-body">
            <h1 class="card-title mb-2">
              <.icon name="hero-key" class="size-5 text-primary" /> Secure SSH Manager
            </h1>

            <a
              :if={@oidc_label}
              id="oidc-login"
              href={~p"/auth/oidc/login"}
              class="btn btn-primary w-full"
            >
              {@oidc_label}
            </a>

            <.form
              :if={@local_form?}
              for={@form}
              action={~p"/session"}
              method="post"
              class="space-y-4"
            >
              <.input
                field={@form[:username]}
                name="username"
                type="text"
                label="Username"
                autocomplete="username"
                required
                autofocus
              />
              <.input
                field={@form[:password]}
                name="password"
                type="password"
                label="Password"
                autocomplete="current-password"
                required
              />
              <button class="btn btn-primary w-full" type="submit">Sign in</button>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
