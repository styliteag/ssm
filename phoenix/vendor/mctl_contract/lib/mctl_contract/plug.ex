defmodule MctlContract.Plug do
  @moduledoc """
  The contract router. Mount it in the tool's router:

      forward "/api/mctl/v1", MctlContract.Plug,
        provider: MyApp.MctlProvider,
        token_store: MyApp.MctlTokens

  Options:

    * `:provider` (required) – a `MctlContract.Provider`
    * `:token_store` – a `MctlContract.TokenStore`
      (default `MctlContract.Tokens.Ecto`)
    * `:idempotency_store` – a `MctlContract.IdempotencyStore`
      (default `MctlContract.Idempotency.Ecto`)
    * `:product` – overrides the product name of `provider.product/0`
    * `:auth_hooks` – a `MctlContract.AuthHooks` (per-IP failure limit,
      failure audit, per-token rate limit); default none
    * `:max_body` – largest JSON body in bytes (default 1 MB); larger is
      `400 bad_request`

  The JSON body is parsed here, after authentication, unless the host
  endpoint already did: use `MctlContract.Parsers` in the endpoint, it
  leaves contract bodies to this plug.
  Routes and scopes: `MctlContract.OpenAPI.operations/0`.
  """
  use Plug.Router, copy_opts_to_assign: :mctl_opts

  alias MctlContract.Plug.{Auth, Handlers, Idempotency, Respond}

  @max_body 1_000_000

  @impl true
  def init(opts) do
    opts = Keyword.put_new(opts, :max_body, @max_body)

    parsers =
      Plug.Parsers.init(
        parsers: [:json],
        pass: ["*/*"],
        json_decoder: Jason,
        length: Keyword.fetch!(opts, :max_body)
      )

    opts
    |> Keyword.put_new(:token_store, MctlContract.Tokens.Ecto)
    |> Keyword.put_new(:idempotency_store, MctlContract.Idempotency.Ecto)
    |> Keyword.put(:mctl_parsers, parsers)
    |> tap(&Keyword.fetch!(&1, :provider))
  end

  # the token is checked before the body is read: unauthenticated
  # clients never make the server parse a body
  plug :match
  plug :authenticate
  plug :parse_body
  plug :dispatch

  get "/openapi.json", private: %{mctl_need: :public} do
    Handlers.openapi(conn, opts(conn))
  end

  get "/me", private: %{mctl_need: :any} do
    Handlers.me(conn, opts(conn))
  end

  get "/hosts", private: %{mctl_need: "read"} do
    Handlers.list(conn, opts(conn), "hosts", :list_hosts, Handlers.renderer(:host))
  end

  get "/hosts/:id", private: %{mctl_need: "read"} do
    Handlers.get(conn, opts(conn), :get_host, id, Handlers.renderer(:host))
  end

  get "/host-summaries", private: %{mctl_need: "read"} do
    Handlers.list_if(
      conn,
      opts(conn),
      "host_summaries",
      "host_summaries",
      :list_host_summaries,
      Handlers.renderer(:host_summary)
    )
  end

  get "/hosts/:id/summary", private: %{mctl_need: "read"} do
    Handlers.get_if(
      conn,
      opts(conn),
      "host_summaries",
      :get_host_summary,
      id,
      Handlers.renderer(:host_summary)
    )
  end

  post "/hosts", private: %{mctl_need: "setup"} do
    idempotent(conn, fn conn ->
      Handlers.write(
        conn,
        opts(conn),
        :host_create,
        {:create_host, []},
        202,
        Handlers.renderer(:job)
      )
    end)
  end

  patch "/hosts/:id", private: %{mctl_need: "setup"} do
    Handlers.write(
      conn,
      opts(conn),
      :host_update,
      {:update_host, [id]},
      200,
      Handlers.renderer(:host)
    )
  end

  post "/hosts/:id/actions", private: %{mctl_need: "commands"} do
    idempotent(conn, &Handlers.host_action(&1, opts(&1), id))
  end

  delete "/hosts/:id", private: %{mctl_need: "setup"} do
    Handlers.delete_host(conn, opts(conn), id)
  end

  post "/hosts/:id/maintenance", private: %{mctl_need: "setup"} do
    idempotent(conn, &Handlers.create_maintenance(&1, opts(&1), id))
  end

  get "/maintenance", private: %{mctl_need: "read"} do
    Handlers.list_if(
      conn,
      opts(conn),
      "maintenance",
      "maintenance",
      :list_maintenance,
      &MctlContract.Render.maintenance/1
    )
  end

  delete "/maintenance/:id", private: %{mctl_need: "setup"} do
    Handlers.cancel_maintenance(conn, opts(conn), id)
  end

  get "/people/:key", private: %{mctl_need: "read"} do
    Handlers.get_person(conn, opts(conn), key)
  end

  post "/people/:key/remove", private: %{mctl_need: "commands"} do
    idempotent(conn, &Handlers.remove_person(&1, opts(&1), key))
  end

  get "/customers", private: %{mctl_need: "read"} do
    Handlers.list(conn, opts(conn), "customers", :list_customers, Handlers.renderer(:named))
  end

  post "/customers", private: %{mctl_need: "setup"} do
    idempotent(conn, fn conn ->
      Handlers.write(
        conn,
        opts(conn),
        :named_create,
        {:create_customer, []},
        201,
        Handlers.renderer(:named)
      )
    end)
  end

  patch "/customers/:slug", private: %{mctl_need: "setup"} do
    Handlers.write(
      conn,
      opts(conn),
      :named_update,
      {:update_customer, [slug]},
      200,
      Handlers.renderer(:named)
    )
  end

  get "/groups", private: %{mctl_need: "read"} do
    Handlers.list(conn, opts(conn), "groups", :list_groups, Handlers.renderer(:named))
  end

  post "/groups", private: %{mctl_need: "setup"} do
    idempotent(conn, fn conn ->
      Handlers.write(
        conn,
        opts(conn),
        :named_create,
        {:create_group, []},
        201,
        Handlers.renderer(:named)
      )
    end)
  end

  patch "/groups/:slug", private: %{mctl_need: "setup"} do
    Handlers.update_group(conn, opts(conn), slug)
  end

  get "/jobs", private: %{mctl_need: "read"} do
    Handlers.list(conn, opts(conn), "jobs", :list_jobs, Handlers.renderer(:job))
  end

  get "/jobs/:id", private: %{mctl_need: "read"} do
    Handlers.get(conn, opts(conn), :get_job, id, Handlers.renderer(:job))
  end

  match _, private: %{mctl_need: :public} do
    Handlers.not_found(conn)
  end

  defp opts(conn), do: conn.assigns.mctl_opts

  defp idempotent(conn, fun), do: Idempotency.run(conn, opts(conn)[:idempotency_store], fun)

  defp parse_body(conn, _opts) do
    Plug.Parsers.call(conn, opts(conn)[:mctl_parsers])
  rescue
    Plug.Parsers.RequestTooLargeError ->
      max = opts(conn)[:max_body]
      Respond.error(conn, "bad_request", "the request body is too large (max #{max} bytes)")

    Plug.Parsers.ParseError ->
      Respond.error(conn, "bad_request", "the request body is not valid JSON")
  end

  defp authenticate(conn, _opts), do: Auth.call(conn, opts(conn))
end
