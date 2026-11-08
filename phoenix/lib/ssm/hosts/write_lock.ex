defmodule Ssm.Hosts.WriteLock do
  @moduledoc """
  One write lock per host, shared by everything that reads a host's
  `authorized_keys` and writes it back: a sync (`Ssm.Diffs.sync_host/2`),
  the removal-only revocation sync (`Ssm.Diffs.RevocationSync`, also around
  its audit entry), "Remove key" (`Ssm.Diffs.KeyRemoval`), offboarding
  (`SsmWeb.Mctl.People`) and forgetting a managed login
  (`Ssm.Hosts.ManagedLogins`). Without it two of them could read the same
  file and the later write would undo the earlier one. A `:global` lock on
  this node; a waiting caller blocks until the holder is done. Re-entrant
  for the holder: a nested `run/2` runs inside the outer one and never
  releases it (`:global.trans/4` alone would drop the lock when the inner
  call ends). Changes made on the host itself are caught by the sha256
  check of `script.sh` instead.
  """

  @doc "Run `fun` while holding `host_id`'s write lock; returns its result."
  @spec run(integer(), (-> result)) :: result when result: term()
  def run(host_id, fun) when is_function(fun, 0) do
    key = {__MODULE__, host_id}

    if Process.get(key) do
      fun.()
    else
      :global.trans({key, self()}, fn -> held(key, fun) end, [node()], :infinity)
    end
  end

  defp held(key, fun) do
    Process.put(key, true)

    try do
      fun.()
    after
      Process.delete(key)
    end
  end
end
