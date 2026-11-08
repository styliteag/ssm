defmodule Ssm.Diffs.Notes do
  @moduledoc """
  The notes of one login's diff (`Ssm.Diffs.LoginDiff`) as a flat list —
  what the diff page shows as badges and item notes, for `/api/v2` clients.
  Each note is `%{kind, text, line}`: `kind` is stable (`unsafe`,
  `revocation_blocked`, `readonly_ignored`, `drops_host_restriction`,
  `invalid_stored_options`, `note`), `text` is the page's wording, `line`
  the key line an item note belongs to (nil for a login-wide note).
  """

  alias Ssm.Diffs.{KeyDiff, LoginDiff}

  @type t :: %{kind: String.t(), text: String.t(), line: String.t() | nil}

  @doc "Login-wide notes first (unsafe, blocked, ignored marker), then item notes in item order."
  @spec of(LoginDiff.t()) :: [t()]
  def of(%LoginDiff{} = login) do
    login_notes =
      [
        {"unsafe", login.unsafe},
        {"revocation_blocked", login.blocked},
        {"readonly_ignored", login.readonly_ignored && "ignored: " <> login.readonly_ignored}
      ]
      |> Enum.reject(fn {_kind, text} -> is_nil(text) end)
      |> Enum.map(fn {kind, text} -> %{kind: kind, text: text, line: nil} end)

    login_notes ++ Enum.flat_map(login.items, &item_notes/1)
  end

  # Compare.note_extras joins several notes of one item with "; "
  defp item_notes(%KeyDiff{note: nil}), do: []

  defp item_notes(%KeyDiff{note: note, line: line}) do
    note
    |> String.split("; ")
    |> Enum.map(&%{kind: kind(&1), text: &1, line: line})
  end

  defp kind("drops host restriction" <> _), do: "drops_host_restriction"
  defp kind("invalid stored options" <> _), do: "invalid_stored_options"
  defp kind("revocation blocked" <> _), do: "revocation_blocked"
  defp kind(_text), do: "note"
end
