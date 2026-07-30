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
