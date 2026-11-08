defmodule Ssm.Users.KeyParser do
  @moduledoc """
  Pure parser for authorized_keys-style public key lines
  (`type base64 [comment]`), the LiveView counterpart of the React
  KeysPage's `SSH_KEY_REGEX` + `parseSSHKey`.

  Beyond token splitting it verifies the SSH wire format (RFC 4253 §6.6):
  the base64 payload must decode, and the decoded blob must start with a
  length-prefixed copy of the declared type string.
  """

  alias Ssm.Users.UserKey

  # sshd separates the fields of a key line by spaces and tabs only
  @fields ~r/[ \t]+/
  @leading_fields ~r/\A[ \t]+/

  @type parsed :: %{
          key_type: String.t(),
          key_base64: String.t(),
          name: String.t() | nil
        }

  @doc """
  Parse one public key line into `%{key_type, key_base64, name}` where
  `name` is the trailing comment (or `nil`). A line break inside the input
  is refused. Accepted types are exactly
  `Ssm.Users.UserKey.key_types/0` (ssh-rsa, ssh-ed25519, ecdsa-sha2-nistp*,
  ssh-dss, and the sk-* variants).
  """
  @spec parse(String.t()) :: {:ok, parsed()} | {:error, String.t()}
  def parse(line) when is_binary(line) do
    trimmed = String.trim(line)

    # one key, one line: an inner line break would put a second line into
    # authorized_keys (bulk import splits lines before calling this)
    if String.contains?(trimmed, ["\n", "\r"]),
      do: {:error, "a single key must be on one line"},
      else: parse_tokens(trimmed)
  end

  defp parse_tokens(trimmed) do
    case String.split(trimmed, @fields, parts: 3) do
      [""] -> {:error, "empty line"}
      [type] -> with :ok <- check_type(type), do: {:error, "missing base64 key material"}
      [type, base64] -> build(type, base64, nil)
      [type, base64, comment] -> build(type, base64, comment)
    end
  end

  @doc """
  The key of an authorized_keys line as `{type, base64}`, read the way sshd
  reads the line: a line that starts with a key type and material has no
  options; otherwise the options are skipped first (quote-aware, only `\\"`
  escapes, see `split/1`) and the key must follow them. A key type inside a
  quoted option value is never the line's key. Comment, surrounding
  whitespace and CR do not matter. Two lines hold the same key exactly when
  their identities are equal. `nil` when the line holds no key. The
  material is not validated here (see `parse/1`).
  """
  @spec identity(String.t()) :: {String.t(), String.t()} | nil
  def identity(line) when is_binary(line) do
    case split(line) do
      {:ok, _options, key_part} ->
        key_part |> String.split(@fields) |> Enum.take(2) |> List.to_tuple()

      :error ->
        nil
    end
  end

  @doc """
  `parse/1` for an authorized_keys line that may carry an options prefix:
  the options are skipped as sshd skips them, the key and its comment are
  parsed and validated as `parse/1` does.
  """
  @spec parse_authorized_line(String.t()) :: {:ok, parsed()} | {:error, String.t()}
  def parse_authorized_line(line) when is_binary(line) do
    case split(line) do
      {:ok, _options, key_part} -> parse(key_part)
      :error -> parse(line)
    end
  end

  @doc """
  The options prefix of an authorized_keys line exactly as sshd delimits it,
  `""` when the line has none or holds no key.
  """
  @spec options(String.t()) :: String.t()
  def options(line) when is_binary(line) do
    case split(line) do
      {:ok, options, _key_part} -> options
      :error -> ""
    end
  end

  @doc """
  Split an authorized_keys line into `{:ok, options, key_part}` like sshd
  (`sshkey_advance_past_options`): the options end at the first space or
  tab outside double quotes, and only `\\"` escapes a quote. `key_part`
  starts with a known key type followed by material; `:error` when the line
  holds no such key (also for unbalanced quotes).
  """
  @spec split(String.t()) :: {:ok, String.t(), String.t()} | :error
  def split(line) when is_binary(line) do
    trimmed = String.trim(line)

    if key_start?(trimmed) do
      {:ok, "", trimmed}
    else
      with {:ok, options, rest} <- advance(trimmed, "", false),
           true <- key_start?(rest) do
        {:ok, options, rest}
      else
        _ -> :error
      end
    end
  end

  defp key_start?(text) do
    case String.split(text, @fields, parts: 3) do
      [type, _material | _] -> type in UserKey.key_types()
      _ -> false
    end
  end

  defp advance(<<>>, _acc, true), do: :error
  defp advance(<<>>, acc, false), do: {:ok, acc, ""}

  defp advance(<<?\\, ?", rest::binary>>, acc, quoted),
    do: advance(rest, acc <> "\\\"", quoted)

  defp advance(<<?", rest::binary>>, acc, quoted), do: advance(rest, acc <> "\"", not quoted)

  defp advance(<<c, _::binary>> = rest, acc, false) when c in [?\s, ?\t],
    do: {:ok, acc, Regex.replace(@leading_fields, rest, "")}

  defp advance(<<c, rest::binary>>, acc, quoted), do: advance(rest, acc <> <<c>>, quoted)

  defp build(type, base64, comment) do
    with :ok <- check_type(type),
         :ok <- check_material(type, base64) do
      {:ok, %{key_type: type, key_base64: base64, name: normalize_comment(comment)}}
    end
  end

  defp check_type(type) do
    if type in UserKey.key_types() do
      :ok
    else
      {:error, "unsupported key type #{inspect(type)}"}
    end
  end

  @doc """
  `:ok` when `base64` decodes to an SSH wire-format blob of `type`
  (RFC 4253 §6.6), else `{:error, message}`.
  """
  @spec check_material(String.t(), String.t()) :: :ok | {:error, String.t()}
  def check_material(type, base64) do
    case Base.decode64(base64) do
      {:ok, blob} -> check_wire_type(type, blob)
      :error -> {:error, "invalid base64 key material"}
    end
  end

  # The decoded blob must open with <<byte_size(type)::32, type::binary>>.
  defp check_wire_type(type, blob) do
    prefix = <<byte_size(type)::32, type::binary>>
    size = byte_size(prefix)

    if byte_size(blob) >= size and :binary.part(blob, 0, size) == prefix do
      :ok
    else
      {:error, "key material does not match declared type #{type}"}
    end
  end

  defp normalize_comment(nil), do: nil

  defp normalize_comment(comment) do
    case String.trim(comment) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
