defmodule Ssm.ControlChars do
  @moduledoc """
  Control characters (`\\p{Cc}`, Unicode line separators, bidi and BOM
  controls) in text that ends up in an authorized_keys line or an audit
  line. A newline in a key comment or a
  login would start a second line on the host — an injected key — so these
  fields refuse them everywhere (changesets, `/api/v2` params) and the line
  renderer (`Ssm.Diffs.KeyLine`) refuses stored rows that still carry one.
  """

  import Ecto.Changeset

  @message "must not contain control characters"
  # C0/C1 controls, Unicode line/paragraph separators, bidi embeddings,
  # overrides, isolates and marks (LRM, RLM, ALM), zero-width characters
  # (ZWSP, ZWNJ, ZWJ, word joiner) and the zero-width no-break space (BOM)
  @pattern ~r/[\p{Cc}\p{Zl}\p{Zp}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}\x{2066}-\x{2069}\x{061C}\x{FEFF}]/u

  @doc """
  True when `value` is a string holding a control character, a Unicode
  line/paragraph separator or a bidi/BOM control — or is not valid UTF-8
  (fails closed: such bytes cannot be checked).
  """
  @spec present?(term()) :: boolean()
  def present?(value) when is_binary(value),
    do: not String.valid?(value) or Regex.match?(@pattern, value)

  def present?(_value), do: false

  @doc "`:ok` or `{:error, message}` — the `/api/v2` params check."
  @spec check(term()) :: :ok | {:error, String.t()}
  def check(value), do: if(present?(value), do: {:error, @message}, else: :ok)

  @doc """
  `value` without the characters `present?/1` refuses (invalid UTF-8 bytes
  become U+FFFD first) — for text read from elsewhere (a host, an identity
  provider) that is shown or stored, not written to a host.
  """
  @spec strip(String.t()) :: String.t()
  def strip(value) when is_binary(value),
    do: value |> String.replace_invalid() |> then(&Regex.replace(@pattern, &1, ""))

  @doc "Add a changeset error to every field in `fields` that holds a control character."
  @spec validate(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def validate(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      validate_change(acc, field, fn ^field, value ->
        if present?(value), do: [{field, @message}], else: []
      end)
    end)
  end
end
