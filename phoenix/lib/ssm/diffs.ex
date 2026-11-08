defmodule Ssm.Diffs do
  @moduledoc """
  Compare a host's on-disk `authorized_keys` to what the database authorizes,
  and push the DB state to the host — port of api/v2/diffs.py.

  Every read/write goes through `Ssm.Ssh.ScriptRunner` (never raw SFTP), so
  home-dir probing, `has_pragma` detection, the readonly sentinel and managed
  backups all come for free. Disabled hosts short-circuit before any SSH.
  What the DB expects comes from `Ssm.Diffs.Expected`, the comparison and
  the options policy from `Ssm.Diffs.Compare`.

  ssm's own public key (`Ssm.Ssh.OwnKey`, the key it logs in with) in the
  file of the host's login user (`host.username`) is never drift: on the
  host it is `:present` (matched by type and base64 after the options,
  whatever its options or comment), missing it is not reported, and a sync
  of that login always writes it – otherwise the first sync would lock ssm
  out (onboarding v2 installs it into `~root/.ssh/authorized_keys`). When
  the own key cannot be read, a sync that would write that login is refused.

  Alias logins: the own key is placed by login name, so a login that is
  not `host.username` but resolves to its home (a uid-0 alias such as
  `toor` sharing root's home) is never managed — `script.sh` refuses the
  write (`unsafe (shared_home)`) and a sync skips it. Placing the key by
  home instead would keep ssm's key, but the two logins would still
  replace each other's grants in their one file on every sync.
  """

  alias Ssm.Diffs.{Compare, Expected, KeyLine}
  alias Ssm.Hosts
  alias Ssm.Hosts.{Host, MachineId}
  alias Ssm.Ssh.ScriptRunner
  alias Ssm.Users.KeyParser

  @blocked_note "revocation blocked by user_readonly"
  @ssh_dir_blocked "revocation blocked: unsafe ~/.ssh"

  defmodule KeyDiff do
    @moduledoc """
    One key line and its presence status. `note` explains a special case
    for operators ("invalid stored options", "drops host restriction: …").
    """
    @enforce_keys [:status, :line]
    defstruct [:status, :line, note: nil]
    @type status :: :present | :missing_on_host | :extra_on_host
    @type t :: %__MODULE__{status: status(), line: String.t(), note: String.t() | nil}
  end

  defmodule LoginDiff do
    @moduledoc "Per-login diff of authorized_keys."
    defstruct login: nil,
              has_pragma: false,
              readonly_condition: nil,
              readonly_ignored: nil,
              unsafe: nil,
              blocked: nil,
              read_error: nil,
              items: []
  end

  defmodule HostDiff do
    @moduledoc "A host's full diff across every login."
    defstruct [:host_id, :host_name, :disabled, :read_error, logins: []]
  end

  defmodule SyncedLogin do
    @moduledoc false
    defstruct [:login, :written_keys]
  end

  @doc """
  Compute the diff for a host. Returns `{:error, {:host_disabled, _}}` for a
  disabled host and `{:error, :not_found}` for an unknown one.
  """
  @spec host_diff(module(), integer()) ::
          {:ok, HostDiff.t()} | {:error, term()}
  def host_diff(client \\ Ssm.Ssh, host_id) do
    with {:ok, host} <- Hosts.fetch_host(host_id),
         :ok <- ensure_not_disabled(host) do
      {observed, read_error} = read_observed(client, Hosts.target_for(host))
      all_logins = (Expected.logins(host_id) ++ Map.keys(observed)) |> Enum.uniq() |> Enum.sort()
      own = own_key_or_none(host)

      logins =
        Enum.map(all_logins, fn login ->
          build_login_diff(host_id, login, Map.get(observed, login), read_error, own[login])
        end)

      {:ok,
       %HostDiff{
         host_id: host.id,
         host_name: host.name,
         disabled: host.disabled,
         read_error: read_error,
         logins: logins
       }}
    end
  end

  defp read_observed(client, target) do
    case ScriptRunner.get_ssh_keyfiles(client, target) do
      {:ok, entries} -> {Map.new(entries, &{&1.login, &1}), nil}
      {:error, {_code, message}} -> {%{}, message}
    end
  end

  @doc """
  Push the DB's expected `authorized_keys` to every authorized login on the
  host, and to every managed login (`Ssm.Authorizations.managed_logins/1`)
  that still has a file on the host: a login whose last grant is gone gets
  an empty file (plus ssm's own key for the host's login user), so a
  revocation reaches the host. Files are never deleted. Disabled host
  short-circuits.

  Readonly markers come from the listing read first. A host-wide marker
  (`system_readonly`, a vendor platform) on any target login stops the sync
  before the first write. A login's own `user_readonly` skips only that
  login: every other login is written and the result is `{:error,
  {:ssh_readonly, message}}` naming the skipped logins, their reasons and
  the logins that were written. Nothing is written when ssm's own key is
  unavailable and the host's login user is a target (`{:error,
  {:own_key_unavailable, _}}`). A login without a file has no readonly state
  in the listing: when the script refuses its write as readonly, it is
  skipped the same way and the sync goes on with the next login. Any other
  write failure stops the sync there; the logins before it (sorted by name)
  are already written.

  A stored key row with control characters in the key is never written: it
  is logged, the remaining lines are synced and the result is `{:error,
  {:invalid_key_line, message}}`. A comment with control characters is
  dropped (the key is written without it). A legacy row with options that
  fail today's rules keeps the host's line of that key (or is skipped when
  the host lacks it). Both are logged.
  """
  @spec sync_host(module(), integer()) ::
          {:ok, [SyncedLogin.t()]} | {:error, term()}
  def sync_host(client \\ Ssm.Ssh, host_id),
    do: client |> sync_host_reported(host_id) |> elem(0)

  @doc """
  `sync_host/2` plus what it did, for the audit log (`Ssm.Diffs.SyncAudit`):
  `{result, %{written: [%SyncedLogin{}], skipped: [{login, reason}],
  ignored: [{login, reason}]}}` — also for a failed or partial sync.
  `ignored` lists target logins whose `user_readonly` was not honoured (not
  owned by root): a user tried to freeze the login.
  """
  @spec sync_host_reported(module(), integer()) ::
          {{:ok, [SyncedLogin.t()]} | {:error, term()}, map()}
  def sync_host_reported(client \\ Ssm.Ssh, host_id) do
    case prepare_sync(client, host_id) do
      {:ok, %{host: host, logins: logins, target: target, ctx: ctx}} ->
        logins
        |> sync_logins(client, target, ctx, %{
          synced: [],
          refused: [],
          skipped: Enum.reverse(ctx.skipped)
        })
        |> tap(fn {result, _report} -> learn_machine_id(result, host, client) end)

      {:error, _} = error ->
        {error, %{written: [], skipped: [], ignored: []}}
    end
  end

  defp prepare_sync(client, host_id) do
    with {:ok, host} <- Hosts.fetch_host(host_id),
         :ok <- ensure_not_disabled(host),
         target = Hosts.target_for(host),
         # read first: a granted key keeps the host's line (options, comment);
         # no write when the files cannot be read
         {:ok, entries} <- ScriptRunner.get_ssh_keyfiles(client, target),
         on_host = Map.new(entries, &{&1.login, parse_authorized_keys(&1.keyfile)}),
         logins = Expected.logins_to_sync(host_id, on_host),
         :ok <- ensure_no_host_readonly(host, entries, logins),
         skipped = logins_to_skip(entries, logins),
         to_write = logins -- Enum.map(skipped, &elem(&1, 0)),
         {:ok, own} <- own_key_for_sync(host, to_write) do
      ignored =
        for e <- entries, e.readonly_ignored, e.login in logins, do: {e.login, e.readonly_ignored}

      ctx = %{host: host, own: own, on_host: on_host, skipped: skipped, ignored: ignored}
      {:ok, %{host: host, logins: to_write, target: target, ctx: ctx}}
    end
  end

  # identity-claims-v1: a successful sync proves the host reachable; refresh
  # its machine-id claim (best effort, never changes the sync result).
  defp learn_machine_id({:ok, _}, host, client), do: MachineId.refresh(host, client: client)
  defp learn_machine_id(_other, _host, _client), do: :ok

  # a host-wide marker (system_readonly, vendor platform) blocks every login
  defp ensure_no_host_readonly(host, entries, logins) do
    targets = MapSet.new(logins)

    case Enum.find(entries, &(MapSet.member?(targets, &1.login) and &1.readonly_scope == :host)) do
      nil ->
        :ok

      entry ->
        {:error,
         {:ssh_readonly,
          "host #{inspect(host.name)} is readonly (#{reason_text(entry.readonly_condition)}, " <>
            "reported for login #{inspect(entry.login)}); nothing written"}}
    end
  end

  # [{login, reason}] of the target logins a sync must not write: a
  # root-owned user_readonly, or an unsafe ~/.ssh (a link: the write would
  # land elsewhere). A linked authorized_keys is not skipped: script.sh
  # replaces its entry and never writes through it.
  defp logins_to_skip(entries, logins) do
    targets = MapSet.new(logins)

    entries
    |> Enum.filter(&MapSet.member?(targets, &1.login))
    |> Enum.map(&{&1.login, skip_reason(&1)})
    |> Enum.reject(fn {_login, reason} -> is_nil(reason) end)
  end

  # only an unsafe ~/.ssh is skipped: a linked authorized_keys is replaced
  # (never written through), so its revocation still reaches the host
  defp skip_reason(%{unsafe: "ssh_dir"}), do: @ssh_dir_blocked
  defp skip_reason(%{readonly_scope: :user, readonly_condition: condition}), do: condition
  defp skip_reason(_entry), do: nil

  # the marker text is written by the login's user: quoted and bounded
  defp reason_text(text), do: text |> to_string() |> String.slice(0, 200) |> inspect()

  defp sync_logins([], _client, _target, ctx, acc) do
    report = report(acc, ctx)
    {finish(report.written, acc.refused, report.skipped, ctx.host), report}
  end

  defp sync_logins([login | rest], client, target, ctx, acc) do
    expected = Expected.lines(ctx.host.id, login)

    lines =
      expected.lines
      |> Compare.lines_to_write(expected.legacy, Map.get(ctx.on_host, login, []))
      |> with_own_key(ctx.own[login])

    content = Enum.map_join(lines, "", &(&1 <> "\n"))

    case ScriptRunner.set_authorized_keyfile(client, target, login, content) do
      :ok ->
        done = %SyncedLogin{login: login, written_keys: length(lines)}
        acc = %{acc | synced: [done | acc.synced], refused: acc.refused ++ expected.refused}
        sync_logins(rest, client, target, ctx, acc)

      # a login without a file has no readonly state in the listing; its own
      # user_readonly surfaces only now: skip it like a listed one
      {:error, {:ssh_readonly, reason}} ->
        sync_logins(rest, client, target, ctx, %{acc | skipped: [{login, reason} | acc.skipped]})

      # the script refused a link only now (no listing entry, link-to-dir)
      {:error, {:ssh_unsafe, reason}} ->
        skipped = [{login, unsafe_reason(reason)} | acc.skipped]
        sync_logins(rest, client, target, ctx, %{acc | skipped: skipped})

      {:error, _} = error ->
        {error, report(acc, ctx)}
    end
  end

  defp report(acc, ctx),
    do: %{
      written: Enum.reverse(acc.synced),
      skipped: Enum.reverse(acc.skipped),
      ignored: ctx.ignored
    }

  defp unsafe_reason(message) do
    case Regex.run(~r/unsafe \(([^)]+)\)/, message) do
      [_, "ssh_dir"] -> @ssh_dir_blocked
      [_, "home"] -> "no usable home (missing or a symlink)"
      [_, "shared_home"] -> "not managed: shares the SSH user's home (ssm's own key)"
      [_, kind] -> "unsafe: " <> kind
      nil -> "unsafe"
    end
  end

  defp finish(synced, [], [], _host), do: {:ok, synced}

  defp finish(_synced, refused, [], _host),
    do: {:error, {:invalid_key_line, refused_message(refused)}}

  defp finish(synced, refused, skipped, host) do
    skipped_text =
      Enum.map_join(skipped, "; ", fn {login, reason} ->
        "skipped #{inspect(login)} (#{reason_text(reason)})"
      end)

    written = Enum.map_join(synced, ", ", & &1.login)
    refused_text = if refused == [], do: "", else: "; " <> refused_message(refused)

    {:error,
     {:ssh_readonly,
      "host #{inspect(host.name)}: #{skipped_text}; written: #{written}#{refused_text}"}}
  end

  defp refused_message(refused) do
    ids = refused |> Enum.map(& &1.key_id) |> Enum.uniq() |> Enum.join(", ")

    "refused #{length(refused)} stored key line(s) (control characters in the key; " <>
      "key id #{ids}) — fix or delete them; all other lines were written"
  end

  ## Diff building

  defp build_login_diff(host_id, login, entry, read_error, own) do
    expected = Expected.lines(host_id, login)
    {_, lines} = split_own(expected.lines, own)
    actual = if entry, do: parse_authorized_keys(entry.keyfile), else: []
    {own_lines, actual} = split_own(actual, own)
    {legacy_items, actual} = Compare.legacy_items(expected.legacy, actual)

    items =
      Compare.diff(lines, actual) ++
        legacy_items ++ Compare.to_sorted(MapSet.new(own_lines), :present)

    %LoginDiff{
      login: login,
      has_pragma: !!(entry && entry.has_pragma),
      readonly_condition: entry && entry.readonly_condition,
      readonly_ignored: entry && entry.readonly_ignored,
      read_error: login_read_error(entry, read_error),
      unsafe: unsafe_text(entry),
      blocked: if(entry && entry.unsafe == "ssh_dir", do: @ssh_dir_blocked),
      items: blocked_by_user_readonly(items, entry)
    }
  end

  # an unsafe ~/.ssh is not read: the per-login read_error (also in the API
  # diff) says so; the periodic check keeps it as blocked drift (SyncCheck)
  defp login_read_error(nil, read_error), do: read_error

  defp login_read_error(%{unsafe: "ssh_dir"}, _read_error),
    do: @ssh_dir_blocked <> " (not read, not written)"

  defp login_read_error(_entry, _read_error), do: nil

  defp unsafe_text(%{unsafe: "ssh_dir"}), do: "unsafe ~/.ssh: not read, not written"

  defp unsafe_text(%{unsafe: unsafe}) when is_binary(unsafe),
    do: "unsafe authorized_keys (#{unsafe}): not read; a sync replaces it"

  defp unsafe_text(_entry), do: nil

  # removals a sync cannot make while the login's user_readonly is set
  defp blocked_by_user_readonly(items, %{readonly_scope: :user}),
    do: Compare.note_extras(items, @blocked_note)

  defp blocked_by_user_readonly(items, _entry), do: items

  @doc false
  def compute_diff(expected, actual), do: Compare.diff(expected, actual)

  ## ssm's own key

  # {:ok, %{login => {type, base64}}}: the own key belongs to the host's login user
  defp own_key_for(%Host{username: login}) when is_binary(login) do
    module = Application.get_env(:ssm, :own_key, Ssm.Ssh.OwnKey)

    with {:ok, line} <- module.public_key(),
         [type, base64 | _] <- String.split(line) do
      {:ok, %{login => {type, base64}}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unparsable_own_key}
    end
  end

  defp own_key_for(_host), do: {:ok, %{}}

  # the diff only reads: without the own key it is an ordinary line there
  defp own_key_or_none(host) do
    case own_key_for(host) do
      {:ok, own} -> own
      {:error, _} -> %{}
    end
  end

  # a sync must never write the login user's file without ssm's own key:
  # that would lock ssm out of the host
  defp own_key_for_sync(%Host{username: login} = host, logins) do
    case own_key_for(host) do
      {:ok, own} ->
        {:ok, own}

      {:error, reason} ->
        if login in logins,
          do: {:error, {:own_key_unavailable, own_key_message(host, reason)}},
          else: {:ok, %{}}
    end
  end

  defp own_key_message(host, reason) do
    "ssm's own public key (SSH_KEY) is unavailable (#{inspect(reason)}); refusing to " <>
      "rewrite #{inspect(host.username)}'s authorized_keys on #{inspect(host.name)} " <>
      "— nothing written"
  end

  defp split_own(lines, nil), do: {[], lines}
  defp split_own(lines, own), do: Enum.split_with(lines, &(KeyParser.identity(&1) == own))

  defp with_own_key(lines, nil), do: lines

  defp with_own_key(lines, {type, base64} = own) do
    {_, rest} = split_own(lines, own)
    rest ++ [format_key_line(type, base64, "ssm")]
  end

  @doc false
  defdelegate format_key_line(key_type, key_base64, label), to: KeyLine, as: :format

  defp parse_authorized_keys(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  defp ensure_not_disabled(%Host{disabled: true, name: name}),
    do: {:error, {:host_disabled, "host #{inspect(name)} is disabled"}}

  defp ensure_not_disabled(%Host{}), do: :ok
end
