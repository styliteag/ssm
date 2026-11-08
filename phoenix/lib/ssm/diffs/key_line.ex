defmodule Ssm.Diffs.KeyLine do
  @moduledoc """
  Renders one expected authorized_keys line from the database:
  `[<options> ]<type> <base64>[ <comment>]`.

  The last line of defence against line injection: a stored row whose key
  type, key material, comment or options holds a control character, or
  whose options fail `Ssm.Authorizations.Options.validate/1`, is never
  rendered — even when it predates the input validation.
  """

  alias Ssm.Authorizations.Options
  alias Ssm.ControlChars

  @type entry :: %{
          required(:key_type) => String.t(),
          required(:key_base64) => String.t(),
          required(:name) => String.t() | nil,
          required(:options) => String.t() | nil
        }

  @doc """
  Render one row:

    * `{:ok, line}`
    * `{:ok, line, :comment_dropped}` — the comment (`name`) fails
      `Ssm.ControlChars` (legacy tab, C1, Latin-1 bytes): the key is written
      without it, so its owner is not locked out
    * `{:error, :invalid_options}` — options that fail today's rules
      (control characters included); the caller may keep the host's line of
      that key instead (`format/3` with a clean comment gives the line
      without options)
    * `{:error, :control_chars}` — in the key type or material: never
      written in any form
  """
  @spec render(entry()) ::
          {:ok, String.t()}
          | {:ok, String.t(), :comment_dropped}
          | {:error, :control_chars | :invalid_options}
  def render(%{key_type: type, key_base64: base64, name: name, options: options}) do
    cond do
      ControlChars.present?(type) or ControlChars.present?(base64) ->
        {:error, :control_chars}

      match?({:error, _}, Options.validate(options)) ->
        {:error, :invalid_options}

      ControlChars.present?(name) ->
        {:ok, prefix(options) <> format(type, base64, nil), :comment_dropped}

      true ->
        {:ok, prefix(options) <> format(type, base64, name)}
    end
  end

  @doc "The comment to write for `name`: nil when it fails `Ssm.ControlChars`."
  @spec clean_name(String.t() | nil) :: String.t() | nil
  def clean_name(name), do: if(ControlChars.present?(name), do: nil, else: name)

  @doc "A key line without options: `<type> <base64>[ <comment>]`."
  @spec format(String.t(), String.t(), String.t() | nil) :: String.t()
  def format(key_type, key_base64, nil), do: "#{key_type} #{key_base64}"
  def format(key_type, key_base64, ""), do: "#{key_type} #{key_base64}"
  def format(key_type, key_base64, label), do: "#{key_type} #{key_base64} #{label}"

  defp prefix(nil), do: ""

  defp prefix(options) do
    case String.trim(options) do
      "" -> ""
      trimmed -> trimmed <> " "
    end
  end
end
