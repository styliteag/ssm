defmodule SsmWeb.Router do
  use SsmWeb, :router

  import SsmWeb.UserAuth

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", SsmWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SsmWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  scope "/", SsmWeb do
    pipe_through :browser

    get "/", PageController, :home
    post "/session", SessionController, :create
    delete "/sign-out", SessionController, :delete

    live_session :auth, on_mount: [{SsmWeb.UserAuth, :live_no_user}] do
      live "/sign-in", LoginLive
    end

    live_session :authenticated, on_mount: [{SsmWeb.UserAuth, :live_user_required}] do
      live "/dashboard", DashboardLive
      live "/hosts", HostsLive
      live "/users", UsersLive
      live "/keys", KeysLive
      live "/authorizations", AuthorizationsLive
      live "/diff", DiffLive
      live "/activities", ActivitiesLive
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:ssm, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SsmWeb.Telemetry
    end
  end
end
