defmodule Ssm.Mctl.Boot do
  @moduledoc """
  One-shot mctl boot work (contract-v1 §7, ADR-0009), run from the
  application supervisor after the repo and migrations:

    * `MCTL_TOKEN_FILE` → create/rotate the `ssm_` service token
      `mission-control` (`MCTL_TOKEN_SCOPES`, default `read,setup,commands`);
      only its SHA-256 is stored, the token never reaches the log.
    * `create_host` jobs left `queued`/`running` by a restart are failed.
  """

  require Logger

  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    # Logs its own outcome (never the token); a failure must not stop boot.
    _ =
      MctlContract.Bootstrap.ensure_service_token(
        MctlContract.Tokens.Ecto,
        Keyword.merge([prefix: "ssm_"], opts)
      )

    stale = MctlContract.Jobs.Ecto.fail_stale()
    if stale > 0, do: Logger.warning("mctl: failed #{stale} job(s) interrupted by a restart")
    :ok
  end
end
