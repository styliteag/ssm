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

  pipeline :api_v2_auth do
    plug SsmWeb.Api.AuthPlug
  end

  # The python stack's JSON API, kept wire-compatible (plan §7 default):
  # bearer JWT, ApiResponse envelope, stable error codes. login/refresh/logout
  # are public (logout is a stateless client-side no-op), everything else
  # requires an access token.
  scope "/api/v2", SsmWeb.Api do
    pipe_through :api

    post "/auth/login", AuthController, :login
    post "/auth/refresh", AuthController, :refresh
    post "/auth/logout", AuthController, :logout

    scope "/" do
      pipe_through :api_v2_auth

      get "/auth/me", AuthController, :me

      get "/hosts", HostController, :index
      post "/hosts", HostController, :create
      get "/hosts/:id", HostController, :show
      patch "/hosts/:id", HostController, :update
      delete "/hosts/:id", HostController, :delete

      get "/users", UserController, :index
      post "/users", UserController, :create
      get "/users/:id", UserController, :show
      patch "/users/:id", UserController, :update
      delete "/users/:id", UserController, :delete

      get "/keys", KeyController, :index
      post "/keys", KeyController, :create
      get "/keys/:id", KeyController, :show
      patch "/keys/:id", KeyController, :update
      delete "/keys/:id", KeyController, :delete

      get "/authorizations", AuthorizationController, :index
      post "/authorizations", AuthorizationController, :create
      get "/authorizations/:id", AuthorizationController, :show
      patch "/authorizations/:id", AuthorizationController, :update
      delete "/authorizations/:id", AuthorizationController, :delete

      get "/activity-log", ActivityLogController, :index
      get "/info", InfoController, :show

      get "/diffs/:host_id", DiffController, :show
      post "/diffs/:host_id/sync", DiffController, :sync
    end
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SsmWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
    plug :fetch_design
  end

  # Theme cookies → assigns for the root layout's data-theme (design pattern
  # from ../dashboard & ../link-shortener; see SsmWeb.Design).
  defp fetch_design(conn, _opts) do
    conn = fetch_cookies(conn)
    design = SsmWeb.Design.validate(conn.cookies["ssm_design"])
    mode = SsmWeb.Design.validate_mode(conn.cookies["ssm_mode"])

    conn
    |> assign(:design, design)
    |> assign(:mode, mode)
    |> assign(:theme, SsmWeb.Design.theme(design, mode))
  end

  scope "/", SsmWeb do
    pipe_through :browser

    get "/", PageController, :home
    post "/session", SessionController, :create
    delete "/sign-out", SessionController, :delete

    # Theme choice works pre-login too (the login page is themed).
    post "/design", DesignController, :design
    post "/design/mode", DesignController, :mode

    live_session :auth, on_mount: [{SsmWeb.UserAuth, :live_no_user}] do
      live "/sign-in", LoginLive
    end
  end

  scope "/", SsmWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/authorizations/export", AuthorizationExportController, :export
  end

  scope "/", SsmWeb do
    pipe_through :browser

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
