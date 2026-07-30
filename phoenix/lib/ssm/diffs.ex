defmodule Ssm.Diffs do
  @moduledoc """
  Compare a host's on-disk `authorized_keys` to what the database authorizes,
  and push the DB state to the host — port of api/v2/diffs.py.

  Every read/write goes through `Ssm.Ssh.ScriptRunner` (never raw SFTP), so
  home-dir probing, `has_pragma` detection, the readonly sentinel and managed
  backups all come for free. Disabled hosts short-circuit before any SSH.
  """

  import Ecto.Query

  alias Ssm.Authorizations.Authorization
  alias Ssm.Hosts
  alias Ssm.Hosts.Host
  alias Ssm.Repo
  alias Ssm.Ssh.ScriptRunner
  alias Ssm.Users.UserKey

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
    defstruct [:host_id, :host_name, :disabled, logins: []]
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

      logins =
        Enum.map(all_logins, fn login ->
          build_login_diff(host_id, login, Map.get(observed, login), read_error)
        end)

      {:ok,
       %HostDiff{host_id: host.id, host_name: host.name, disabled: host.disabled, logins: logins}}
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
         :ok <- ensure_not_disabled(host) do
      target = Hosts.target_for(host)

      host_id
      |> expected_logins()
      |> Enum.sort()
      |> sync_logins(client, target, host_id, [])
    end
  end

  defp sync_logins([], _client, _target, _host_id, acc), do: {:ok, Enum.reverse(acc)}

  defp sync_logins([login | rest], client, target, host_id, acc) do
    expected = expected_keys_for_login(host_id, login)
    content = Enum.map_join(expected, "", &(&1 <> "\n"))

    case ScriptRunner.set_authorized_keyfile(client, target, login, content) do
      :ok ->
        synced = %SyncedLogin{login: login, written_keys: length(expected)}
        sync_logins(rest, client, target, host_id, [synced | acc])

      {:error, _} = error ->
        error
    end
  end

  ## Diff building

  defp build_login_diff(host_id, login, entry, read_error) do
    expected = expected_keys_for_login(host_id, login)
    actual = if entry, do: parse_authorized_keys(entry.keyfile), else: []

    %LoginDiff{
      login: login,
      has_pragma: !!(entry && entry.has_pragma),
      readonly_condition: entry && entry.readonly_condition,
      read_error: if(is_nil(entry) && read_error, do: read_error),
      items: compute_diff(expected, actual)
    }
  end

  @doc false
  def compute_diff(expected, actual) do
    exp = MapSet.new(expected)
    act = MapSet.new(actual)

    present = exp |> MapSet.intersection(act) |> to_sorted(:present)
    missing = exp |> MapSet.difference(act) |> to_sorted(:missing_on_host)
    extra = act |> MapSet.difference(exp) |> to_sorted(:extra_on_host)

    present ++ missing ++ extra
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
