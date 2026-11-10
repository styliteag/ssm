defmodule SsmWeb.ManagedLoginsComponents do
  @moduledoc """
  The hosts page's "Managed logins" dialog (admin only, `SsmWeb.HostsLive`):
  the logins ssm keeps writing on a host (`managed_logins`) with their
  number of access entries, and "Forget" for one without access entries.
  Whether the host still has a file for it is asked when forgetting
  (`Ssm.Hosts.ManagedLogins.forget/4`).
  """

  use SsmWeb, :html

  attr :managed, :map, required: true, doc: "%{host, logins, busy}"

  def managed_logins_modal(assigns) do
    ~H"""
    <.modal id="managed-logins-modal" on_cancel={JS.push("managed-logins-close")}>
      <:title>Managed logins on {@managed.host.name}</:title>

      <p class="mb-3 text-sm opacity-70">
        A sync keeps writing the authorized_keys of every login that ever had access here,
        so a revocation reaches the host. Forget a login only when it has no access entries
        and its file is gone from the host; ssm checks the host first.
      </p>

      <p :if={@managed.logins == []} class="text-sm opacity-60">No managed logins.</p>

      <ul :if={@managed.logins != []} class="space-y-1">
        <li
          :for={entry <- @managed.logins}
          id={"managed-login-#{entry.login}"}
          class="flex items-center gap-2 rounded bg-base-200 px-3 py-1"
        >
          <span class="font-mono text-sm">{entry.login}</span>
          <span class="badge badge-ghost badge-sm tabular-nums">
            {access_entries(entry.authorizations)}
          </span>
          <button
            id={"forget-login-#{entry.login}"}
            class="btn btn-ghost btn-xs ml-auto text-error"
            phx-click="forget-login"
            phx-value-host-id={@managed.host.id}
            phx-value-login={entry.login}
            disabled={entry.authorizations > 0 or @managed.busy}
            data-confirm={"Forget login #{entry.login} on #{@managed.host.name}? A sync no longer writes its authorized_keys."}
            title={
              if entry.authorizations > 0,
                do: "Revoke its access entries first",
                else: "Stop managing this login (checks the host first)"
            }
            aria-label={
              if entry.authorizations > 0,
                do: "Revoke its access entries first",
                else: "Stop managing this login (checks the host first)"
            }
          >
            <.icon name="hero-trash" class="size-4" /> Forget
          </button>
        </li>
      </ul>
    </.modal>
    """
  end
end
