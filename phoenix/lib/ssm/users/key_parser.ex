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

  @type parsed :: %{
          key_type: String.t(),
          key_base64: String.t(),
          name: String.t() | nil
        }

  @doc """
  Parse one public key line into `%{key_type, key_base64, name}` where
  `name` is the trailing comment (or `nil`). Accepted types are exactly
  `Ssm.Users.UserKey.key_types/0` (ssh-rsa, ssh-ed25519, ecdsa-sha2-nistp*,
  ssh-dss, and the sk-* variants).
  """
  @spec parse(String.t()) :: {:ok, parsed()} | {:error, String.t()}
  def parse(line) when is_binary(line) do
    case line |> String.trim() |> String.split(~r/\s+/, parts: 3) do
      [""] -> {:error, "empty line"}
      [type] -> with :ok <- check_type(type), do: {:error, "missing base64 key material"}
      [type, base64] -> build(type, base64, nil)
      [type, base64, comment] -> build(type, base64, comment)
    end
  end

  @doc """
  The key of an authorized_keys line as `{type, base64}`: the first known key
  type followed by key material, whatever options prefix
  (`from="10.0.0.0/8",no-pty`), comment, surrounding whitespace or CR stand
  around it. Two lines hold the same key exactly when their identities are
  equal. `nil` when the line has no known key type with material. The
  material is not validated here (see `parse/1`).
  """
  @spec identity(String.t()) :: {String.t(), String.t()} | nil
  def identity(line) when is_binary(line) do
    tokens = String.split(line)

    case key_index(tokens) do
      nil -> nil
      index -> {Enum.at(tokens, index), Enum.at(tokens, index + 1)}
    end
  end

  @doc """
  `parse/1` for an authorized_keys line that may carry an options prefix:
  the options are skipped (ssm does not keep them), the key and its comment
  are parsed and validated as `parse/1` does.
  """
  @spec parse_authorized_line(String.t()) :: {:ok, parsed()} | {:error, String.t()}
  def parse_authorized_line(line) when is_binary(line) do
    tokens = String.split(line)

    case key_index(tokens) do
      nil -> parse(line)
      index -> tokens |> Enum.drop(index) |> Enum.join(" ") |> parse()
    end
  end

  # index of the first known key type that is followed by a token
  defp key_index(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_index(fn [type, _material] -> type in UserKey.key_types() end)
  end

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

  defp check_material(type, base64) do
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
