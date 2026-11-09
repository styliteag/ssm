defmodule SsmWeb.ActivityText do
  @moduledoc """
  Readable audit-log actions for the Activity page and the dashboard. The
  stored action strings never change (`Ssm.Activity.Actions`); the pages
  show these words and keep the stored string as the element's title (and
  search still matches it).
  """

  @labels %{
    "create" => "created",
    "update" => "updated",
    "delete" => "deleted",
    "enable" => "enabled",
    "disable" => "disabled",
    "import" => "imported",
    "sync" => "synced",
    "sync_partial" => "partly synced",
    "sync_failed" => "sync failed",
    "sync_revocation" => "removed revoked keys",
    "sync_revocation_partial" => "partly removed revoked keys",
    "sync_revocation_failed" => "removing revoked keys failed",
    "pin_host_key" => "host key pinned",
    "create_rolled_back" => "creation rolled back",
    "forget_login" => "stopped managing a login",
    "forget_login_failed" => "could not stop managing a login",
    "grant_create" => "grant created",
    "grant_delete" => "grant deleted",
    "grant_add" => "access added by a grant",
    "grant_remove" => "access removed by a grant",
    "grant_move" => "access moved by a grant",
    "bulk_grant" => "access granted in bulk",
    "remove_keys" => "keys removed from host",
    "remove_keys_failed" => "removing keys from host failed",
    "oidc.login" => "signed in (SSO)",
    "oidc.login_refused" => "SSO sign-in refused",
    "oidc.backchannel_logout" => "signed out by SSO",
    "mctl.connect.create" => "Mission Control connected",
    "mctl.connect.rotate" => "Mission Control token rotated",
    "mctl.connect.revoke" => "Mission Control disconnected",
    "mctl_auth_failed" => "Mission Control token refused"
  }

  @doc "Words for a stored action; unknown ones lose their `_` and `.`."
  @spec action(String.t() | nil) :: String.t()
  def action(nil), do: ""
  def action(action), do: Map.get(@labels, action) || String.replace(action, ["_", "."], " ")

  @doc "Badge class per activity type."
  @spec type_class(String.t() | nil) :: String.t()
  def type_class("host"), do: "badge-info"
  def type_class("user"), do: "badge-success"
  def type_class("key"), do: "badge-warning"
  def type_class("auth"), do: "badge-secondary"
  def type_class(_type), do: "badge-ghost"
end
