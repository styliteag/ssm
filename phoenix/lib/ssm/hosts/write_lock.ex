defmodule Ssm.Hosts.WriteLock do
  @moduledoc """
  One write lock per host, shared by everything that reads a host's
  `authorized_keys` and writes it back: a sync (`Ssm.Diffs.sync_host/2`),
  "Remove key" (`Ssm.Diffs.KeyRemoval`), offboarding (`SsmWeb.Mctl.People`)
  and forgetting a managed login (`Ssm.Hosts.ManagedLogins`). Without it two
  of them could read the same file and the later write would undo the
  earlier one. A `:global` lock on this node, re-entrant for the same
  process; a waiting caller blocks until the holder is done. Changes made on
  the host itself are caught by the sha256 check of `script.sh` instead.
  """

  @doc "Run `fun` while holding `host_id`'s write lock; returns its result."
  @spec run(integer(), (-> result)) :: result when result: term()
  def run(host_id, fun) when is_function(fun, 0),
    do: :global.trans({{__MODULE__, host_id}, self()}, fun, [node()], :infinity)
end
