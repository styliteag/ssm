defmodule Ssm.Diffs do
  @moduledoc """
  Compare a host's on-disk `authorized_keys` to what the database authorizes,
  and push the DB state to the host — port of api/v2/diffs.py.

  Every read/write goes through `Ssm.Ssh.ScriptRunner` (never raw SFTP), so
  home-dir probing, `has_pragma` detection, the readonly sentinel and managed
  backups all come for free. Disabled hosts short-circuit before any SSH.

  ssm's own public key (`Ssm.Ssh.OwnKey`, the key it logs in with) in the
  file of the host's login user (`host.username`) is never drift: on the
  host it is `:present` (matched by type and base64, whatever its options
  or comment), missing it is not reported, and a sync of that login always
  writes it – otherwise the first sync would lock ssm out (onboarding v2
  installs it into `~root/.ssh/authorized_keys`).
  """

  import Ecto.Query

  alias Ssm.Authorizations.Authorization
  alias Ssm.Hosts
  alias Ssm.Hosts.{Host, MachineId}
  alias Ssm.Repo
  alias Ssm.Ssh.ScriptRunner
  alias Ssm.Users.{KeyParser, UserKey}

  defmodule KeyDiff do
    @moduledoc "One key line and its presence status."
    @enforce_keys [:status, :line]
    defstruct [:status, :line]
    @type status :: :present | :missing_on_host | :extra_on_host
    @type t :: %__MODULE__{status: status(), line: String.t()}
  end

  defmodule LoginDiff do
    @moduledoc "Per-login diff of authorized_keys."
    defstruct login: nil,
              has_pragma: false,
              readonly_condition: nil,
              read_error: nil,
              items: []
  end

  defmodule HostDiff do
    @moduledoc "A host's full diff across every login."
    defstruct [:host_id, :host_name, :disabled, :read_error, logins: []]
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
      target = Hosts.target_for(host)

      {observed, read_error} =
        case ScriptRunner.get_ssh_keyfiles(client, target) do
          {:ok, entries} -> {Map.new(entries, &{&1.login, &1}), nil}
          {:error, {_code, message}} -> {%{}, message}
        end

      expected_logins = expected_logins(host_id)
      all_logins = (expected_logins ++ Map.keys(observed)) |> Enum.uniq() |> Enum.sort()
      own = own_key_for(host)

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

  defmodule SyncedLogin do
    @moduledoc false
    defstruct [:login, :written_keys]
  end

  @doc """
  Push the DB's expected `authorized_keys` to every authorized login on the
  host. Bails atomically on the first readonly login (the script refuses the
  write) — never partial-writes. Disabled host short-circuits.
  """
  @spec sync_host(module(), integer()) ::
          {:ok, [SyncedLogin.t()]} | {:error, term()}
  def sync_host(client \\ Ssm.Ssh, host_id) do
    with {:ok, host} <- Hosts.fetch_host(host_id),
         :ok <- ensure_not_disabled(host),
         target = Hosts.target_for(host),
         # read first: a granted key keeps the host's line (options, comment);
         # no write when the files cannot be read
         {:ok, entries} <- ScriptRunner.get_ssh_keyfiles(client, target) do
      own = own_key_for(host)
      on_host = Map.new(entries, &{&1.login, parse_authorized_keys(&1.keyfile)})

      host_id
      |> expected_logins()
      |> Enum.sort()
      |> sync_logins(client, target, %{host_id: host_id, own: own, on_host: on_host}, [])
      |> tap(&learn_machine_id(&1, host, client))
    end
  end

  # identity-claims-v1: a successful sync proves the host reachable; refresh
  # its machine-id claim (best effort, never changes the sync result).
  defp learn_machine_id({:ok, _}, host, client), do: MachineId.refresh(host, client: client)
  defp learn_machine_id(_other, _host, _client), do: :ok

  defp sync_logins([], _client, _target, _ctx, acc), do: {:ok, Enum.reverse(acc)}

  defp sync_logins([login | rest], client, target, ctx, acc) do
    expected =
      ctx.host_id
      |> expected_keys_for_login(login)
      |> lines_to_write(Map.get(ctx.on_host, login, []))
      |> with_own_key(ctx.own[login])

    content = Enum.map_join(expected, "", &(&1 <> "\n"))

    case ScriptRunner.set_authorized_keyfile(client, target, login, content) do
      :ok ->
        synced = %SyncedLogin{login: login, written_keys: length(expected)}
        sync_logins(rest, client, target, ctx, [synced | acc])

      {:error, _} = error ->
        error
    end
  end

  ## Diff building

  defp build_login_diff(host_id, login, entry, read_error, own) do
    {_, expected} = host_id |> expected_keys_for_login(login) |> split_own(own)
    actual = if entry, do: parse_authorized_keys(entry.keyfile), else: []
    {own_lines, actual} = split_own(actual, own)

    %LoginDiff{
      login: login,
      has_pragma: !!(entry && entry.has_pragma),
      readonly_condition: entry && entry.readonly_condition,
      read_error: if(is_nil(entry) && read_error, do: read_error),
      items: compute_diff(expected, actual) ++ to_sorted(MapSet.new(own_lines), :present)
    }
  end

  ## ssm's own key

  # %{login => {type, base64}}: the own key belongs to the host's login user
  defp own_key_for(%Host{username: login}) when is_binary(login) do
    module = Application.get_env(:ssm, :own_key, Ssm.Ssh.OwnKey)

    with {:ok, line} <- module.public_key(),
         [type, base64 | _] <- String.split(line) do
      %{login => {type, base64}}
    else
      _ -> %{}
    end
  end

  defp own_key_for(_host), do: %{}

  defp split_own(lines, nil), do: {[], lines}
  defp split_own(lines, own), do: Enum.split_with(lines, &own_key_line?(&1, own))

  # the key's type and base64 as adjacent fields: any options prefix, any comment
  defp own_key_line?(line, {type, base64}) do
    line
    |> String.split()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.member?([type, base64])
  end

  defp with_own_key(expected, nil), do: expected

  defp with_own_key(expected, {type, base64} = own) do
    {_, rest} = split_own(expected, own)
    rest ++ [format_key_line(type, base64, "ssm")]
  end

  # Lines are compared by their key (`KeyParser.identity/1`: type + base64),
  # never as whole lines: the comment on the host (or ssm's key name) and an
  # options prefix do not make a granted key "missing" and "not authorized" at
  # once. A present key shows the host's line. A line without a key compares
  # as its trimmed text.
  @doc false
  def compute_diff(expected, actual) do
    exp = index_by_key(expected)
    act = index_by_key(actual)

    present = for {id, line} <- act, Map.has_key?(exp, id), do: line
    missing = for {id, line} <- exp, not Map.has_key?(act, id), do: line
    extra = for {id, line} <- act, not Map.has_key?(exp, id), do: line

    to_sorted(present, :present) ++
      to_sorted(missing, :missing_on_host) ++ to_sorted(extra, :extra_on_host)
  end

  # %{key identity => first line with that key}
  defp index_by_key(lines) do
    Enum.reduce(lines, %{}, fn line, acc -> Map.put_new(acc, key_id(line), line) end)
  end

  defp key_id(line), do: KeyParser.identity(line) || {:line, String.trim(line)}

  # the DB's lines for a login, one per key, each replaced by the host's line
  # of that key when the host has it: a sync keeps the host's options and
  # comment of a granted key and never writes a key twice
  defp lines_to_write(expected, host_lines) do
    on_host = index_by_key(host_lines)

    expected
    |> index_by_key()
    |> Enum.sort_by(fn {_id, line} -> Enum.find_index(expected, &(&1 == line)) end)
    |> Enum.map(fn {id, line} -> Map.get(on_host, id, line) end)
  end

  defp to_sorted(set, status) do
    set |> Enum.sort() |> Enum.map(&%KeyDiff{status: status, line: &1})
  end

  @doc false
  def format_key_line(key_type, key_base64, nil), do: "#{key_type} #{key_base64}"
  def format_key_line(key_type, key_base64, ""), do: "#{key_type} #{key_base64}"
  def format_key_line(key_type, key_base64, label), do: "#{key_type} #{key_base64} #{label}"

  defp parse_authorized_keys(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  ## Expected-state queries

  defp expected_logins(host_id) do
    Repo.all(
      from a in Authorization,
        where: a.host_id == ^host_id,
        distinct: true,
        select: a.login
    )
  end

  @doc false
  def expected_keys_for_login(host_id, login) do
    user_ids =
      Repo.all(
        from a in Authorization,
          where: a.host_id == ^host_id and a.login == ^login,
          select: a.user_id
      )

    case user_ids do
      [] ->
        []

      ids ->
        Repo.all(
          from k in UserKey,
            where: k.user_id in ^ids,
            select: {k.key_type, k.key_base64, k.name}
        )
        |> Enum.map(fn {type, base64, name} -> format_key_line(type, base64, name) end)
    end
  end

  defp ensure_not_disabled(%Host{disabled: true, name: name}),
    do: {:error, {:host_disabled, "host #{inspect(name)} is disabled"}}

  defp ensure_not_disabled(%Host{}), do: :ok
end
