defmodule Ssm.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SsmWeb.Telemetry,
        Ssm.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:ssm, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:ssm, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Ssm.PubSub},
        # SSH read cache (always) + the real client (not in tests — tests use
        # Ssm.Ssh.MockClient via config :ssm, :ssh_client).
        Ssm.Ssh.Cache,
        # Last known per-host sync status for the diff viewer.
        Ssm.Diffs.StatusCache,
        # In-memory request/failure limits (mctl API auth hooks).
        Ssm.RateLimit,
        # mctl contract: create_host job work (host-key probe + pin).
        {Task.Supervisor, name: Ssm.Mctl.TaskSupervisor}
      ] ++
        mctl_boot() ++
        ssh_children() ++
        [
          # Start to serve requests, typically the last entry
          SsmWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ssm.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SsmWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  # After the repo and the migrator: install/rotate the `ssm_` service token
  # from MCTL_TOKEN_FILE, fail create_host jobs a restart interrupted, and
  # prune the mctl tables periodically. Off in tests (SQL sandbox).
  defp mctl_boot do
    if Application.get_env(:ssm, :mctl_boot, true) do
      [
        Supervisor.child_spec({Task, &Ssm.Mctl.Boot.run/0}, id: :mctl_boot),
        # Hourly batched prune of mctl_jobs / mctl_idempotency.
        Ssm.Mctl.Pruner
      ]
    else
      []
    end
  end

  defp ssh_children do
    if Application.get_env(:ssm, :start_ssh_client, true) do
      [Ssm.Ssh.ErlangClient]
    else
      []
    end
  end
end
