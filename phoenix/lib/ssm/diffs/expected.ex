defmodule Ssm.Diffs.Expected do
  @moduledoc """
  What the database expects on a host: the logins a sync covers and the
  rendered authorized_keys lines of one login (`Ssm.Diffs.KeyLine`).

  Only enabled ssm users count: a disabled user's keys are never expected,
  so a sync removes them. A stored row with control characters in the key
  is refused (never written); one with a bad comment is written without
  the comment; a legacy row whose options fail today's rules is kept apart
  (`legacy`) so the caller can keep the host's line of that key.
  """

  import Ecto.Query

  alias Ssm.Authorizations
  alias Ssm.Authorizations.Authorization
  alias Ssm.Diffs.KeyLine
  alias Ssm.Repo
  alias Ssm.Users.{User, UserKey}

  require Logger

  @type refused :: %{key_id: integer(), reason: String.t()}
  @type legacy :: %{key_id: integer(), id: {String.t(), String.t()}, line: String.t()}
  @type t :: %{lines: [String.t()], refused: [refused()], legacy: [legacy()]}

  @doc "Logins with at least one grant on the host."
  @spec logins(integer()) :: [String.t()]
  def logins(host_id) do
    Repo.all(
      from a in Authorization, where: a.host_id == ^host_id, distinct: true, select: a.login
    )
  end

  @doc """
  The logins a sync writes: every granted login, plus every managed login
  without a grant that still has a file on the host (`on_host` is keyed by
  login; where there is no file there is nothing to revoke).
  """
  @spec logins_to_sync(integer(), map()) :: [String.t()]
  def logins_to_sync(host_id, on_host) do
    leftover =
      host_id |> Authorizations.managed_logins() |> Enum.filter(&Map.has_key?(on_host, &1))

    (logins(host_id) ++ leftover) |> Enum.uniq() |> Enum.sort()
  end

  @doc "The expected lines of `login` on the host, plus refused and legacy rows."
  @spec lines(integer(), String.t()) :: t()
  def lines(host_id, login) do
    host_id
    |> rows(login)
    |> Enum.reduce(%{lines: [], refused: [], legacy: []}, &classify(&1, &2, {host_id, login}))
    |> Map.new(fn {key, list} -> {key, Enum.reverse(list)} end)
  end

  defp classify(row, acc, where) do
    case KeyLine.render(row) do
      {:ok, line} ->
        %{acc | lines: [line | acc.lines]}

      {:ok, line, :comment_dropped} ->
        log(:warning, row, where, "control characters in the comment; written without it")
        %{acc | lines: [line | acc.lines]}

      {:error, :control_chars} ->
        log(:error, row, where, "control characters in the key; refused")
        %{acc | refused: [%{key_id: row.key_id, reason: "control characters"} | acc.refused]}

      {:error, :invalid_options} ->
        log(:warning, row, where, "invalid stored options; the host's line is kept")
        %{acc | legacy: [legacy(row) | acc.legacy]}
    end
  end

  defp legacy(row) do
    %{
      key_id: row.key_id,
      id: {row.key_type, row.key_base64},
      line: KeyLine.format(row.key_type, row.key_base64, KeyLine.clean_name(row.name))
    }
  end

  defp log(level, row, {host_id, login}, text) do
    Logger.log(
      level,
      "diffs: stored key id=#{row.key_id} host_id=#{host_id} login=#{inspect(login)}: #{text}"
    )
  end

  defp rows(host_id, login) do
    Repo.all(
      from k in UserKey,
        join: u in User,
        on: u.id == k.user_id,
        join: a in Authorization,
        on: a.user_id == u.id,
        where: a.host_id == ^host_id and a.login == ^login and u.enabled == true,
        order_by: k.id,
        select: %{
          key_id: k.id,
          key_type: k.key_type,
          key_base64: k.key_base64,
          name: k.name,
          options: a.options
        }
    )
  end
end
