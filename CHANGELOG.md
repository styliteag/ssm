# Changelog

All notable changes to SSM (Secure SSH Manager) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Confirmations open a styled dialog instead of the browser's box. "Sync all" asks to type
  "sync N" (the number of hosts it writes) before it starts.
- Empty hosts and SSH users lists offer the first step ("New host", "New SSH user").

- Diff page: "Remove login from host" for a login the host does not know ("home not available:
  the host does not know this login"), admins only. It deletes the login's authorizations on
  that host and ssm stops managing the login there. The question warns that a directory outage
  (LDAP/AD/SSSD) looks the same. A login whose home is only missing (an inactive HA node) gets
  no such button; access from a grant must be removed through the grant.
- The header shows on every page how many hosts wait for a sync after access was taken away
  there ("N hosts pending sync"); it links to the new "Pending sync" filter on the hosts page.
  The count follows changes made on the same page at once and others within 30 seconds.

### Changed

- Dialogs are announced as dialogs, keep the keyboard focus inside, start on the first field
  and no longer close on a click beside them (a stray click lost the form). Icon-only buttons,
  search fields and filters have accessible names. Enable/disable a host use clearer icons.
- Sync page: List comes before Cards as on the other pages, and search and filter stay in the
  URL (reload, back button, shared links).
- One vocabulary across the UI. Navigation: "SSH users", "SSH keys", "Access" (was
  Authorizations), "Sync" (was Diff Viewer), "Activity". A user → host → login row is an
  "access entry" (no longer also called a grant; "Grant" is only the customer/group rule).
  The account on the target host is the "target login"; the account ssm logs in as is the
  "connection user". Host states have one word each on every page: not checked, in sync,
  needs sync, online, unreachable, key not accepted, host key changed, disabled. The hosts
  page "Refresh all" is "Test connections", the sync detail "Refresh" is "Read again".
  The `/api/v2` API is unchanged.

- Deleting a host says that ssm never connects to it again, so the key lines it placed and
  ssm's own key stay on the host — delete the authorizations and sync first to take access
  away.
- Deleting or disabling an SSH user, deleting a key or an authorization: the question and the
  message say the keys leave the hosts at the next sync (enabling: they reach the hosts at the
  next sync).

- Diff page: "Sync all" now asks first, like the per-host "Sync" buttons. Every sync
  question names what the sync does as of the last check — how many hosts, how many key
  lines it adds and removes — and says that every key line ssm does not grant is removed,
  including keys added by hand on the host. The detail view's "Sync" asks too.
- Authorizations matrix: revoking a cell asks first; granting and revoking show a message
  saying the change reaches the host at its next sync.
- Error messages on the hosts and diff pages no longer show raw Elixir terms; the details
  go to the server log and the page shows a plain sentence.

## [4.13.4] - 2026-11-09

### Fixed

- "Revocation pending" also ends on a read — the diff, Refresh or the periodic check — that
  finds every login readable and no unauthorized line left on the host; nothing is
  written. Before, only a sync cleared it, even when the removed key had never been on the
  host. A login that could not be read (home not available, unsafe, blocked) keeps the
  mark. The hosts page badge shows the reason and its age.
- A login whose home is not there — an inactive HA node with its pool not imported, an
  unmounted home, a login the host does not know — no longer shows its keys as "missing on
  host". `script.sh get_ssh_keyfiles <login>…` reports it with a code (`home_missing`,
  `home_unreadable`, `unknown_login`); the diff says "home not available" for that login,
  and the host status and periodic check leave it out (no "needs sync", no error).

## [4.13.3] - 2026-11-09

### Changed

- Offboarding a person from Mission Control no longer writes to any host: ssm deletes the
  person's authorizations and shared keys and disables the operator, and the affected
  hosts show "revocation pending" until someone presses Sync in ssm. The job result lists
  them as `revocation_pending` (`hosts` is empty: nothing was written).

## [4.13.2] - 2026-11-09

### Changed

- Diff viewer: only the "Sync" buttons write to a host. "Remove" and "Remove all extra
  keys" (which took unauthorized lines off the host at once) and "Remove and sync now" are
  gone; Allow, Add key and Remove <user> change the database and reload the diff, and the
  next Sync updates the host (it also drops unauthorized lines).

## [4.13.1] - 2026-11-09

### Added

- Diff viewer: "Remove <user>" on every key line of a manual authorization (present or
  missing on the host). A dialog lists the login's lines and marks every key of that SSH
  user; "Remove" deletes the access in ssm, "Remove and sync now" also syncs the host.

## [4.13.0] - 2026-11-09

### Added

- SSH user page (`/users/<id>`): the user's keys (short, copyable), its access per host and
  login with the host's last key check (links to the diff), whether a row comes from a
  grant (link to the grants), and its grants. User names link to it from the users,
  keys, grants and authorizations pages.
- Search on the users (with an enabled/disabled filter), hosts and grants pages. The
  searches and filters of users, hosts, keys, grants, authorizations and activities live
  in the URL and are remembered per page in the browser tab: navigating away and back
  keeps them.
- More links: host names and status badges open the diff; authorization logins open the
  diff; grant targets filter the grants; activity entries link to their host's diff or
  search their user, key or authorization. The unknown-key dialog shows the key
  shortened with a copy button.

## [4.12.3] - 2026-11-09

### Changed

- A sync that wrote some logins and skipped others (e.g. a login that does not exist on
  the host) shows a yellow "Sync of … partly done" warning instead of a red "failed"
  error, and the diff refreshes.
- Diff viewer key rows: long keys show only their start and end (`ssh-rsa AAAAB3NzaC1y…<last 20>
  comment`, full line on hover), a copy button per line, the owner as a link to the SSH
  user's keys plus the key name, and a "grant" badge linking to the user's grants when the
  access comes from a grant. Each login has "Copy authorized_keys": the file a sync would
  write. A key "missing on host" from a manual authorization gets "Remove user" (deletes
  that access in ssm, then the diff reloads).

## [4.12.2] - 2026-11-08

## [4.12.1] - 2026-11-08

### Fixed

- Splitting or merging SSH users no longer crashes on an authorization whose host was
  deleted long ago (left behind by an older database without foreign keys): such rows
  are not copied.
- A failed key write now names the script's own reason (e.g. "Keyfile is unsafe
  (ssh_user)") even when the host's login shell prints to stderr (motd, agent
  banners); before, such output replaced the reason and an unsafe or readonly
  refusal showed as a connection error.

## [4.12.0] - 2026-11-08

### Added

- Grants (ADR-0012 phase 2): SSH access for an SSH user on every host of a
  customer or host group, on the new Grants page (`/grants`, also per SSH user
  from the Users page and per customer or group). A grant creates a normal
  authorization on each host of its target, now and for hosts that join
  later; a host that leaves the customer or group loses it. Diff, sync,
  `/api/v2` and Mission Control see these rows like any other.
- An authorization made by a grant is read-only and shows "via customer X" or
  "via group Y" on the Authorizations page. `/api/v2` answers 409 `CONFLICT`
  when such a row is changed or deleted; change the grant instead. A manual
  authorization for the same user, host and login wins and is kept; deleting
  it brings the grant's authorization back.
- Admins create any grant. A scoped operator creates grants only for its own
  customers or groups, and the grant keeps the operator's scope, so it never
  reaches a host outside it. A scoped operator sees and deletes only grants
  inside its scope. Viewers cannot change grants.
- "Revocation pending" on the Hosts page: a host that lost access through a
  grant (grant deleted, host moved to another customer or out of a group,
  customer merged) keeps the removed keys until a sync succeeds there. The
  mark clears after the next successful sync; without `SSM_REVOCATION_SYNC=on`
  ssm does not sync on its own.
- The activity log records grant create and delete, and every authorization a
  grant adds, removes or hands over to another grant (`grant_add`,
  `grant_remove`, `grant_move`) with the trigger, the grant id, the actor and
  the request id.
- A periodic check (every 15 minutes) compares grants and authorizations and
  logs differences as warnings. It changes nothing.
- `SSM_REVOCATION_SYNC=on` (default `off`) starts a removal-only sync right
  after every change that removes access (grant deleted, host moved out of a
  customer or group, authorization deleted, SSH user deleted, person
  offboarded, an authorization's options restricted). It only removes key
  lines the database no longer authorizes and tightens a line whose options
  grant more than the database's: it never adds a line, writes only logins
  that have a file, and
  skips disabled hosts, readonly markers, unsafe `~/.ssh` and linked
  `authorized_keys` files like a normal sync. It clears "revocation pending"
  only when it succeeds completely, and each run is in the activity log as
  `ssm (revocation sync)` with `mode: removal_only`. With `off`, nothing is
  written automatically; the badge stays until a manual sync.

- Diff page: "Remove" on a line marked "not authorized" takes that key off the host
  right away, and "Remove all extra keys" does so for every such line of a login —
  without a full sync. ssm reads the login fresh, removes only lines that are still
  unauthorized (never a granted key or ssm's own key), keeps every other line, and
  writes through the same safe path as a sync; readonly and unsafe logins are refused.
  Each removal is in the activity log with the key fingerprints. Admins and operators
  on hosts in their scope only, never viewers.

- `GET /api/v2/diffs/{host_id}`: every login now has a `notes` list with the notes the
  diff page shows — unsafe files, blocked revocations ("revocation blocked …"), an
  ignored `user_readonly` not owned by root, "drops host restriction: …" and "invalid
  stored options". Each note is `{kind, text, line}`; `kind` is a stable code to switch
  on, `line` names the key line an item note belongs to. Existing fields are unchanged.

- Hosts page (admins): "Managed logins" lists every login ssm keeps writing on a host
  with its number of authorizations, and "Forget" stops managing a login that has no
  authorization and no `authorized_keys` left on the host (ssm checks the host first;
  a login the host cannot resolve, or whose home is missing, is kept).
  The same over the API: `GET /api/v2/hosts/{id}/managed-logins` and
  `DELETE /api/v2/hosts/{id}/managed-logins/{login}` (new error code
  `MANAGED_LOGIN_NOT_FOUND`). Each forget is in the activity log.

### Changed (API)

- **`/api/v2` wire change**, approved by the user 2026-11-08 (AGENTS.md rule 3):
  `POST /diffs/{id}/sync` for a host that is already syncing (diff page,
  "Sync all" or another API call) now answers at once with 409
  `SYNC_RUNNING` and a `Retry-After: 5` header, in the usual error envelope.
  Nothing is read or written on the host and no activity-log entry is made;
  retry after the given seconds. Before, the request waited for the other
  sync and then synced the host a second time. 409 `SSH_READONLY` keeps its
  meaning (partial sync, or a readonly marker refused the sync): clients
  tell the two apart by `error.code`. A sync that is not refused answers
  and is logged exactly as before (actor = token subject).

### Changed

- The removal-only sync is in the activity log as `sync_revocation`,
  `sync_revocation_partial` or `sync_revocation_failed`, so it can be told apart from
  a manual sync (`sync`, `sync_partial`, `sync_failed`, unchanged).
- Splitting or merging SSH users copies only manual authorizations. Grants
  stay with their SSH user; a merged user's grants are deleted with it.
- Deleting an authorization now also marks its host "revocation pending" until
  the next successful sync.
- Activity-log entries of grant reconciles that follow a change in the web UI
  or `/api/v2` name the user who made the change instead of `ssm`.
- Every write that can change authorizations (bulk grant, key assignment,
  split, merge, host delete) takes the database write lock at its start, so
  concurrent writers wait instead of failing.
- Deleting an SSH user, merging it into another, or removing a person through
  Mission Control (offboarding) also deletes the user's grants, also when the
  removal names single hosts: a kept grant would bring the access back. Each
  removal is in the activity log and marks the hosts "revocation pending".
- A scoped account cannot change an SSH user (or its keys) that holds a grant
  reaching beyond the account's scope, because the user's keys would also land
  on future hosts of that grant.
- Upgrading cannot be rolled back with `ecto.rollback` (SQLite cannot drop the
  new `authorization.grant_id` column); restore the backup taken before the
  upgrade instead.
- The host-key icon on the hosts page shows three states with a tooltip each:
  no key pinned (open lock: ssm refuses to connect), a fingerprint set but not
  yet confirmed by a connection (faded), and a key pinned and confirmed.

### Fixed

- `script.sh` login check works on old busybox (1.01, e.g. QNAP): its `tr` ignores octal ranges, so TAB, newline and ESC in a login were not refused there. Every refused byte is now listed on its own.
- Writes wait up to 15 seconds for SQLite's write lock instead of failing with
  "Database busy" after 2 seconds when another write runs at the same time.

- A sync no longer fails with "Directory nonexistent" for a login whose home has no
  `~/.ssh` yet: ssm creates it (mode 0700, owned by the login's user and group) and
  writes the file. It does so only inside a home that exists and is not a symlink,
  and never follows a link planted at `~/.ssh`. A login without a usable home (missing
  or a symlink) is skipped with that reason; the other logins are still written.
- Closing the diff page (or losing the connection) during a sync no longer stops
  the sync half-way without an audit entry: the sync runs on the server, finishes
  and is recorded in the activity log as before.
- A second sync of a host that is already syncing (a double click, a second tab,
  another operator, "Sync all") is refused with "A sync of <host> is already
  running." instead of running twice and losing the first result; "Sync all"
  reports how many hosts it skipped for that reason.
- The hosts page status badge no longer says "unknown" after a restart while
  "checked … ago" shows a recent check: it falls back to the stored key check.
  A host that refuses ssm's key shows "auth failed" and a changed host key
  shows "host key changed" (hosts page and diff viewer) instead of a plain
  "offline"/"error".
- Disabling or re-enabling a host drops its last check result, so a re-enabled
  host starts as "unknown" instead of showing a stale status. Deleting a host
  through `/api/v2` or Mission Control (and the hosts behind a deleted jump
  host) now also clears its cached status, so a later host that reuses the id
  does not inherit it.

- Web pages no longer crash on a malformed id in a click event (users, keys,
  authorizations), and "Load more" in the activity log stops at the newest
  1000 entries.

### Security

- Deleting or moving a manual authorization that a grant also covers (same SSH user,
  host and login) is refused when the grant row that would take its place lacks the
  manual row's restrictions (e.g. `no-pty`, `from=`): before, the grant row replaced it
  silently and the restrictions were gone. Remove the restrictions first (admin-only
  for operators) or delete the grant. API: 409 `CONFLICT`.

- A login's user could block every revocation for their login: in their own `~/.ssh`
  they could rename the root-owned `authorized_keys` that ssm wrote to `user_readonly`,
  which then counted as a root-owned readonly marker and made every sync skip the
  login. A `user_readonly` now counts only inside a `~/.ssh` that root owns and that
  group and others cannot write, and never when it is an ssm-written keyfile. Any
  other root-owned marker is ignored, the login is written, and the diff and the
  activity log show "user_readonly unsafe (tampered?)". To freeze a login on purpose,
  make its `~/.ssh` root-owned (not group/world-writable) and put a root-owned
  `user_readonly` there. This affects released versions up to and including 4.10.0.
- Writing `authorized_keys` now checks after the final rename that the file in place
  is the one ssm wrote ("unsafe (race)" otherwise), and hosts whose `mv` supports
  neither `-T` nor `-h` (old busybox) are refused with "unsafe (no_safe_rename)":
  a plain `mv` could put ssm's file into a directory a user links there at the right
  moment. Other logins of the host are still written.
- Reading `authorized_keys` no longer opens a link swapped in after ssm's checks:
  where perl is available the file is opened with `O_NOFOLLOW` and checked after the
  open (also on FreeBSD); without perl, Linux keeps the `/proc` check and other systems
  now check the file before and after the read.
- The host listing no longer writes a predictable temp file (`$TMPDIR/homedirs.<pid>`)
  as root.
- A new or changed login of an authorization or grant must be a user name: a letter
  or `_` first, then letters, digits, `_`, `.` or `-`, at most 32 characters, an
  optional trailing `$` (upper case is allowed, e.g. `Administrator`), or an SSSD/AD
  login `user@domain` (up to 64 characters before the `@`, a domain such as
  `ad.corp.example`, 128 characters in all). `DOMAIN\user` is refused. A login starting
  with `-` could be read as an option by tools on the host. Existing authorizations
  with other logins keep working and stay editable. On the host, `script.sh` never
  looks up a login that starts with `-`.
- Merging SSH users is refused when their authorizations for the same host and login
  carry different key options ("Not merged: … different key options …", naming each
  login@host). Before, one row was kept silently and the other user's keys got its
  options, which could drop restrictions such as `from` or `no-pty`.
- The scope and admin-only checks of an SSO operator's SSH user changes (edit, delete,
  bulk delete, split, merge, add/move/delete key) and of grant creation now run inside
  the same database transaction as the write, so a change committed in between can no
  longer slip past them.
- The removal-only sync (`SSM_REVOCATION_SYNC=on`) now logs `sync_revocation_failed`
  when it crashes or an SSH call times out, and retries hosts that are still
  "revocation pending" on the periodic check's schedule (`SSM_SYNC_INTERVAL`): one
  interval after the mark, then after 2, 4, … up to 16 intervals.

- `/api/v2` writes are now in the activity log: every successful create, update
  or delete of a host, SSH user, key or authorization records one entry with the
  API user as actor and `via: api` in its details, like the same change made in
  the web UI. Before, only API syncs were recorded.
- "Revocation pending" now covers every change that takes SSH access away, not only
  grants and deleted authorizations: an authorization moved to another host, login or
  SSH user (the old host), an SSH user disabled, deleted, merged away or split (the
  hosts of its grants), a key deleted, moved to another SSH user or given new key
  material, and the authorizations and shared keys removed when a person is offboarded
  through Mission Control. With `SSM_REVOCATION_SYNC=on` each of them also starts the
  removal-only sync.
- Restricting an authorization's options (adding or changing `from`, `command`,
  `restrict`, `expiry-time`, `no-*` and the like, or removing a permissive option)
  now marks its host "revocation pending" too, and the removal-only sync applies it:
  a host line of that key whose options grant more than the database's is replaced
  by the database's line. Before, the host kept the old, wider options until a
  manual full sync.
- SSO operators can no longer widen an existing authorization by deleting its
  restrictions: removing or changing a restriction already on the row (`restrict`,
  `no-*`, `from`, `command`, `permitopen`, `permitlisten`, `expiry-time`, `principals`,
  `verify-required`) is admin-only. Operators may still add restrictions.

- A sync, "Remove key", offboarding through Mission Control and "Forget" of a managed
  login no longer run at the same time on one host: each takes the host's write lock,
  so one cannot undo another's change. Each write also checks that the
  `authorized_keys` is still what ssm read; a file the user changed in between is
  not overwritten — the login is skipped ("changed on the host since it was read").
- ssm refuses every write when it cannot confirm that the login is not an alias of the
  host's SSH user: a host without SSH user, or an SSH user the host does not know.
- Creating a missing `~/.ssh` is refused when the user could swap their home (its
  parent is writable by them); a home with the setgid bit is now handled.
- "Forget" asks the host once more right before deleting the login.
- The removal-only sync (`SSM_REVOCATION_SYNC=on`) now waits for the same host write
  lock as a manual sync, "Remove key", offboarding and "Forget", so it can no longer
  run at the same time as one of them on a host and undo its change. A write that
  takes the lock again inside its own run no longer releases it early.

- An SSO operator can no longer give a key the permissions of an admin's grant by
  moving it: adding, importing or moving a key, splitting or merging users,
  and assigning a diff-page key are refused (and logged) for an SSH user that holds a
  grant with admin-only options. Renaming a key stays possible; admins are unaffected.
- On hosts without `getent` (busybox), ssm now matches a login in `/etc/passwd`
  exactly. Before, a login name containing a `.` (for example `roo.`) could match
  `root` and have ssm read or write root's `authorized_keys`.

- Permissive `authorized_keys` options can be set from the web UI by admins only:
  `environment`, `cert-authority`, `user-rc`, `permitopen`, `permitlisten`, and the
  re-enabling `pty`, `port-forwarding`, `agent-forwarding`, `X11-forwarding`, `tunnel`,
  plus `no-touch-required`. SSO operators may set restrictive options only (`restrict`,
  `no-*`, `from`, `command`, `expiry-time`, `principals`, `verify-required`), in the
  authorization form and in bulk grant; they can still edit the comment of an
  admin's grant but not move it. The `/api/v2` token path is unchanged.

- ssm no longer writes the `authorized_keys` of a login that shares the home of the
  host's SSH login (for example a uid-0 alias such as `toor` in root's home). Such a
  write replaced the file that holds ssm's own key, so a grant for the alias could lock
  ssm out of the host and wipe root's keys. A sync now skips that login with "not
  managed: shares the SSH user's home"; manage the keys under the SSH login instead.

- Editing a key changes only its name, comment and owner; key type and
  material can no longer be changed after creation (UI and API). A new key's
  type must be a known SSH key type, and `POST /api/v2/keys` also checks that
  the material is a key of that type (422 `VALIDATION_FAILED`). Key names are
  limited to 128 and comments to 1024 characters everywhere, as in the API;
  a longer comment from a key import or a host line is cut to 128 characters.
- A host's jump host can no longer form a loop (A via B via A) or a chain of
  more than 16 jump hosts, counting the hosts that already jump through it; a
  loop already stored no longer exhausts memory.
- ssm never sends a host a login it could read as a uid or an option: empty,
  all digits, a leading `+` (`getent passwd +0` is root) or `-`, or one with
  whitespace, `:`, `/` or control characters. A stored login like that is
  skipped by a sync ("invalid login"), the other logins are still written;
  `script.sh` refuses it as well. Before, such a refusal stopped the whole
  host's sync.
- `script.sh` writes the file of the SSH user ssm connects as only for that
  user and only in `$HOME`; any other login that resolves to `$HOME` is
  refused like the shared-home aliases. A login whose home is unknown or not
  an absolute path is refused ("no usable home") instead of being resolved
  against the script's working directory.
- Host listings from a host are checked entry by entry; malformed entries are
  dropped and logged. Remote error output in messages is capped at 500
  characters.
- `probe_ssh` through a jump host refuses loopback names (`localhost`,
  `*.localhost`, `localhost4`, `localhost6`, …) and names that resolve, from
  ssm, to a refused range.
- Host comments refuse control characters and are limited to 1024
  characters. Key comments read from hosts are stored and shown in the
  periodic check without control or bidi characters, at most 200 characters.
  Zero-width characters and bidi marks (U+200B–U+200F, U+2060, U+061C) now
  count as control characters everywhere.
- SSO profile claims: names lose control and bidi characters and are capped
  at 255 characters; an e-mail with control characters or over 320 characters
  is ignored.
- The authorizations CSV export prefixes cells that a spreadsheet would run as
  a formula (`= + - @`) with `'`; malformed filter parameters are ignored
  instead of failing.

### Known limitations

- A grant names an SSH user, not a person or a key. An SSO operator may create an SSH
  user with keys that has no authorization yet; when someone with a wider scope later
  grants that SSH user on a customer or group, those keys reach every host of it.
  Check an SSH user's keys before granting it.

## [4.11.0] - 2026-11-08

### Security

- SSO login fails closed on the scope claims (ADR-0012 phase 1). Operators and
  viewers must bring `orbit_customers` and `orbit_groups` (host groups), each
  exactly `["*"]` or a list of slugs; a missing or malformed claim (also a
  mixed `["*", "x"]`) refuses the login. An `admin` with a restricted scope is
  refused instead of being downgraded. Each refusal is in the activity log
  with its reason.
- Web operators and viewers are limited to the hosts of their customers and
  host groups (ADR-0012 phase 1). Hosts, diffs and sync, authorizations
  (list, matrix, bulk grant, CSV export), the activity log, dashboard counts
  and search show and change only hosts in scope; a host outside it behaves
  like a missing one. Hosts without a customer or group are visible only with
  `*` in that dimension. `.htpasswd` admins, SSO admins, `/api/v2` tokens and
  the Mission Control API stay global.
- A scoped account still sees every SSH user and key, but changes a user or its
  keys (edit, enable/disable, delete, add or import keys, split, merge, bulk
  delete, "Assign unknown key" on the diff page) only when all of that user's
  authorizations are on hosts in its scope; a key change reaches every host of
  the user, and it needs at least one authorization in scope: a user without
  authorizations is read-only until it is authorized on a host in scope. Other
  SSH users are read-only for it. New SSH users can still be created.
- A scoped account cannot change where ssm connects to (address, port, login
  user, pinned host key, jump host) and cannot edit, disable or delete a host
  that other hosts use as their jump host; otherwise it could point a host in
  its scope at another machine and reach it through a sync.
- A jump host that other hosts still use can no longer be deleted from the web
  UI (deleting it also deleted those hosts); remove the dependency first. The
  check and the delete run in one locked transaction, so a host that starts
  using it as a jump host meanwhile is not deleted along with it.

### Added

- `OIDC_GROUPS_CLAIM` (default `orbit_groups`) names the host-group claim.
  `OIDC_GROUPS_DEFAULT=*` lets a missing groups claim count as all groups,
  for identity providers other than Mission Control.
- The operator's host groups are stored next to its customers and
  overwritten at every login.

### Changed

- A scoped account cannot create hosts or run "Pin host keys" (both act
  outside its scope). Only admins set a host's jump host; for other roles the
  field is read-only.
- The activity log records the host of host-bearing entries. A scoped account
  sees the entries of its hosts and its own entries without a host; entries
  written before this release have no host and are shown to global accounts
  only.
- Upgrading ends every open SSO session once, so each operator signs in
  again and gets its scope from the new claims.

## [4.10.0] - 2026-11-08

### Changed

- `/api/v2` wire changes, approved by the user 2026-11-08 (AGENTS.md rule 3):
  - `GET /diffs/{id}` for a host whose key listing cannot be read: 502
    `SSH_CONNECT_FAILED` with the read error. Before, it returned 200 with
    `logins: []`.
  - `POST /diffs/{id}/sync` when root-owned `user_readonly` markers skip
    logins: 409 `SSH_READONLY`. The message names the skipped logins with
    their reason and the logins that were written (partial sync).
  - `POST /diffs/{id}/sync` when ssm's own key (`SSH_KEY`) cannot be read and
    the host's login user is a target: 500 `INTERNAL_ERROR`. Nothing is
    written.
  - `POST /diffs/{id}/sync` when a stored key row has control characters in
    its key: 422 `VALIDATION_FAILED`, and the other lines are written.
    Invalid options and control characters in input fields of
    `/authorizations`, `/keys`, `/users` and `/hosts` also return 422
    `VALIDATION_FAILED`.

### Security

- Fixed root escalations in the host script (`script.sh`), which ssm runs as
  root:
  - Before this fix, a sync wrote through a symlinked or hardlinked
    `authorized_keys`, so a user could make ssm write the user's granted keys
    into root's file. Now a linked `authorized_keys` is never written
    through. ssm writes a new file and renames it into place, which replaces
    the link, so revocation still reaches the login.
  - If `~/.ssh` itself is a link or resolves outside the home, ssm skips the
    login and marks it "revocation blocked: unsafe ~/.ssh" in the diff, the
    periodic check (as drift) and the sync's activity-log entry. The note
    also appears in the login's `read_error` in `GET /api/v2/diffs/{id}`.
  - The backup of a handwritten file used a fixed name. A user could plant
    `authorized_keys.backup` as a symlink to a directory (for example
    `/etc/cron.hourly`), and ssm then moved the user's file there. This bug
    also affected the previous release. The backup now gets a fresh random
    name (`authorized_keys.backup.<random>`).
  - The final rename never follows a link that points to a directory. It uses
    `mv -T` or `mv -h`. On busybox, which has neither, the script first
    removes a symlink at `authorized_keys` (`rm` never follows a link) and
    then renames. If a real directory sits there, ssm skips that login with
    the reason `unsafe: link-to-dir` and still writes the other logins.
  - ssm no longer reads through links, so a link to `/etc/shadow` can no
    longer show up in the diff. Such a login is shown as "unsafe
    authorized_keys (…): not read; a sync replaces it". On Linux the opened
    file is checked again through `/proc`, and every read is time-bounded, so
    a FIFO cannot hang the listing. A read that fails (a link swapped in, a
    timeout) marks only that login as `unsafe: race`, and the listing goes on.
  - The script stops a write if it cannot get 16 random hex digits for its
    temporary and backup file names, so it never uses a predictable name.
- `authorized_keys` is now written atomically. ssm writes a new file next to
  the old one and renames it over the old one. The new file is root-owned with
  mode 0644, which is what the old script produced and what sshd StrictModes
  accepts.
- A `user_readonly` marker counts only if it is a plain root-owned file with
  a single link. Its content is never shown any more; the reason is always
  "user_readonly (root-owned)". A marker that is a link is ignored and shown
  as "user_readonly is a link". `system_readonly` is unchanged.
- Revocation now reaches the host. ssm remembers every login that ever held a
  grant on a host (new table `managed_logins`, filled at upgrade from the
  existing grants). A sync also rewrites such a login after its last grant is
  deleted: if the login still has an `authorized_keys` file, it becomes empty
  (the host's login user keeps only ssm's own key). Readonly markers and
  disabled hosts are respected as before, and no file is ever deleted. Logins
  whose grants were deleted before this upgrade are not covered; check them by
  hand.
- Keys of disabled SSH users are no longer deployed. The next sync removes them,
  and until then the diff and the periodic check show them as "not authorized"
  (drift).
- Grant options (`authorization.options`) are now written to the host, e.g.
  `no-pty,from="10.0.0.0/8" ssh-ed25519 AAAA… laptop`. Before, they were only
  stored. A grant with options replaces the options of the host's line on the
  next sync, and a different options prefix on the host shows as drift. If the
  host line had restrictions the grant lacks (`from`, `command`, `restrict`,
  `no-*`, `permitopen`, `permitlisten`, `expiry-time`, `principals`), the diff
  page marks it "drops host restriction: …"; the sync still writes the grant. A
  grant without options keeps the host's line as before, so options typed by
  hand on the host survive.
- Options are validated in the UI and in `/api/v2` (422 `VALIDATION_FAILED`).
  Only these names are accepted: `restrict`, `no-pty`, `no-port-forwarding`,
  `no-agent-forwarding`, `no-X11-forwarding`, `no-user-rc`, `from`, `command`,
  `permitopen`, `permitlisten`, `environment`, `expiry-time`, `principals`,
  `pty`, `port-forwarding`, `agent-forwarding`, `X11-forwarding`, `user-rc`,
  `no-touch-required`, `verify-required`, `cert-authority`, `tunnel`. Flags take
  no value, and the others need a value in double quotes. Quotes must be
  balanced. Backslashes and control characters are refused, so a value can no
  longer smuggle in a second key.
- Before upgrading, list stored rows that the new rules refuse:
  `bin/ssm eval 'Ssm.Release.invalid_stored_rows() |> IO.inspect()'`. The
  report lists grant options and key fields that contain control characters.
  For a grant with refused options, a sync keeps the host's existing line of
  that key, or skips the key if the host has none. It logs the case, and the
  diff page marks it "invalid stored options". A user merge or split copies
  such options unchanged. A stored key comment with control characters (for
  example a tab, a C1 character or old Latin-1 bytes) is left out: the key is
  written without its comment, and ssm logs it.
- ssm now reads authorized_keys lines the way sshd does. A key type inside a
  quoted option value (e.g. `environment="X= ssh-ed25519 <granted key>"`) no
  longer counts as that granted key or as ssm's own key. A sync replaces such
  a line with the grant's line.
- The host script (`script.sh`) now reports valid JSON in every case. It
  escapes backslashes, quotes, tabs, CRs and other control characters in the
  login, the readonly text and the `authorized_keys` content. It also reports
  whether a readonly marker applies to the whole host (`system_readonly`, a
  vendor platform) or to one login (`user_readonly`), and checks them in the
  order system, platform, user. Bytes that are not valid UTF-8 (for example
  a Latin-1 comment) no longer make a host unreadable: ssm replaces them with
  U+FFFD. Before, the SSH client turned such output into an Erlang term, and
  the whole host failed to read. Keys are still matched by type and key material, so only the shown
  comment changes. The script changed, so ssm uploads the new version to each
  host the next time it connects there, also during a read-only check.
- A host-wide readonly marker (`system_readonly`, a vendor platform) now stops
  a sync before the first write. Before, logins earlier in the order could
  already have been written. A login's own `~/.ssh/user_readonly` now counts
  only if root owns the file, so users can no longer freeze their own login
  and block a revocation. A root-owned `user_readonly` skips only that login:
  all other logins are written. ssm ignores a `user_readonly` owned by anyone
  else and writes the login. The diff page shows it as "ignored: user_readonly
  not owned by root", and the sync's activity-log entry lists it. The sync is then reported as failed and
  names the skipped logins, their marker text and the logins that were
  written (`/api/v2`: 409 `SSH_READONLY`). If such a login still holds keys
  that ssm would remove, the diff page and the periodic check mark them
  "revocation blocked by user_readonly". This note also appears in the Mission
  Control host summary text. A login without an `authorized_keys` file is
  handled the same way: when the host refuses the write as readonly, ssm skips
  that login and syncs the next one.
- Every sync now writes an entry to the activity log, from the UI and from
  `/api/v2`: `sync` when it succeeds, `sync_partial` when it fails after some
  logins were written, and `sync_failed` when nothing was written. Each entry
  holds the actor, the host, the written logins and the skipped logins with
  their reason, the ignored `user_readonly` markers, and the error for a
  failed sync. Before, only a successful UI
  sync was logged.
- A host whose key listing cannot be read no longer looks like an empty host.
  `GET /api/v2/diffs/{id}` returns 502 `SSH_CONNECT_FAILED` with the read
  error instead of 200 with an empty `logins` list, and the diff page shows the
  read error above the list.
- A sync writes nothing when ssm's own key (`SSH_KEY`) cannot be read and the
  host's login user is a target, because ssm would lock itself out. In
  `/api/v2`, this is 500 `INTERNAL_ERROR`.
- ssm now splits key lines on spaces and tabs only, as sshd does.
- Control characters, Unicode line and paragraph separators, bidi controls,
  BOMs and invalid UTF-8 are refused in key names, key extra comments, SSH user
  names and comments, host names and host login users, grant logins and grant
  comments, in the UI and in `/api/v2` (422 `VALIDATION_FAILED`). A pasted
  single key that spans several lines is refused. Before, a line break in a key
  comment could add an extra line to `authorized_keys`.
- A sync never writes a stored key whose key type or key material contains
  control characters. ssm logs the row, writes all other lines and reports the
  sync of that host as failed with the key id. In `/api/v2`, this is 422
  `VALIDATION_FAILED` on `POST /diffs/{id}/sync`.

## [4.9.2] - 2026-11-08

### Added

- Hosts page: "Refresh all (N)" tests the SSH connection of every enabled
  host the current filter lists (after a confirm; disabled hosts are never
  contacted), `SSH_CONCURRENCY` at a time, and shows each result in its row as
  it arrives, then a summary (online/offline). Nothing is written to the hosts.
  Each row also shows "checked … ago" from the last stored key check, or
  "checked just now" after a test on this page.

## [4.9.1] - 2026-11-08

### Changed

- Diff page: opening it no longer connects to any host. Each host shows its
  last stored check (`host_checks`) with its age ("checked 3 h ago" / "never
  checked"); hosts are read over SSH only on an explicit action: "Check" on a
  row, "Check all" (asks first and names how many hosts it contacts), or the
  detail view of one host. Every manual check is stored like the periodic
  check, so a reload shows it without a new connection. "Sync all" re-checks
  only the hosts it synced.
- Diff page with `host_id`: only that host's detail (name, address, last
  check, Check/Sync, the diff) and a "← all hosts" link; no host list and no
  other host is contacted.

### Added

- Diff page: a result filter (needs sync, key not accepted, unreachable /
  timeout, name does not resolve, other errors, never checked, disabled) with
  counts, and a "Key not accepted" notice listing hosts whose last check was
  refused for ssm's key.

## [4.9.0] - 2026-11-08

### Added

- Mission Control can ask ssm whether an address answers SSH as seen from
  ssm (mctl contract 0.5.0, capability `probe_ssh`, `POST
  /api/mctl/v1/probe/ssh`): up to 5 ports, TCP connect and the first line
  only (no login, nothing sent), directly or through one of ssm's hosts as
  jump host (`ssh -W` with the pinned known_hosts of every hop). Loopback,
  link-local, unspecified and multicast targets and ssm's own addresses are
  refused; a disabled or unpinned jump host is refused. 30 probes per minute
  per token; every probe is in the activity log (`probe_ssh`).
### Fixed

- Diff page: a granted key whose line on the host has another comment (or
  an options prefix such as `from="…",no-pty`, or CRLF / trailing blanks)
  is shown once as present. It was listed twice, as "missing on host" and
  "not authorized" ("Allow" then said the grant already exists), because
  whole lines were compared instead of key type + base64. The periodic
  check no longer counts such keys as drift.
- Sync keeps the host's line of a granted key as it is (options and
  comment) instead of replacing it with ssm's line, writes each key once,
  and no longer writes when the host's key files cannot be read first.
- "Allow" and "Assign unknown key" also work for host lines with an
  options prefix.

## [4.8.1] - 2026-11-08

### Fixed

- SSH to an IPv6 address works: an IPv6 literal (e.g. `fdfd:4444:5::6:1`)
  is connected over IPv6 instead of being looked up as an IPv4 name, which
  failed with "the host name does not resolve" (Mission Control onboarding
  of a host by its IPv6 address). A DNS name is tried over IPv4 first and
  over IPv6 when it has no IPv4 record; an unreachable IPv6 address now
  reports "the host is unreachable".
### Added

- Diff page, "Assign unknown key": "Create user" is the default choice.
  It creates the user (name prefilled from the key comment: the part before
  "@" of the last word, e.g. "ot" for "Oliver Tegeler ot@FW13-OT",
  otherwise the comment as a slug), the key and the login grant on this host
  in one step. The key name is editable (prefilled with the key comment),
  also when assigning to an existing user. A taken or empty user name keeps
  the dialog open with the error and saves nothing. The host itself still
  changes only with a later sync.

## [4.8.0] - 2026-11-08

### Added

- mctl contract 0.4.0 `delete_customer` (`DELETE /api/mctl/v1/customers/{slug}`):
  Mission Control can delete a customer without hosts; a customer that
  still has hosts answers 409 and no host is moved. Logged as
  `customer_delete`. mctl_contract vendored at v0.4.0.

### Changed

- Build: one source for the Elixir/OTP versions, `.tool-versions`. a test (`test/tool_versions_test.exs`) fails when the Dockerfile ARGs drift from it.

### Fixed

- Open popovers (theme switcher, mobile menu) and expanded activity details
  stay open when the page re-renders (e.g. the activity list refresh).


## [4.7.0] - 2026-11-08

### Added

- mctl contract 0.3.0 `delete_group` (`DELETE /api/mctl/v1/groups/{slug}`):
  Mission Control can delete a group no host carries any more; a group
  still in use answers 409 and no host loses it. Logged as `group_delete`.
  mctl_contract vendored at v0.3.0.

## [4.6.0] - 2026-11-07

### Added

- **Merge customers from Mission Control** (mctl contract 0.2.0, capability
  `merge_customer`): `POST /api/mctl/v1/customers/{slug}/merge` with
  `{"into": "<slug>"}` moves every host of the customer to the target and
  deletes the customer, in one transaction. The activity log records it as
  `customer_merge` (type host, target `customer:<slug>`). Unknown slugs, or a
  repeat after success, answer 404.

## [4.5.2] - 2026-11-07

### Added

- **More than one name for the web UI**: `PHX_ALT_HOSTS` (comma-separated)
  lists further host names ssm is served under, e.g. a NetBird name next to
  the public `PHX_HOST`. LiveView accepts those origins, and single sign-on
  started on such a name returns to it (callback and post-logout sign-in
  page), so the login no longer fails for lack of the session cookie. Other
  host names still get the `PHX_HOST` URLs.

### Changed

- Releases publish the GitHub Container Registry image as
  `ghcr.io/styliteag/ssm` (was the nested `ghcr.io/styliteag/ssm/ssm`, which
  keeps its released tags). Docker Hub (`styliteag/ssm`) is unchanged.

## [4.5.0] - 2026-11-07

### Added

- **Mission Control can rename groups**: `PATCH /api/mctl/v1/groups/{slug}`
  with `{"name": …}` changes the display name of a host group (scope
  `setup`); the slug stays. Unknown groups answer 404, an empty or overlong
  name 422, the same name twice is fine. `/me` lists the new capability
  `rename_group`. Customer rename (`PATCH /customers/{slug}`) already
  existed and is now covered by the shared conformance tests too.
- **Security log for CrowdSec**: one JSON line on stdout per failed web or
  `/api/v2/auth/login` password, login-throttle lock, invalid refresh
  token, refused single sign-on callback or back-channel logout, and bad or
  throttled mctl contract token:
  `{"type":"auth_failure","app":"ssm","ts":…,"ip":…,"reason":…,"path":…}`
  (reasons `bad_password`, `bad_token`, `locked`, `oidc_failed`), with the
  real client IP (`TRUSTED_PROXIES`) and never a username, password or
  token. The line bypasses the normal log format, so it always starts with
  `{"type":"auth_failure"`.
- **Mission Control can delete hosts and offboard people**: `DELETE /api/mctl/v1/hosts/{id}` deletes the host with its authorizations (keys on the host itself are not touched — it may already be gone) and answers a finished `delete_host` job; a jump host that other hosts still use is refused with `409`. `GET /api/mctl/v1/people/{key}` (key `oidc:<issuer>|<subject>` or `email:<address>`) shows what ssm knows about a person: the SSO operator, the SSH users named like the person's e-mail with their keys and authorizations, and keys of other users whose comment is that e-mail — as SHA256 fingerprints and comments, never key material. `POST /api/mctl/v1/people/{key}/remove` (scope `commands`) deletes those authorizations (and the shared keys), removes exactly the person's key lines from `authorized_keys` on every host (or the given `hosts`; readonly logins and disabled hosts are reported, never written) and disables the operator; the `remove_person` job reports per host whether it worked. `/me` lists the capabilities `delete_host` and `people`. `/api/v2` is unchanged.
- **Sign-out at the SSO provider (RP-initiated logout)**: when an SSO user signs out of ssm, the local session ends as before and the browser is then sent to the provider's `end_session_endpoint` (if its discovery document has one) with `client_id`, `post_logout_redirect_uri` (ssm's sign-in page) and, when available, `id_token_hint`, so the provider session ends too. The logout request also carries a random `state`. The ID token for the hint is kept encrypted in the session cookie (up to 1500 bytes) or, when larger, in server memory until sign-out or the session maximum; it is never logged. Set `OIDC_RP_LOGOUT=false` (also `0`, `off`, `no`) to keep the old behaviour; default is on. Without an `end_session_endpoint`, or if the provider cannot be read, sign-out goes to the sign-in page as before. `.htpasswd` users are unaffected.
- **"Connect Mission Control" in the UI**: admins get a new page Setup → API tokens (`/settings/api-tokens`, visible to admins only) that creates the service token `mission-control` with the chosen scopes (`read`, `setup`, `commands`). The token is shown once, together with ssm's public URL and a ready-to-paste entry for Mission Control's `MCTL_CONNECTORS_FILE`; the page shows status (prefix, scopes, last use and IP) and offers rotate and revoke. Creating, rotating and revoking are in the activity log (`mctl.connect.create`, `.rotate`, `.revoke`, never the token). The token set by `MCTL_TOKEN_FILE` (`mission-control-env`) is a separate token and stays untouched.
- **Hosts with a non-root login are marked "limited"**: ssm does not use sudo, so when it logs in as another user than `root` it only sees and manages the `authorized_keys` files that user can access (usually only its own). The Hosts page shows a "limited" badge with this explanation next to the login (list and cards), and the host form says so when the login is not `root`. The mctl API reports it as read-only host attributes `limited` and `limited_reason`, and the `create_host` job result carries `limited`.
- **Mission Control can install ssm's key on new hosts**: the `create_host` job of `POST /api/mctl/v1/hosts` now puts `ssm_public_key` (the public key ssm logs in with, derived from `SSH_KEY`) and `username` into the job result right away, while the job is still `running`. The job then retries the SSH login with growing pauses (2 s up to 30 s) for up to 10 minutes until that key is authorized on the host, then pins the host key as before. A pre-seeded `attributes.key_fingerprint` (e.g. from the dashboard agent) is checked on every attempt; a different host key fails the job at once with `host_key_changed`. If the login still fails after 10 minutes the job fails with `auth_failed` and a message naming the login user; if ssm's own key cannot be read it fails with `ssm_key_unavailable`. Other connection errors fail at once as before.
- **Jump host by name when adding hosts through Mission Control**: `POST /api/mctl/v1/hosts` now accepts `attributes.jump_via` as an existing ssm host's id or name (an unknown host is `422` with `attributes.jump_via: ["no such ssm host"]`), and `attributes.username` is checked with the same login-name rules as the Hosts page (default `root`).
- **Periodic key check and host summaries for Mission Control**: ssm now checks every enabled host's `authorized_keys` against the database on its own, every `SSM_SYNC_INTERVAL` (default `15m`; seconds, `Nm` or `Nh`, at least 10 s; `0` or `off` disables), with at most `SSM_SYNC_CONCURRENCY` (default 8) hosts at once. The interval is jittered by 10 % and the first run starts at a random moment within a minute of boot. The result per host is stored (new table `host_checks`: state, per-user drift with key type, fingerprint and comment but never key material, error, checked and last-changed time) and also fills the Diff Viewer's status, so the page no longer starts from nothing after a restart. `GET /api/mctl/v1/host-summaries` and `/hosts/{id}/summary` report it: keys in sync is `ok`, drift is `warn` with one item per user and login, an unreachable host or failed read is `crit` (fixed sentence, no addresses), a disabled or never checked host is `unknown`. `GET /api/mctl/v1/me` lists the new capability `host_summaries`. `/api/v2` is unchanged. The Diff Viewer now shows an unreachable host with no authorizations as an error instead of "in sync".
- **Mission control API (`/api/mctl/v1`)**: ssm now speaks the shared mctl contract v1 — hosts with customer, groups and their pinned SSH host key as identity, customers and groups, and `POST /hosts` as a job that adds the host and pins its key. Access uses `ssm_` service tokens with scopes (only the SHA-256 is stored); set `MCTL_TOKEN_FILE` (and optionally `MCTL_TOKEN_SCOPES`) to install the `mission-control` token at boot. The existing `/api/v2` and its envelope are unchanged.
- **`TRUSTED_PROXIES`**: comma-separated addresses/CIDRs of reverse proxies in front of ssm. For requests from them, the client IP is taken from `X-Forwarded-For` (used for the mctl token's last-used IP and the failed-login limit of the mctl API); unset, the header is ignored.
- **Customers and host groups**: new `customers`, `groups` and `host_groups` tables; hosts carry a customer, groups and `inserted_at`/`updated_at` (existing hosts are stamped with the upgrade time).
- **"Pin host keys" on the Hosts page**: connects once to every enabled host without a fully pinned key, jump hosts first, and lists the hosts that failed. A pinned host shows a fingerprint icon next to its name.
- **Single sign-on (OIDC) for the web UI**: set `OIDC_ISSUER`, `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET_FILE` and the sign-in page shows a "Login with SSO" button (`OIDC_LOGIN_LABEL`). Authorization Code flow with PKCE; the ID token is fully validated and no token is kept. The suite role claim (`OIDC_ROLE_CLAIM`, default `orbit_role`) maps to a new per-user role: `admin` and `operator` keep today's full access, `viewer` is read-only (every write action in the UI is refused centrally; the page shows "Your account is read-only."). The suite role `customer` is refused. Without the claim, `OIDC_ROLE_MAP` (`group=role,...`) maps the `groups` claim. SSO users are stored in a new `operators` table keyed by issuer and subject (never matched by name or e-mail with a `.htpasswd` user); name, e-mail, role and customers are refreshed at every login, an operator disabled in ssm stays refused. Sessions last at most `OIDC_SESSION_MAX_HOURS` (8) and end at once on OIDC back-channel logout (`POST /auth/oidc/backchannel-logout`, signed `logout_token`, replay-protected). Logins, refusals (reason code only) and back-channel logouts are in the activity log. `.htpasswd` users are local admins and keep working; `LOCAL_LOGIN` (`on` / `admins_only` / `off`) can hide the local form once SSO works (`off` without working SSO is treated as `admins_only`). The `/api/v2` bearer API and its tokens are unchanged. Adds the `oidcc` library (and its `jose` dependency).
- **Machine identity for Mission Control**: ssm now reads each host's machine id over SSH (`/etc/machine-id` on Linux, `kern.hostuuid` on FreeBSD; fixed command) when a host is added or its key is pinned and after every successful key sync, and stores only a keyed hash of it (new nullable column `host.machine_id`). The hash is reported as `identity.machine_id` in the mctl API, so the same machine is recognised across ssm, the monitoring and the dashboard. The raw id is never stored or logged; if reading fails the previous value stays. `identity.ssh_host_keys` always uses the `<type> SHA256:<fingerprint>` form (a legacy bare pin is reported typed when the full key is stored, otherwise omitted).

### Changed

- `release.sh` (`just release`) accepts an explicit version `X.Y.Z` above the
  current one, for the suite-wide 4.5.0.
- **Viewers no longer see write buttons**: for an SSO `viewer` the pages hide every control that would only answer "Your account is read-only." (new, edit, delete, sync, bulk actions, …); the authorization matrix still shows who is authorized but cannot be clicked. The list comes from the same allow-list as the server-side refusal, which stays in place.
- **A rotated provider key no longer breaks back-channel logout**: a `logout_token` signed with a key id ssm has not seen makes ssm re-fetch the provider's keys, as the SSO login already did — at most once a minute for the whole app.

### Fixed

- mctl_contract is vendored (v0.1.0 in `vendor/mctl_contract`, copied by
  `mctl_contract/scripts/vendor.sh`): CI, Docker builds and plain checkouts no
  longer need the library next to the repo. `MCTL_CONTRACT_PATH` points at a
  checkout while working on the library. A test checks the copy against the
  hash in `VENDORED` and, where a mctl_contract checkout is next to the repo,
  that it is the newest tag.
- **ssm no longer locks itself out of hosts added through Mission Control**: its own key in the login user's `authorized_keys` is never shown as drift and every sync keeps it (matched by key type and body), so the first sync no longer removes it (lab e2e B3).
- **Single sign-on comes back on its own** when the identity provider was down while ssm started: the provider configuration is retried with backoff instead of staying unavailable until a restart (B13).
- **`TRUSTED_PROXIES` also matches IPv4-mapped IPv6 peers** (`::ffff:a.b.c.d`), so failed-login limits and the security log see the real client IP behind the proxy (B5).
- **Mission Control: deleting a host while it is being added** now ends its `create_host` job as `failed` with the code `host_deleted` instead of crashing the job (the code was `not_found` when the host was gone before the job started).
- **SSH key added after start is picked up**: the key set in `SSH_KEY` is re-read on every new connection when the file changes, so creating or replacing it no longer needs a restart (previously: `auth_failed` until restart).
- **Failed host creation via the mctl API leaves nothing behind**: when the `create_host` job fails (e.g. key rejected), the half-created host is removed, so the same request can be sent again. A duplicate name or address now returns `409 conflict` with `details` naming the field (`{"name": ["already exists"]}` / `{"address": [...]}`) instead of a bare 409.
- **The changelog no longer ends in leftover tool output**: the file's tail carried a stray XML fragment and a "Note to self" session recap from the era it was first written. Since the release workflow lifts each version's section straight into the GitHub release body, that residue was operator-visible — it is gone, together with the empty `### Added` stubs the old release script seeded into releases that recorded nothing. The maintenance notes now name `./release.sh` as what rotates `[Unreleased]`, instead of describing the manual edit it replaced, and the three `2025-09-XX` placeholder dates (0.2.10–0.2.12) are the actual release dates recovered from their git tags.
- **Development checkouts no longer grow by ~12 GB**: daisyUI is vendored (`phoenix/assets/vendor/daisyui.js`, `daisyui-theme.js`, v5.5.20) instead of a Mix git dependency, so `mix deps.get` never clones the daisyUI repository.

### Security

- **Offboarding through Mission Control trusts only verified e-mail addresses**: ssm now stores whether an SSO user's e-mail was verified by the identity provider (`email_verified`) and keeps the e-mail of the first verified login as the user's offboarding address; a later change of the e-mail claim does not move it. `GET /api/mctl/v1/people/{key}` for an `oidc:` key matches SSH users and keys only by that address, so nobody can get a colleague's keys removed by changing their own e-mail at the provider. An `email:` key that is the verified address of several SSO users is refused (`409`, use the `oidc:` key). The answer lists the matched addresses and, per key and authorization, why it matched. Shared keys (keys of other SSH users whose comment is the person's e-mail) are deleted from ssm only after they were removed from every host; until then the `remove_person` job reports them as `pending_keys` and the next removal finishes them, and a removal limited to `hosts` leaves them in place and reports them as `kept_shared_keys`. New columns `operators.email_verified` and `operators.verified_email`.
- **`LOCAL_LOGIN=off` now also covers the API and fails safe**: `POST /api/v2/auth/login` and `/api/v2/auth/refresh` refuse `.htpasswd` credentials with the usual `401 INVALID_CREDENTIALS` (`on` and `admins_only` are unchanged; already issued access tokens keep working until they expire). While the SSO provider's configuration is not loaded (provider unreachable), `off` behaves as `admins_only`, so nobody is locked out. `LOCAL_LOGIN` is case-insensitive; an invalid value logs an error and means `admins_only`. SSO ID tokens whose `iat` is older than 10 minutes or more than 2 minutes ahead are refused, and an unknown signing key id triggers at most one provider key refresh per minute.
- **SSO sessions are re-checked while a page is open**: an open page now ends at the session's absolute expiry and, every 60 seconds, when the operator was disabled, their role changed, their sessions were revoked or their session was ended by back-channel logout; disabling an operator or changing the role at login also disconnects open pages at once. A back-channel logout that names only a `sid` ends exactly that session (not just the latest one). Back-channel logout has its own, higher rate limit, separate from the SSO login limit. With `LOCAL_LOGIN=off`, existing local sessions stop working (still `admins_only` when SSO is off). The activity log writes SSO users as `name (oidc:<id>)` so they cannot be mistaken for `.htpasswd` users. Viewers can no longer trigger diff re-checks or refreshes, and the Diff Viewer shows them only the cached status (no SSH connection is opened for them, not even through a `?host_id=` link).
- **Password logins now have a failed-login limit**: the sign-in form and `POST /api/v2/auth/login` count failed attempts per client IP (IPv6: its /64, real client IP via `TRUSTED_PROXIES`) and per username (case-insensitive; unknown names count too, so nothing reveals which users exist). After 5 failures within 15 minutes that IP or username is locked until the window ends: the form shows "Too many failed attempts, try again later", the API answers `429` with the new error code `RATE_LIMITED` in the usual envelope plus `Retry-After`; the password is not checked while locked. A successful login resets the username's counter only. Locks appear in the activity log (`login_locked`, never with a password). Tune with `config :ssm, :login_limits, failures: 5, window: 900`. Note: because usernames are limited too, someone who knows a username can keep that account locked out of password login (existing sessions and tokens are unaffected).
- **Host username and address can no longer smuggle ssh options**: both end up on the command line of the local `ssh` process used for jump-host chains, so a username like `-oProxyCommand=…` could run commands on the ssm server for anyone able to edit hosts (UI or `/api/v2`). Usernames must now be login names (letters, digits, `.`, `_`, `-`, not starting with `-`, at most 32 characters) and addresses a hostname or IP address; the ssh call additionally passes the user as `-l` and ends its options with `--`. Existing hosts that break the rule still load and show in the UI, but ssm refuses to connect to them (and to hosts behind them) with an error naming the field until the record is fixed.
- **Mission control API is throttled and audited**: repeated failed token authentication at `/api/mctl/v1` blocks the client (IPv6: its /64) for the rest of a 5-minute window (10 bad tokens, then `429` with `Retry-After`); requests without any token are not counted. Each token is limited to 600 requests per minute, and failed attempts appear in the activity log (`mctl_auth_failed` / `mctl_auth_locked`, without the token). Malformed JSON there gets the API's own `400 bad_request` answer. Failed `create_host` jobs report short error codes (`connect_refused`, `timeout`, `unreachable`, `host_key_changed`, …); the raw SSH detail is only in the server log. When `X-Forwarded-For` arrives but `TRUSTED_PROXIES` is unset, ssm logs a warning once.
- **SSH host keys are verified (ADR-0008)**: ssm no longer accepts any host key. Every connection checks the server's key against the host's pinned `key_fingerprint` before authenticating; a different key is refused with an error naming both fingerprints ("host key changed"), and hosts without a pinned key are refused until they are pinned. Jump hosts are verified too: the OpenSSH forwarder gets a generated `known_hosts` with the hops' pinned keys and `StrictHostKeyChecking yes` (previously `no` with `/dev/null`). Fingerprints kept from the Rust era (bare `SHA256:…`) are honoured as pins. **After upgrading, run "Pin host keys" once** — until then, unpinned hosts (and hosts behind jump hosts whose full key is not stored yet) cannot be reached. A host key fingerprint set through the API or a pasted `ssh-keygen -l` line is normalised; other values are rejected.
- **Web server and framework libraries patched against 22 published advisories**: Bandit 1.12.4 → 1.14.1 (16 advisories, most of them HIGH: HTTP/1.1 request smuggling via chunk extensions, HTTP/2 and WebSocket memory/CPU exhaustion, client-chosen `conn.host`), together with its transport layer (Thousand Island 1.6.0, HPAX 1.1.0); Phoenix LiveView 1.2.13 (open redirect in `validate_local_url!/2`), Phoenix.HTML 4.4.0 (attribute injection), Plug.Crypto 2.2.1 (secret key base in stack traces), Ecto 3.14.3 (unbounded query cache), Decimal 3.2.0 (unbounded allocation in `round/3`), and the test-only lazy_html 0.1.13. `mix hex.audit` and the OSV database report no known advisory for the locked versions. `THIRD-PARTY-LICENSES.md` and `sbom.cdx.json` carry the new versions; the SBOM's own version field, which still said 1.1.11, now matches the release.
- **The GitLeaks CI scan is green again**: the reviewed allowlist now also covers retired material still present in repository history, so the job no longer carries a permanent error annotation and a genuinely new finding stands out instead of drowning in a known one.

## [2.0.1] - 2026-07-30

### Fixed
- **LiveView pages work behind a TLS-terminating reverse proxy**: the socket origin check compared the browser's `Origin` against the container's own scheme and port, which never match once a proxy terminates HTTPS — the log filled with `Could not check origin for Phoenix.Socket transport`, the UI silently degraded to long-polling and reconnected in a loop. Setting `PHX_HOST` to the public hostname now switches the check to a hostname comparison; deployments without `PHX_HOST` (reached by IP or LAN name) keep the previous behaviour. Reverse-proxy operators must set `PHX_HOST` — see the commented example in `docker/compose.yml`.

### Removed
- **Dead editor/tooling configs**: the unused Spec-Kit machinery (`.specify/`, the `/specify`-family commands in `.claude/commands/`), Cursor configs (`.cursor/`, `.cursorrules`, and the typo'd `.cursrorules`), `.grok/`, `.opencode.json`, four orphaned knowledge-graph skill notes in `.claude/skills/`, the broken `.envrc` (`use flake` without a `flake.nix` — a Rust-era leftover), `.mcp.json`, and the historical python rewrite plan (`plans/`). Kept: `.claude/settings.json` (code-review-graph hooks) and the `release`/`ship`/`verify` skills.

### Changed
- **`CLAUDE.md` is now a one-line `@AGENTS.md` import instead of a symlink** — the officially recommended, Windows-friendly way to share one agent-instruction file; editors no longer show two identical full files.

### Security
- **GitLeaks in CI actually scans now**: the `gitleaks-action` wrapper had errored softly on every run for lack of an organization license — replaced with the plain (MIT) gitleaks CLI, pinned, full-history. A reviewed `.gitleaks.toml` allowlists known fake test fixtures and documented example values. Also bumped the workflow's deprecated actions (checkout@v5, codeql upload-sarif@v4).

## [2.0.0] - 2026-07-30

### Removed
- **The Python/FastAPI backend and React frontend are gone**: the Elixir/Phoenix stack is now the only application. Deleted: `backend/` (FastAPI, SQLAlchemy, Alembic, pytest suite), `frontend/` (React SPA), the combined nginx+uvicorn Docker image (`docker/app/`), the python-era dev scripts (`start-dev.sh`, `kill-ports.sh`), stale docs describing the old stacks (`docs/API.md`, `DESIGN.md`, `IMPROVEMENT_PLAN.md`, the Postman collection), and the old-stack SBOMs. The final snapshot of the python stack's database is kept at `./ssm.db` as the dev-DB import source.

### Changed
- **Production Docker deployment now builds the Elixir image** (`docker/compose.yml` → `phoenix/Dockerfile`) — the CI release workflow publishes it too. The data volumes are unchanged (`docker/data/{db,config,keys,logs}` mounted at `/app/{db,config,keys,logs}`): the Elixir image keeps the previous image's mount contract and adopts the existing database in place, so operators keep their data without any migration step. The environment keeps working too (`DATABASE_URL`, `HTPASSWD`, `SSH_KEY`, `JWT_SECRET`/`SESSION_KEY`, `LOGLEVEL`).
- **Simpler `just` commands**: the `elixir-` prefix is gone — `just dev`, `just test`, `just verify`, `just mix <task>`, `just import-db` (the aggregate `verify` gate is now the Elixir `mix precommit`). `just up`/`down`/`logs`/`ps` drive the production compose file; `just docker-build`/`docker-run` exercise the production image locally. `release.sh` no longer bumps python files and verifies the Elixir stack instead.
- **Dev container now mounts `phoenix/keys/`** (was `backend/keys/`) — the SSH key moved with the stack; drop your key at `phoenix/keys/id_ssm`.
- **GitHub releases now carry the real release notes**: the release workflow extracts the version's section from `CHANGELOG.md` into the release body (previously a boilerplate stub with only the image names). Manual workflow re-runs now build the given tag instead of the default branch, and the workflow's actions were bumped to current majors.
- **Production image carries complete OCI labels**: description, url, license (`BUSL-1.1`), and vendor joined the existing title/version/revision/source labels, with defaults so locally built images are label-complete too.
- **`release.sh` leaves a bare `[Unreleased]` section** after rotating the changelog instead of seeding an empty `- ` bullet that could leak into the next release.
- **Diff viewer remembers results and dead hosts fail fast**: sync statuses are cached server-side — revisiting the page shows the last known badges instantly (parity with the React app, which kept them in browser state) and only missing or stale results (older than 5 minutes) are re-checked; a new "Re-check all" button forces a full sweep. Connects also got their own budget: `SSH_CONNECT_TIMEOUT` (default 10s) bounds TCP+handshake, so dead or firewalled hosts no longer hold a check slot for the full `SSH_TIMEOUT` (120s).
- **Host checks run massively parallel and the fan-out is configurable**: the diff viewer's status sweep now checks up to `SSH_CONCURRENCY` hosts at once (new env var, default 32). To make that parallelism real, the SSH connection registry no longer performs handshakes itself — connects (and jump-host forwarder readiness waits) moved into the calling process, so one dead host timing out (up to `SSH_TIMEOUT`, default 120s) no longer stalls every other connection behind it. When two operations race to connect the same host, one connection wins and the other is closed.

### Fixed
- **SSH Keys "host access" counted deleted hosts**: the per-owner host count included grants whose host row is gone (orphans inherited from Diesel-era databases); those are skipped now.
- **Assigning an unknown key without picking a user** ended the LiveView session instead of showing an error; it now says what is missing.
- **Key type badge wrapped and clipped**: long key types (`ssh-ed25519`) broke onto two lines inside the fixed-height badge on the SSH Keys page and got cut off; the badge no longer wraps.
- **Diff viewer showed "checking…" on every host until the slowest one answered**: per-host sync statuses were collected in one all-or-nothing batch, so with a large fleet and a few dead hosts (120s SSH timeout each) no badge appeared for minutes. Results now stream in per host as each check finishes, and up to 8 checks run concurrently (previously 4).
- **Elixir dev server could not reach any host**: the dev container only mounted `phoenix/`, so the SSH key the app expects at `keys/id_ssm` was invisible and every SSH operation failed with `ssh.key_unreadable`. The compose file now mounts the key directory (`phoenix/keys/`) read-only into the container.

### Added
- **Operator upgrade guide** (`docs/UPGRADING.md`): what changes when switching a production deployment from the `1.1.x` python/react image to the Elixir image — TL;DR: bump the image tag; volumes, `DATABASE_URL` (both old forms), `HTPASSWD`, `SESSION_KEY`/`JWT_SECRET`, `SSH_KEY`, port 80, and the `/api/v2` wire format all keep working. Covers the pre-upgrade DB backup, Traefik/WebSocket notes, behavior changes (7-day web sessions), and the rollback path (adoption is non-destructive).
- **License attribution and SBOM regenerate from the shipped Elixir deps**: `just notices` rebuilds `THIRD-PARTY-LICENSES.md` and a CycloneDX 1.6 `sbom.cdx.json` from the phoenix release's runtime dependencies (hex + git deps + the vendored topbar.js) — the file previously still listed the removed python/react dependencies. Dev/test-only tooling is excluded. Ported from the dashboard-open generator.
- **Justfile conveniences**: `just sh` / `just iex` (shell/IEx in the dev container), `just migration <name>` / `just migrate` / `just rollback` (Ecto migration workflow), and an optional gitignored `local.just` for checkout-specific recipes.
- **Card views for hosts, users, and SSH keys**: every list page now has a List/Cards toggle (list stays the default). Host cards show address, status badge, login, jump host, and the grant-count link; user cards keep the selection checkbox for merge/bulk-delete plus key/grant links; key cards show owner, type badge, truncated material, and host access. All row actions (test, edit, delete, split, copy, view, …) are available on the cards too.
- **Diff viewer list view (the default)**: next to the card grid there is now a table view (toggle top-left, choice kept in the URL) with sortable Name / Address / Status / Differences columns, a name-or-address search, the difference count per host, and per-row actions — re-check one host or sync it (with confirmation) without opening its detail first. Clicking a row opens the per-login diff as before.
- **Sortable columns on every list**: hosts, users, SSH keys, and the authorizations list all sort by clicking a column header (click again to flip direction; the header shows the active sort arrow).
- **Authorizations page overhaul**: the list gained stat cards (total / active / inactive / distinct users / distinct hosts), a free-text search across user, host, login, options, and comment, and cross-links everywhere — user and host names filter the list in place, with shortcut icons to the user's keys and the host's diff view. The matrix got the old frontend's look back: user and host search fields, slanted host headers, a sticky user column, compact ✓/✗ cells (names link to the grant list and the diff viewer). The bulk-grant dialog is wider, has per-column search with live selected counts, and a clearer new/existing preview.
- **Hosts page: online/offline status and cross-links**: each host row shows an online/offline/unknown badge (fed from the diff viewer's status cache and from this page's own connection tests — a successful test flips the badge to online immediately, a failure shows offline with the error in the tooltip), status filter pills with counts (Active — the default —, All, Online, Offline, Unknown, Disabled), an authorization count linking to the authorizations page filtered to that host, and a per-host shortcut into the diff viewer.
- **Elixir stack: theme system and production image**: the Phoenix app gained a theme picker (four designs — Orbit, Bench, Soft, Rainbow — each in light and dark, selectable from the sidebar and already active on the sign-in page; choices persist in year-long cookies, and stale cookies from removed themes fall back safely) and a production Dockerfile (`phoenix/Dockerfile`): an Elixir release image that keeps the previous image's operational contract — plain HTTP on :80 (TLS stays at the operator's proxy; `force_ssl` removed for LAN parity), volumes at `/app/db` `/app/config` `/app/keys` `/app/logs`, database migrations applied on start (`Ssm.Release.migrate` — the baseline migration adopts Diesel- and Alembic-era databases in place), `/api/health` healthcheck, OCI image labels, and `openssh-client` in the runtime for jump-host chains and boot-time key decryption.
- **Elixir stack ships the `/api/v2` JSON API** (rewrite plan §7, default "keep"): the python API's full surface reimplemented wire-compatibly in Phoenix — bearer JWT auth (`auth/login`, `auth/refresh`, `auth/logout`, `auth/me`) with the same HS256 signing secret (`JWT_SECRET`/`SESSION_KEY`), claims, and 15-minute/7-day TTLs, so existing API clients and tokens keep working across a cutover; CRUD for `hosts`, `users`, `keys`, `authorizations` with the same field constraints, envelope (`{success, data, error{code, message, details}, meta}`), stable error codes (401 `AUTH_REQUIRED`/`INVALID_CREDENTIALS`, 404 `*_NOT_FOUND`, 409 `CONFLICT`/`HOST_DISABLED`/`SSH_READONLY`, 422 `VALIDATION_FAILED`, 502 `SSH_CONNECT_FAILED`) and semantics (`jump_via` existence/self-jump checks, `?user_id=`/`?host_id=` filters, `{"deleted_id"}` delete payloads); paginated `activity-log`; `info` (version + alembic revision of an adopted database); and `diffs/{host_id}` + `diffs/{host_id}/sync` backed by the same diff engine as the LiveView page, honoring disabled-host and readonly guards. The JWT layer runs on OTP `:crypto` directly — no new dependency. 24 ExUnit contract tests mirror the pytest suite's assertions. Container port parity is in place as well (the Phoenix image listens on :80 like today's image). The scheduler sweeps remain unrestored by design: the python scheduler is vestigial (its env vars are read but never wired to jobs), and restoring the documented behavior needs explicit sign-off (plan §8).
- **Elixir LiveView UI reaches React feature parity**: the remaining React-only tooling is now in the Phoenix app. Users page: rows are selectable with merge (into an existing or a brand-new user; keys move, authorizations are copied with duplicates skipped, sources deleted — all in one transaction) and bulk delete (impact summary of users/keys/authorizations before confirming), plus a per-user split action that moves chosen keys to a new user and copies the authorizations. SSH Keys page: stats bar, type filter pills, free-text search, paste-to-parse add modal (the pasted authorized_keys line is validated against the SSH wire format and the comment becomes the name), multi-line bulk import with a per-line success/error report, and copy-to-clipboard for full key lines. Authorizations page: three views — the list (now with CSV export matching the React columns, downloadable under the active filters), the matrix (users × hosts per login account with usage-sorted selector, root-or-most-used default, view-only "all" counts mode, show-authorized-only toggle, and click-to-grant/revoke cells), and a stats view (totals plus hosts-by-user-access and users-by-host-access rankings); a bulk-grant modal grants a login across a users × hosts selection, skipping pairs already granted, with a live new/existing preview. Diff viewer: an unauthorized key on a host can now be legitimized from the diff — keys of known users get an "Allow" button that grants the login, unknown keys can be assigned to a user (granting the login too); both are database-only changes, the host stays untouched until the next sync. Activities page: free-text search across action/target/actor and structured detail rendering (old→new change chips, summary chips, JSON fallback). Dashboard: version pill showing app version and applied schema revision. New host form pre-fills the SSH login with root. Grants whose user or host row was deleted in a legacy Diesel-era database render as "missing" markers instead of crashing the page. All mutations are audit-logged; ~60 new ExUnit tests cover the ported features.
- **Elixir dev server imports your existing data**: `just dev` now snapshots the repo-root `ssm.db` (the python stack's database) into `phoenix/ssm_dev.db` on first start — previously the Elixir dev server came up with an empty database. The copy uses SQLite's transaction-safe `.backup`, never writes to the source, and only runs when the dev DB has no hosts yet; `just import-db` forces a fresh snapshot at any time.
- **Elixir/Phoenix rewrite groundwork (branch `elixir-rewrite`)**: rewrite plan at `docs/elixir-phoenix-rewrite.md` and a new `phoenix/` app (Phoenix 1.8 + LiveView, SQLite via `ecto_sqlite3`) scaffolded alongside the existing stack, with a docker-only dev toolchain (`phoenix/compose.yml`, port 4000). The Elixir app reads the same environment variables as the Python stack (`DATABASE_URL`, `HTPASSWD`, `SSH_*`, `JWT_SECRET`/`SESSION_KEY`, `LOGLEVEL`, `PORT`, `LISTEN`) and takes its version from the repo-root `VERSION` file. No user-visible behavior changes; the Python/React stack remained the production app during the transition (it has since been removed — see the top of this section). The Elixir stack adopts the existing SQLite database in place: a baseline migration recreates the Alembic-head schema idempotently (fresh DBs get the full schema; Diesel-era and Alembic-era DBs are adopted untouched, verified against a verbatim Diesel-era schema dump). Web sign-in uses session cookies against the same htpasswd file (bcrypt-only, `$2y$` accepted); a password change or user removal now invalidates that user's existing sessions on their next request, and sessions last 7 days instead of silently dying after 15 minutes like the old broken token refresh. The SSH layer is reimplemented on Erlang's built-in `:ssh`/`:ssh_sftp` (no asyncssh): direct hosts connect natively, jump-host chains run through a supervised OpenSSH forwarder, and passphrase-protected keys are decrypted once at boot — with the same per-host connection reuse, read caching, disabled-host and readonly-marker guards, and the identical bundled `script.sh` for authorized_keys operations. The domain logic (hosts, users, keys, authorizations, activity log, and the authorized_keys diff/sync) is reimplemented as Elixir contexts with the same validation, uniqueness, and audit-trail behavior as the Python API. The LiveView UI port has begun: an authenticated app shell with sidebar navigation (same seven pages as the React app) and dark/light/system theme toggle, the Dashboard (entity stat cards plus a recent-activity feed), and the Hosts page (create/edit modal with jump-host selection, enable/disable toggle, delete with confirmation, and an async SSH connection test that refuses disabled hosts). Host mutations write activity-log entries — behavior the Python stack defined but never wired up. The Users page (per-user key/authorization counts, create/edit modal, enable/disable, cascade-aware delete), SSH Keys page (owner filter, add/edit modal — key material immutable after creation, full-key view modal, delete), and Authorizations page (user/host filters, grant/edit/revoke with duplicate-grant rejection) are ported as LiveViews; all mutations audit-log. The Diff Viewer computes per-host sync status asynchronously (synchronized / needs sync with add/remove counts / error / disabled), shows the per-login key diff with readonly and managed-pragma badges, and offers single-host Sync plus a Sync-all that only touches drifted hosts; syncs are audit-logged. The Activities page lists the audit trail newest-first with a type filter, expandable JSON details, and load-more paging. The Elixir app exposes an unauthenticated `GET /api/health` (version + database probe) for container orchestration, and the `justfile` gained targets for the docker-only toolchain (today: `just dev`, `just test`, `just verify`).

## [1.1.11] - 2026-07-29

### Security
- **Frontend dependency advisories**: upgraded React Router to 8.3.0, PostCSS to 8.5.25, and the frontend lint toolchain so all transitive `brace-expansion` paths resolve to 5.0.8, addressing the high-severity vulnerabilities reported by Dependabot and `npm audit`.

### Added
- **Third-party license attribution (`THIRD-PARTY-LICENSES.md`)**: generated NOTICE files enumerating every bundled production dependency with its version, SPDX license, and full license text, satisfying the attribution/notice obligations of those licenses under our BSL 1.1 distribution. All dependencies are permissive (MIT/BSD/ISC/Apache-2.0/PSF) or weak file-level copyleft; `asyncssh` is used under its Eclipse Public License 2.0 option (offered as `EPL-2.0 OR GPL-2.0-or-later`), unmodified, so no copyleft reaches SSM. Two files are produced by `backend/scripts/gen_third_party_licenses.py`: a combined backend+frontend notice at the repository root (shipped in the full-app image, `docker/app/Dockerfile`, alongside `LICENSE`) and a backend-only notice at `backend/THIRD-PARTY-LICENSES.md` (shipped in the standalone backend image, `backend/Dockerfile`). The root `.dockerignore` was adjusted so the notice and `LICENSE` survive into the build context. Regenerate the files after any dependency change.
- **Software Bill of Materials (SBOM)**: machine-readable CycloneDX SBOMs for the production dependency trees, generated by `backend/scripts/gen_sbom.sh` into `sbom/ssm-backend.cdx.json` (Python, 36 components, CycloneDX 1.6) and `sbom/ssm-frontend.cdx.json` (JavaScript, CycloneDX 1.5). Each component carries a Package URL (`purl`) and SPDX license; backend license fields are back-filled from installed metadata by `backend/scripts/enrich_sbom_licenses.py` (the `cyclonedx-py requirements` generator leaves them empty). Enables automated vulnerability/license scanning and supply-chain attestation. Both images ship their SBOMs under `/app/sbom/`: the full-app image (`docker/app/Dockerfile`) carries both files, the standalone backend image (`backend/Dockerfile`) carries the backend SBOM (mirrored into `backend/sbom/` so it reaches that build context). Regenerate after dependency changes.

## [1.1.10] - 2026-06-28

### Changed
- **License switched to Business Source License 1.1 (BSL 1.1)**: the project is now source-available rather than GPL-3.0-only. You may read, build, modify, and run SSM for your own organization for free, but offering it as a hosted/managed/multi-tenant service or reselling it for a fee requires a commercial license from STYLiTE (office@stylite.de). Each released version automatically converts to GPL v3.0-or-later four years after publication (Change Date 2030-06-28). Added `LICENSE` (BSL text) and `LICENSING.md` (plain-language summary); removed the standalone GPLv3 `LICENSE.txt`; updated the README License section.

### Security
- **Patched 46 Dependabot-flagged dependency vulnerabilities** (22 high, 18 moderate, 6 low). Backend: `asyncssh` 2.22.0→2.24.0, `cryptography`→49.0.0, `pyjwt` 2.12.1→2.13.0, `starlette`→1.3.1, `urllib3`→2.7.0, `idna`→3.18, `mako`→1.3.12 (lockfile; direct-dependency floors for `asyncssh`/`pyjwt` raised in `pyproject.toml`). Frontend: `axios`→1.18.1, `react-router`/`react-router-dom`→7.18.0, `vite`→7.3.6, plus transitive `esbuild`/`js-yaml`/`form-data`/`@babel/core`; `npm audit` now reports 0 vulnerabilities (direct floors raised in `package.json`).

## [1.1.9] - 2026-04-27

### Changed
- **Documentation refresh**: `AGENTS.md`/`CLAUDE.md`, `frontend/README.md`, top-level `README.md`, and the `verify`/`release` skills no longer describe the project as a Rust/Actix/Diesel backend. Commands, endpoint paths (`/api/v2/*`), auth scheme (JWT bearer), SSH library (`asyncssh`), and env vars (`JWT_SECRET`) now match the Python/FastAPI reality. Removed obsolete `jump_via` string-coercion section.
- **Configuration is env-only**: dropped TOML support. Settings come from environment variables, optionally seeded by a `backend/.env` file loaded on startup via `python-dotenv` (override the path with `DOTENV=…`). `config.toml` / `config.toml.example` / the `CONFIG` env var are gone; `backend/.env.example` is the new template. SSH options moved from a `[ssh]` table to flat env vars: `SSH_TIMEOUT`, `SSH_KEY_PASSPHRASE`, `SSH_CHECK_SCHEDULE`, `SSH_UPDATE_SCHEDULE`. `SSH_KEY` and `JWT_SECRET`/`SESSION_KEY` keep their previous names. `start-dev.sh` and the docker compose/setup files were updated to match.

## [1.1.8] - 2026-04-27

### Changed
- **Contributor docs**: `AGENTS.md`/`CLAUDE.md` now spell out a mandatory rule that every database schema change goes through an alembic migration — never hand-edit models without a matching revision in `backend/migrations/versions/`.

### Fixed
- **Docker bind-mount permissions**: Container startup now `chown`s `/app/db` to the runtime user, so SQLite databases written under the previous uid-1000 backend image remain writable after upgrading to the combined image.

## [1.1.7] - 2026-04-27

### Added
- **Dashboard version pill**: The dashboard now displays the frontend version, backend version, and applied alembic schema revision (`fe v… be v… db <rev>`), with a tooltip showing each on its own line.
- **`/api/v2/info` endpoint**: New protected endpoint returning `{name, version, alembic_revision}`. Frontend version is injected at build time from the repository `VERSION` file via Vite (`__APP_VERSION__`), and the Docker frontend stage copies `VERSION` so the bundle ships with the correct value.

### Fixed
- **Legacy DB stamping creates missing tables**: When stamping a Diesel-era database as revision `0001`, also run `metadata.create_all(checkfirst=True)` to create tables that were added after the Python rewrite (notably `activity_log` and its indexes). Without this, the activity-log API crashed with `no such table: activity_log` on first request.

## [1.1.6] - 2026-04-27

### Fixed
- **Frontend talking to wrong API base**: The production frontend bundle was being built with `VITE_API_URL=/api`, but the FastAPI backend mounts everything under `/api/v2/*`, so login (and every other call) returned 404. The Dockerfile default and both compose files now use `/api/v2`.

## [1.1.5] - 2026-04-27

### Fixed
- **Empty `alembic_version` after fresh upgrade**: SQLite uses non-transactional DDL, so a fresh `alembic upgrade head` would create the schema but the stamp `INSERT` into `alembic_version` was rolled back when the async connection closed. An explicit `connection.commit()` after migrations now persists the revision row.
- **Legacy DB with empty alembic_version table**: Some inherited databases already had an empty `alembic_version` table (created by a prior crashed bootstrap). The previous fix only handled the missing-table case, so alembic still tried to re-run revision `0001` and crashed with `table host already exists`. The stamp logic now also fires when the table is present but empty.

### Security
- **postcss XSS advisory**: Bumped postcss to 8.5.12 to address a published XSS advisory.

## [1.1.4] - 2026-04-27

### Fixed
- **Legacy DB stamping moved into `migrations/env.py`**: Detection now lives inside alembic's environment, so it runs whenever alembic does — regardless of how it is invoked. The previous standalone preflight script and its hook in `start.sh` are removed.

## [1.1.3] - 2026-04-27

### Fixed
- Container startup no longer crashes on databases inherited from the Rust backend. A preflight step detects legacy databases (schema present, no `alembic_version` table) and stamps them as revision `0001` so `alembic upgrade head` becomes a no-op.

## [1.1.2] - 2026-04-27

## [1.1.1] - 2026-04-27

## [1.1.0] - 2026-04-27

### Added
- **Authorization Matrix "All" View**: Added "all (view only)" option to login account selector that displays the count of authorizations per user/host across all login accounts
- **Authorization Matrix Usage Counts**: Login accounts in selector now show usage count (e.g., "oracle (4)")
- **User Merge Workflow**: Users list now supports selecting multiple accounts and merging them into a single user, consolidating keys and host authorizations in one step
- **Bulk User Deletion**: Select users in the list and delete them all at once with a confirmation dialog that summarizes impact

### Changed
- **Authorization Matrix UI**: Removed scroll bars from matrix view for cleaner, full-page display
- **Authorization Matrix Layout**: Moved "Show Authorized Only" button to be positioned after the login account selector for better workflow
- **Authorization Matrix Selector Order**: Login accounts sorted by usage count in descending order, with "all (view only)" shown first
- **Authorization Matrix Default**: Smart default selection - prefers "root" if available, otherwise defaults to most-used login account
- **Host Add Form**: SSH Username field now defaults to "root" for convenience

## [1.0.1] - 2025-10-06

## [1.0.0] - 2025-10-06

### Changed
- **Database Schema Consolidation**: Removed all incremental migrations and created single initial migration with final schema
- **Breaking Change**: Existing databases must be recreated - migration history removed for clean 1.0.0 baseline

### Added
- **Initial Migration**: Single migration file containing complete database schema for version 1.0.0

## [0.2.22] - 2025-10-06

### Added
- **Authorization Matrix Enhancement**: Added login account selector to filter matrix by specific SSH accounts (root, oracle, etc.)
- **Smart Host Filtering**: Matrix automatically shows only hosts that have authorizations for the selected login account
- **Alphabetical Sorting**: Users and hosts are now sorted alphabetically for better overview
- **Show Authorized Only Toggle**: Added button to show only users with actual authorizations, hiding empty rows
- **Code Quality Improvements**: Fixed multiple Clippy and ESLint warnings across frontend and backend

### Changed
- **Matrix Behavior**: Matrix now defaults to showing all users but only relevant hosts for selected login account
- **User Experience**: Cleaner matrix interface with better filtering and sorting

## [0.2.21] - 2025-10-06

## [0.2.20] - 2025-10-06

### Added
- Expanded username validation to allow spaces, @ symbols, and # symbols
- Allow empty comments in user edit modal

## [0.2.19] - 2025-10-06

## [0.2.18] - 2025-10-06

### Added
- Comprehensive CHANGELOG.md file for tracking all changes
- Automatic CHANGELOG.md updates in release.sh script

## [0.2.17] - 2025-09-13

### Added
- **Environment Variable Support**: Full support for `DATABASE_URL`, `HTPASSWD`, `SSH_KEY`, and `SESSION_KEY` environment variables that take precedence over config file settings
- **Automatic Htpasswd Creation**: Server automatically creates htpasswd file with random admin password if none exists, displayed in beautiful ASCII art during startup
- **Enhanced SSH Key Error Handling**: Detailed error messages with step-by-step SSH key generation instructions using ed25519 keys
- **Comprehensive Startup Logging**: Server now logs database URL, htpasswd path, SSH key path, and log level during startup for transparency
- **Config File Optional**: Server can start without `config.toml` using sensible defaults and environment variables
- **Docker Environment Configuration**: Proper environment variable setup in docker-compose.yml with detailed comments

### Changed
- **Configuration Loading**: Environment variables now override config file settings for all critical paths
- **Default SSH Key Path**: Changed from `/app/id` to `keys/id_ssm` for better Docker compatibility
- **Error Messages**: All error messages now use beautiful box drawing characters for better readability
- **Documentation**: Updated README.md, CLAUDE.md, and config examples with comprehensive environment variable documentation

### Fixed
- **CORS Configuration**: Confirmed that `cors_origins` config setting is unused (server uses hardcoded localhost origins)
- **SSH Key Path Resolution**: Consistent default paths across development and Docker environments

### Security
- **Automatic Password Generation**: Secure random password generation using cryptographically secure RNG
- **Bcrypt Hashing**: All auto-generated passwords use proper bcrypt hashing with default cost factor

## [0.2.16] - 2025-09-13

### Changed
- Update .gitignore to exclude backup files with .bak extension

### Fixed
- Reposition logout button in sidebar for improved accessibility
- Move logout button under user info section in sidebar

## [0.2.15] - 2025-09-13

### Changed
- Update Nginx configuration to comment out rate limiting for SSH and API endpoints

## [0.2.14] - 2025-09-13

### Refactored
- Enhance authorization mapping in UsersPage for type safety
- Update UsersPage to use RawAuthorizationResponse type for improved type safety

## [0.2.13] - 2025-09-13

### Fixed
- Resolve TypeScript compilation errors for production build

### Changed
- Update dependencies in package.json and package-lock.json
- Update Cargo.toml dependency versions
- Remove deprecated test files and modules

### Security
- Remove git-secure wrapper script that enforced SSH commit signing
- Enforce SSH commit signing and update dependencies

## [0.2.12] - 2025-09-08

## [0.2.11] - 2025-09-08

## [0.2.10] - 2025-09-07

---

## Development Notes

### How to Update This Changelog

1. **Before committing**: Add new changes under `[Unreleased]` section
2. **When releasing**: `./release.sh patch|minor|major` rotates `[Unreleased]` into a new version section with the release date
3. **Version format**: Use semantic versioning (MAJOR.MINOR.PATCH)
4. **Categories**:
   - `Added` for new features
   - `Changed` for changes in existing functionality
   - `Deprecated` for soon-to-be removed features
   - `Removed` for now removed features
   - `Fixed` for any bug fixes
   - `Security` for vulnerability fixes
