defmodule Ssm.Activity.Actions do
  @moduledoc """
  The catalog of activity-log actions (`activity_log.action`): an atom per
  action, mapped to the string that is stored. The strings are history —
  the activity page filters and searches on them — so an entry here is
  never renamed. New code names its action with `name/1`; an unknown atom
  raises. `test/ssm/activity/actions_test.exs` snapshots the list and fails
  on a literal action in `lib/` that is missing here.
  """

  @actions [
    # web UI and /api/v2 writes (host, user, key, auth)
    create: "create",
    update: "update",
    delete: "delete",
    import: "import",
    enable: "enable",
    disable: "disable",
    split: "split",
    merge: "merge",
    bulk_grant: "bulk_grant",
    # syncs (Ssm.Diffs.SyncAudit)
    sync: "sync",
    sync_partial: "sync_partial",
    sync_failed: "sync_failed",
    sync_revocation: "sync_revocation",
    sync_revocation_partial: "sync_revocation_partial",
    sync_revocation_failed: "sync_revocation_failed",
    # host writes outside a sync
    remove_keys: "remove_keys",
    remove_keys_failed: "remove_keys_failed",
    forget_login: "forget_login",
    forget_login_failed: "forget_login_failed",
    # grants (Ssm.Grants, Ssm.Grants.Expansion)
    grant_create: "grant_create",
    grant_delete: "grant_delete",
    grant_add: "grant_add",
    grant_remove: "grant_remove",
    grant_move: "grant_move",
    # refusals and locks
    admin_only_refused: "admin_only_refused",
    login_locked: "login_locked",
    # host keys (Ssm.Hosts.HostKeys)
    pin_host_key: "pin_host_key",
    accept_host_key: "accept_host_key",
    # mctl contract
    create_rolled_back: "create_rolled_back",
    customer_merge: "customer_merge",
    customer_delete: "customer_delete",
    group_delete: "group_delete",
    probe_ssh: "probe_ssh",
    mctl_remove_person: "mctl_remove_person",
    mctl_auth_failed: "mctl_auth_failed",
    mctl_auth_locked: "mctl_auth_locked",
    mctl_connect_create: "mctl.connect.create",
    mctl_connect_rotate: "mctl.connect.rotate",
    mctl_connect_revoke: "mctl.connect.revoke",
    # web login (OIDC)
    oidc_login: "oidc.login",
    oidc_backchannel_logout: "oidc.backchannel_logout",
    oidc_login_refused: "oidc.login_refused"
  ]

  @names Keyword.values(@actions)

  @type t :: atom()

  @doc "The stored string of `action`; an atom outside the catalog raises."
  @spec name(t()) :: String.t()
  for {action, name} <- @actions do
    def name(unquote(action)), do: unquote(name)
  end

  @doc "Every stored action string."
  @spec all() :: [String.t()]
  def all, do: @names

  @doc "Is `name` a cataloged action string?"
  @spec known?(String.t()) :: boolean()
  def known?(name), do: name in @names
end
