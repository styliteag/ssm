defmodule Ssm.Diffs.SyncCheck do
  @moduledoc """
  Pure: turns a `Ssm.Diffs.HostDiff` into what the periodic key check
  stores (`result/2`) and into the status the diff page shows (`status/1`).

  The stored drift never contains key material: a key is labelled by its
  type, SHA256 fingerprint and comment. A line that is not a plain key line
  (authorized_keys options, odd text) is labelled `"unparsable key line"`
  and nothing of it is kept. A drift entry whose extra keys a sync cannot
  remove (the login's `user_readonly`) carries `"blocked"`. Read failures are reduced to a fixed sentence
  (`Ssm.Ssh.ErrorCode`); the raw text (addresses, SSH output) stays out.
  """

  alias Ssm.Diffs.{HostDiff, LoginDiff}
  alias Ssm.Ssh.ErrorCode
  alias Ssm.Users.UserKey

  @type entry :: %{String.t() => String.t() | [String.t()] | nil}
  @type result :: %{
          state: String.t(),
          logins: non_neg_integer(),
          drift: [entry()],
          error_code: String.t() | nil,
          error: String.t() | nil
        }

  @unparsable "unparsable key line"
  @blocked "revocation blocked by user_readonly"

  @doc """
  The check result of a diff. `owners` maps a key's base64 to the name of
  the ssm user who owns it (`%{}` when unknown).
  """
  @spec result(HostDiff.t(), %{String.t() => String.t()}) :: result()
  def result(%HostDiff{logins: logins} = diff, owners) do
    case read_error(diff) do
      nil -> compared(logins, owners)
      raw -> failed(raw, length(logins))
    end
  end

  @doc """
  The diff page's status of a diff: `:synced`, `{:needs_sync, missing,
  extra}` or `{:error, text}` (the raw read error, for operators).
  """
  @spec status(HostDiff.t()) ::
          :synced | {:needs_sync, non_neg_integer(), non_neg_integer()} | {:error, String.t()}
  def status(%HostDiff{logins: logins} = diff) do
    case read_error(diff) do
      nil ->
        items = Enum.flat_map(logins, & &1.items)
        missing = Enum.count(items, &(&1.status == :missing_on_host))
        extra = Enum.count(items, &(&1.status == :extra_on_host))
        if missing + extra == 0, do: :synced, else: {:needs_sync, missing, extra}

      raw ->
        {:error, raw}
    end
  end

  # a blocked login (unsafe ~/.ssh) is not read on purpose: drift, not error
  defp read_error(%HostDiff{read_error: nil, logins: logins}),
    do: Enum.find_value(logins, &(is_nil(&1.blocked) && &1.read_error))

  defp read_error(%HostDiff{read_error: raw}), do: raw

  defp failed(raw, login_count) do
    {code, sentence} = ErrorCode.classify({:ssh_connect_failed, raw})
    %{state: "error", logins: login_count, drift: [], error_code: code, error: sentence}
  end

  defp compared(logins, owners) do
    drift = Enum.flat_map(logins, &(login_entries(&1, owners) ++ blocked_entry(&1)))

    %{
      state: if(drift == [], do: "synced", else: "drift"),
      logins: length(logins),
      drift: drift,
      error_code: nil,
      error: nil
    }
  end

  defp login_entries(%LoginDiff{login: login, items: items}, owners) do
    items
    |> Enum.filter(&(&1.status in [:missing_on_host, :extra_on_host]))
    |> Enum.group_by(&owner(&1.line, owners))
    |> Enum.sort_by(fn {user, _} -> {is_nil(user), user} end)
    |> Enum.map(fn {user, group} ->
      %{
        "user" => user,
        "login" => login,
        "missing" => labels(group, :missing_on_host),
        "extra" => labels(group, :extra_on_host)
      }
      |> with_blocked(group)
    end)
  end

  # a login a sync cannot write at all (unsafe ~/.ssh): its revocation is
  # blocked whatever its keys are
  defp blocked_entry(%LoginDiff{blocked: nil}), do: []

  defp blocked_entry(%LoginDiff{login: login, blocked: blocked}),
    do: [%{"user" => nil, "login" => login, "missing" => [], "extra" => [], "blocked" => blocked}]

  # a user_readonly marker keeps the sync from removing these extra keys
  defp with_blocked(entry, group) do
    case Enum.find(group, &(&1.note && &1.note =~ @blocked)) do
      nil -> entry
      _item -> Map.put(entry, "blocked", @blocked)
    end
  end

  defp labels(items, status),
    do: for(i <- items, i.status == status, do: label(i.line))

  defp owner(line, owners) do
    case tokens(line) do
      [_type, base64 | _] -> Map.get(owners, base64)
      _ -> nil
    end
  end

  defp label(line) do
    case tokens(line) do
      [type, base64 | rest] ->
        "#{type} #{fingerprint(base64)}#{comment(rest)}"

      _ ->
        @unparsable
    end
  end

  defp tokens(line) do
    case String.split(String.trim(line), ~r/\s+/, parts: 3) do
      [type | _] = parts -> if type in UserKey.key_types(), do: parts
      _ -> nil
    end
  end

  defp comment([comment]) when comment != "", do: " (#{String.trim(comment)})"
  defp comment(_), do: ""

  # OpenSSH style SHA256 fingerprint of the key blob; text that is no valid
  # base64 is hashed as is (still not reversible, still stable).
  defp fingerprint(base64) do
    blob =
      with :error <- Base.decode64(base64),
           :error <- Base.decode64(base64, padding: false) do
        base64
      else
        {:ok, decoded} -> decoded
      end

    "SHA256:" <> Base.encode64(:crypto.hash(:sha256, blob), padding: false)
  end
end
