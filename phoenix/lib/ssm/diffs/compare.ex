defmodule Ssm.Diffs.Compare do
  @moduledoc """
  Pure comparison of a login's expected lines (`Ssm.Diffs.Expected`) with the
  lines on the host, and the lines a sync writes.

  Lines are compared by their key (`KeyParser.identity/1`, read as sshd reads
  the line: type + base64 after the options), never as whole lines: the
  comment on the host (or ssm's key name) and an options prefix do not make
  a granted key "missing" and "not authorized" at once. A present key shows
  the host's line. A line without a key compares as its trimmed text.

  Options policy: a DB line with options (the grant's `options`) wins — the
  host line must carry the same options, else the DB line is missing and
  the host line extra; a host line whose restricting options the DB lacks
  is marked "drops host restriction: …". A DB line without options keeps
  the host's line of that key, so options typed by hand on the host survive.
  """

  alias Ssm.Authorizations.Options
  alias Ssm.Diffs.KeyDiff
  alias Ssm.Users.KeyParser

  @invalid_options "invalid stored options"

  @doc "Diff items of `expected` against `actual` (both lists of lines)."
  @spec diff([String.t()], [String.t()]) :: [KeyDiff.t()]
  def diff(expected, actual) do
    exp = index_by_key(expected)
    act = index_by_key(actual)
    same? = fn id -> both_have?(exp, act, id) and options_match?(exp[id], act[id]) end

    present = for {id, line} <- act, same?.(id), do: {line, nil}
    missing = for {id, line} <- exp, not same?.(id), do: {line, nil}
    extra = for {id, line} <- act, not same?.(id), do: {line, dropped_note(exp[id], line)}

    items(present, :present) ++ items(missing, :missing_on_host) ++ items(extra, :extra_on_host)
  end

  @doc """
  Items for legacy rows (`Expected` `legacy`): the host's line of that key is
  `:present`, a key the host lacks is `:missing_on_host`; both carry the note
  "invalid stored options". Returns `{items, actual without those lines}`.
  """
  @spec legacy_items([map()], [String.t()]) :: {[KeyDiff.t()], [String.t()]}
  def legacy_items(legacy, actual) do
    act = index_by_key(actual)
    ids = MapSet.new(legacy, & &1.id)

    items =
      Enum.map(legacy, fn entry ->
        case Map.fetch(act, entry.id) do
          {:ok, line} -> %KeyDiff{status: :present, line: line, note: @invalid_options}
          :error -> %KeyDiff{status: :missing_on_host, line: entry.line, note: @invalid_options}
        end
      end)

    {items, Enum.reject(actual, &MapSet.member?(ids, key_id(&1)))}
  end

  @doc """
  The lines a sync writes for a login: one per key, never a key twice, each
  DB line or — by the options policy — the host's line of that key; then the
  host's line of every legacy row whose key is not written already (a legacy
  key the host lacks is skipped).
  """
  @spec lines_to_write([String.t()], [map()], [String.t()]) :: [String.t()]
  def lines_to_write(expected, legacy, host_lines) do
    on_host = index_by_key(host_lines)

    db_lines =
      expected
      |> index_by_key()
      |> Enum.sort_by(fn {_id, line} -> Enum.find_index(expected, &(&1 == line)) end)
      |> Enum.map(fn {id, line} -> keep_host_line(line, Map.get(on_host, id)) end)

    written = MapSet.new(db_lines, &key_id/1)

    legacy_lines =
      legacy
      |> Enum.map(&Map.get(on_host, &1.id))
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(written, key_id(&1))))

    db_lines ++ legacy_lines
  end

  @doc """
  Mark every `:extra_on_host` item with `note` (kept: an existing note is
  extended) — e.g. a login whose removals a `user_readonly` marker blocks.
  """
  @spec note_extras([KeyDiff.t()], String.t()) :: [KeyDiff.t()]
  def note_extras(items, note) do
    Enum.map(items, fn
      %KeyDiff{status: :extra_on_host, note: nil} = item -> %{item | note: note}
      %KeyDiff{status: :extra_on_host} = item -> %{item | note: item.note <> "; " <> note}
      item -> item
    end)
  end

  @doc "Items with one status, sorted by line, without notes."
  @spec to_sorted(Enumerable.t(), KeyDiff.status()) :: [KeyDiff.t()]
  def to_sorted(lines, status), do: lines |> Enum.map(&{&1, nil}) |> items(status)

  defp items(pairs, status) do
    pairs
    |> Enum.sort()
    |> Enum.map(fn {line, note} -> %KeyDiff{status: status, line: line, note: note} end)
  end

  # %{key identity => first line with that key}
  defp index_by_key(lines) do
    Enum.reduce(lines, %{}, fn line, acc -> Map.put_new(acc, key_id(line), line) end)
  end

  defp key_id(line), do: KeyParser.identity(line) || {:line, String.trim(line)}

  defp both_have?(exp, act, id), do: Map.has_key?(exp, id) and Map.has_key?(act, id)

  # an expected line without options accepts any options on the host
  defp options_match?(expected_line, host_line) do
    case KeyParser.options(expected_line) do
      "" -> true
      options -> options == KeyParser.options(host_line)
    end
  end

  defp keep_host_line(db_line, nil), do: db_line

  defp keep_host_line(db_line, host_line),
    do: if(KeyParser.options(db_line) == "", do: host_line, else: db_line)

  defp dropped_note(nil, _host_line), do: nil

  defp dropped_note(db_line, host_line) do
    case Options.dropped_restrictions(KeyParser.options(host_line), KeyParser.options(db_line)) do
      [] -> nil
      names -> "drops host restriction: " <> Enum.join(names, ", ")
    end
  end
end
