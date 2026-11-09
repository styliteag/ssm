defmodule Ssm.Ssh.ScriptRunner do
  @moduledoc """
  Drive `script.sh` on the remote host for every authorized_keys op — port of
  ssh/script_runner.py. The script itself (priv/ssh/script.sh) is carried
  over from the python stack VERBATIM; it handles home-directory lookup via
  getent (BSD/TrueNAS/pfSense), the readonly probe + vendor fingerprints, and
  has_pragma detection.

  All writes to authorized_keys MUST go through `set_authorized_keyfile/4` —
  never `write_file` directly — so the script can back up handwritten files
  and enforce the readonly flag.
  """

  require Logger

  alias Ssm.Authorizations.Login
  alias Ssm.Ssh.{Result, Shell, Target}

  @remote_path ".ssm/script.sh"
  # remote stderr/stdout quoted in an error message (flash, API) is capped
  @max_output 500

  defmodule LoginKeyfile do
    @moduledoc "One login's authorized_keys as reported by script.sh."
    @enforce_keys [:login, :has_pragma, :keyfile]
    defstruct [
      :login,
      :has_pragma,
      :readonly_condition,
      :readonly_scope,
      :readonly_ignored,
      :unsafe,
      :sha256,
      :keyfile,
      :home_state
    ]

    @type t :: %__MODULE__{
            login: String.t(),
            has_pragma: boolean(),
            readonly_condition: String.t() | nil,
            readonly_scope: :user | :host | nil,
            readonly_ignored: String.t() | nil,
            unsafe: String.t() | nil,
            sha256: String.t() | nil,
            keyfile: String.t(),
            home_state: String.t() | nil
          }
  end

  @doc "Upload / refresh the script if the remote copy is missing or stale."
  @spec ensure_uploaded(module(), Target.t()) :: :ok | {:error, term()}
  def ensure_uploaded(client \\ Ssm.Ssh, target) do
    probe_cmd = "sh #{Shell.quote(@remote_path)} version 2>/dev/null || true"

    with {:ok, %Result{} = probe} <- client.exec(target, probe_cmd, []) do
      if remote_current?(probe.stdout) do
        :ok
      else
        upload(client, target)
      end
    end
  end

  defp remote_current?(stdout) do
    case Jason.decode(String.trim(stdout)) do
      {:ok, %{"sha256" => sha}} -> sha == script_sha256()
      _ -> false
    end
  end

  defp upload(client, target) do
    dir = @remote_path |> Path.dirname() |> Shell.quote()

    command =
      "mkdir -p #{dir} && cat > #{Shell.quote(@remote_path)} && chmod 0700 #{Shell.quote(@remote_path)}"

    case client.exec(target, command, input: script_source()) do
      {:ok, %Result{exit_code: 0}} ->
        :ok

      {:ok, %Result{} = result} ->
        {:error,
         {:ssh_connect_failed, "script upload failed on #{target.name}: #{output(result.stderr)}"}}

      {:error, _} = error ->
        error
    end
  end

  @doc "One `LoginKeyfile` per login that has an authorized_keys file."
  @spec get_ssh_keyfiles(module(), Target.t()) :: {:ok, [LoginKeyfile.t()]} | {:error, term()}
  def get_ssh_keyfiles(client \\ Ssm.Ssh, target, logins \\ []) do
    # logins ssm expects: an unreachable home comes back with "home_state"
    asked =
      logins
      |> Enum.filter(&Login.host_safe?/1)
      |> Enum.uniq()
      |> Enum.map_join("", &(" " <> Shell.quote(&1)))

    with :ok <- ensure_uploaded(client, target),
         {:ok, %Result{} = result} <-
           client.exec(target, "sh #{Shell.quote(@remote_path)} get_ssh_keyfiles" <> asked, []) do
      cond do
        result.exit_code != 0 ->
          {:error,
           {:ssh_connect_failed,
            "script.sh get_ssh_keyfiles failed on #{target.name}: #{output(result.stderr)}"}}

        String.trim(result.stdout) == "" ->
          {:ok, []}

        true ->
          parse_keyfiles(result.stdout, target)
      end
    end
  end

  # A user-writable authorized_keys or user_readonly may hold bytes that are
  # not UTF-8 (a Latin-1 comment); script.sh only emits them inside JSON
  # strings, so replacing them (U+FFFD) keeps the JSON valid and the host
  # readable. Keys compare by type and base64, so only a comment changes.
  defp parse_keyfiles(stdout, target) do
    case stdout |> String.replace_invalid() |> String.trim() |> Jason.decode() do
      {:ok, entries} when is_list(entries) ->
        {:ok, entries |> Enum.filter(&valid_entry?(&1, target)) |> Enum.map(&parse_entry/1)}

      {:ok, _other} ->
        {:error, {:ssh_connect_failed, "script.sh returned non-list on #{target.name}"}}

      {:error, error} ->
        {:error,
         {:ssh_connect_failed, "script.sh returned non-JSON on #{target.name}: #{inspect(error)}"}}
    end
  end

  # The listing comes from the host: an entry of another shape, or whose
  # login ssm would never pass back to the host (`Ssm.Authorizations.Login`),
  # is dropped (and logged) — the diff, sync and people jobs act only on
  # well-formed entries.
  defp valid_entry?(raw, target) do
    valid =
      is_map(raw) and Login.host_safe?(raw["login"]) and is_binary(Map.get(raw, "keyfile", "")) and
        is_boolean(Map.get(raw, "has_pragma", false)) and
        Enum.all?(~w(readonly_condition readonly_scope readonly_ignored unsafe), fn field ->
          value = raw[field]
          is_nil(value) or is_binary(value)
        end)

    if not valid do
      Logger.warning("script.sh listing on #{target.name}: dropped a malformed entry")
    end

    valid
  end

  defp parse_entry(raw) do
    readonly =
      case raw["readonly_condition"] do
        value when value in [nil, ""] -> nil
        value -> value
      end

    %LoginKeyfile{
      login: raw["login"],
      has_pragma: raw["has_pragma"] == true,
      readonly_condition: readonly,
      readonly_scope: readonly_scope(readonly, raw["readonly_scope"]),
      # a user_readonly the login's user owns: not honoured, but reported
      readonly_ignored: blank_to_nil(raw["readonly_ignored"]),
      # "symlink" | "hardlink" | "special": not read (keyfile empty), not written
      unsafe: blank_to_nil(raw["unsafe"]),
      # sha256 of the file as read (passed back by a write: stale check)
      sha256: sha(raw["sha256"]),
      # script.sh (json_escape) emits a proper JSON string: backslashes,
      # quotes and newlines arrive decoded; nothing to unescape here.
      keyfile: raw |> Map.get("keyfile", "") |> to_string(),
      # unknown_login | home_missing | home_unreadable: the home is not there
      home_state: home_state(raw["home_state"])
    }
  end

  defp home_state(value) when value in ~w(unknown_login home_missing home_unreadable), do: value
  defp home_state(_value), do: nil

  # host output goes into a command line: 64 hex digits or nothing
  defp sha(value) when is_binary(value),
    do: if(Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: value)

  defp sha(_value), do: nil

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: to_string(value)

  # `user_readonly` affects one login only; every other marker (and one an
  # older script does not classify) is host-wide
  defp readonly_scope(nil, _scope), do: nil
  defp readonly_scope(_readonly, "user"), do: :user
  defp readonly_scope(_readonly, _scope), do: :host

  @doc """
  Replace `login`'s authorized_keys with `content`. The script enforces the
  readonly sentinel itself; its refusal surfaces as `{:error, {:ssh_readonly,
  reason}}`.

  The SSH user (`target.username`) is passed along: the script refuses a
  login that is not the SSH user but resolves to its home (a uid-0 alias
  like `toor` in root's home) — `Keyfile is unsafe (shared_home)` — since
  that file holds ssm's own key. A target without SSH user is refused
  before any SSH (the check would be impossible); so does the script for
  an SSH user it does not know (`unsafe (ssh_user)`).

  `opts[:expected_sha256]` (from `LoginKeyfile.sha256`) makes the script
  refuse a file that changed since it was read: `{:error, {:ssh_stale, _}}`.
  """
  @spec set_authorized_keyfile(module(), Target.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def set_authorized_keyfile(client \\ Ssm.Ssh, target, login, content, opts \\ [])

  def set_authorized_keyfile(_client, %Target{username: user} = target, login, _content, _opts)
      when user in [nil, ""] do
    {:error,
     {:ssh_unsafe,
      "host #{inspect(target.name)} has no SSH user; refusing to write #{inspect(login)}"}}
  end

  def set_authorized_keyfile(client, target, login, content, opts) do
    command =
      Enum.join(
        ["sh #{Shell.quote(@remote_path)} set_authorized_keyfile", Shell.quote(login)] ++
          [Shell.quote(target.username)] ++ List.wrap(sha(opts[:expected_sha256])),
        " "
      )

    with :ok <- ensure_uploaded(client, target),
         {:ok, %Result{} = result} <- client.exec(target, command, input: content) do
      cond do
        result.exit_code == 0 ->
          :ok

        # script.sh refuses symlinked/hardlinked files (root write-through)
        unsafe_refusal?(result) ->
          {:error,
           {:ssh_unsafe,
            "host #{inspect(target.name)} refused write for #{inspect(login)}: " <>
              refusal_reason(result)}}

        # the file changed on the host since the listing read it
        result |> refusal_reason() |> String.contains?("(stale)") ->
          {:error,
           {:ssh_stale,
            "host #{inspect(target.name)} refused write for #{inspect(login)}: " <>
              refusal_reason(result)}}

        readonly_refusal?(result) ->
          {:error,
           {:ssh_readonly,
            "host #{inspect(target.name)} refused write for #{inspect(login)}: " <>
              refusal_reason(result)}}

        true ->
          {:error,
           {:ssh_connect_failed,
            "script.sh set_authorized_keyfile failed on #{target.name}: " <>
              refusal_reason(result)}}
      end
    end
  end

  # both streams, the script's own stdout first: a login shell on the host
  # may print to stderr (motd, agent banners) and must not hide the reason
  defp refusal_reason(%Result{} = result) do
    [output(result.stdout), output(result.stderr)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" | ")
  end

  # remote text for a message: trimmed, invalid UTF-8 replaced, capped
  defp output(text) do
    text = text |> to_string() |> String.replace_invalid() |> String.trim()

    if String.length(text) > @max_output,
      do: String.slice(text, 0, @max_output) <> "… (truncated)",
      else: text
  end

  defp unsafe_refusal?(%Result{} = result),
    do: result |> refusal_reason() |> String.contains?("Keyfile is unsafe")

  defp readonly_refusal?(%Result{} = result) do
    result |> refusal_reason() |> String.downcase() |> String.contains?("readonly")
  end

  @doc """
  Whether the host has an `authorized_keys` entry for `login` (any file or
  link there, or a linked `~/.ssh`): `{:ok, boolean}`. A login getent does
  not know or a missing home is `unknown` — like anything but a clear
  answer, an error.
  """
  @spec has_keyfile(module(), Target.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def has_keyfile(client \\ Ssm.Ssh, target, login) do
    command = "sh #{Shell.quote(@remote_path)} has_keyfile #{Shell.quote(login)}"

    with :ok <- ensure_uploaded(client, target),
         {:ok, %Result{} = result} <- client.exec(target, command, []) do
      case {result.exit_code, String.trim(result.stdout)} do
        {0, "yes"} ->
          {:ok, true}

        {0, "no"} ->
          {:ok, false}

        _ ->
          {:error,
           {:ssh_connect_failed,
            "script.sh has_keyfile failed on #{target.name}: " <> refusal_reason(result)}}
      end
    end
  end

  @doc "The remote script's `{version, sha256}` self-report."
  @spec version(module(), Target.t()) :: {:ok, map()} | {:error, term()}
  def version(client \\ Ssm.Ssh, target) do
    with {:ok, %Result{} = result} <-
           client.exec(target, "sh #{Shell.quote(@remote_path)} version", []) do
      if result.exit_code == 0 do
        case Jason.decode(String.trim(result.stdout)) do
          {:ok, payload} when is_map(payload) ->
            {:ok, payload}

          _ ->
            {:error, {:ssh_connect_failed, "script.sh version non-JSON on #{target.name}"}}
        end
      else
        {:error,
         {:ssh_connect_failed,
          "script.sh version failed on #{target.name}: #{output(result.stderr)}"}}
      end
    end
  end

  @doc "Local script source (priv/ssh/script.sh, verbatim from the python stack)."
  @spec script_source() :: String.t()
  def script_source do
    File.read!(Application.app_dir(:ssm, ["priv", "ssh", "script.sh"]))
  end

  @doc "SHA-256 of the local script, hex-encoded."
  @spec script_sha256() :: String.t()
  def script_sha256 do
    :crypto.hash(:sha256, script_source()) |> Base.encode16(case: :lower)
  end
end
