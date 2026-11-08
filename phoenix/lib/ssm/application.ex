defmodule Ssm.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Ssm.OIDC.Config.load()
    check_revocation_sync()
    :ok = Ssm.SecurityLog.install()

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
        # Back-channel logout replay store.
        Ssm.OIDC.JtiStore,
        # Large ID tokens kept server-side for the logout hint.
        Ssm.OIDC.TokenStore,
        # mctl contract: create_host job work (host-key probe + pin).
        {Task.Supervisor, name: Ssm.Mctl.TaskSupervisor},
        # Periodic key check sweeps (Ssm.Diffs.SyncScheduler), manual syncs
        # (Ssm.Diffs.SyncRunner) and the removal-only sync.
        {Task.Supervisor, name: Ssm.Diffs.TaskSupervisor},
        # Manual syncs (diff page): per-host state, runs under the supervisor above.
        Ssm.Diffs.SyncRunner
      ] ++
        oidc_children() ++
        mctl_boot() ++
        ssh_children() ++
        sync_children() ++
        drift_children() ++
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

  # Provider discovery/JWKS worker, only when OIDC_ISSUER configured OIDC.
  defp oidc_children do
    case Ssm.OIDC.Config.get() do
      nil -> []
      _config -> [Supervisor.child_spec(Ssm.OIDC.Supervisor, restart: :temporary)]
    end
  end

  # The periodic key check: needs the real SSH client, so off in tests;
  # SSM_SYNC_INTERVAL=0|off disables it, a bad value is logged and the
  # default (15 minutes) applies.
  defp sync_children do
    if Application.get_env(:ssm, :start_ssh_client, true) do
      raw = Application.get_env(:ssm, :sync_check, []) |> Keyword.get(:interval)

      case Ssm.Diffs.SyncScheduler.parse_interval(raw) do
        {:ok, seconds} ->
          [{Ssm.Diffs.SyncScheduler, interval_ms: seconds * 1000}]

        :off ->
          []

        {:error, message} ->
          Logger.error("#{message}; using the default interval")
          {:ok, seconds} = Ssm.Diffs.SyncScheduler.parse_interval(nil)
          [{Ssm.Diffs.SyncScheduler, interval_ms: seconds * 1000}]
      end
    else
      []
    end
  end

  # SSM_REVOCATION_SYNC: a bad value is logged and counts as off
  defp check_revocation_sync do
    case Ssm.Diffs.RevocationSync.parse(Application.get_env(:ssm, :revocation_sync)) do
      {:ok, true} -> Logger.info("removal-only revocation sync is on (SSM_REVOCATION_SYNC)")
      {:ok, false} -> :ok
      {:error, message} -> Logger.error(message <> "; the revocation sync stays off")
    end
  end

  # The periodic grant drift check (logs only, never writes); off in tests.
  defp drift_children do
    case Ssm.Grants.DriftCheck.child_opts() do
      nil -> []
      opts -> [{Ssm.Grants.DriftCheck, opts}]
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
