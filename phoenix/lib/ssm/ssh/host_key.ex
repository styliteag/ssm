defmodule Ssm.Ssh.HostKey do
  @moduledoc """
  Pure helpers for SSH host-key pinning (ADR-0008).

  A host's pinned identity lives in two columns:

    * `key_fingerprint` — `<key type> SHA256:<base64>` (the format
      `ssh-keygen -l` prints, minus bit count and comment). This is what every
      connect is verified against, and what the mctl API reports as
      `identity.ssh_host_keys`. An operator may pre-seed it (also as a bare
      `SHA256:<base64>`, which then matches any key type).
    * `host_key` — the full public key line (`<type> <base64>`), filled when
      ssm itself captured the key. OpenSSH cannot verify against a fingerprint,
      so jump hops need it for the generated `known_hosts` file.
  """

  # Fixed host-key algorithm order: the same key type is offered every time,
  # so a host with several host keys always presents the pinned one.
  @fixed_order [
    :"ssh-ed25519",
    :"ecdsa-sha2-nistp256",
    :"ecdsa-sha2-nistp384",
    :"ecdsa-sha2-nistp521",
    :"rsa-sha2-512",
    :"rsa-sha2-256"
  ]

  @type_algorithms %{
    "ssh-ed25519" => [:"ssh-ed25519"],
    "ecdsa-sha2-nistp256" => [:"ecdsa-sha2-nistp256"],
    "ecdsa-sha2-nistp384" => [:"ecdsa-sha2-nistp384"],
    "ecdsa-sha2-nistp521" => [:"ecdsa-sha2-nistp521"],
    "ssh-rsa" => [:"rsa-sha2-512", :"rsa-sha2-256"]
  }

  # ssh-keygen -l prints the key type in parentheses; map it back.
  @keygen_types %{
    "(ED25519)" => "ssh-ed25519",
    "(RSA)" => "ssh-rsa"
  }

  @key_type ~r/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|ssh-ed448|ssh-dss)$/
  @sha256 ~r/^SHA256:[A-Za-z0-9+\/]{43}$/

  @doc "Normalise a public key line to `<type> <base64>` (comment dropped)."
  @spec public_key(String.t()) :: {:ok, String.t()} | {:error, :invalid_public_key}
  def public_key(line) when is_binary(line) do
    with [type, blob | _] <- String.split(String.trim(line), ~r/\s+/),
         true <- Regex.match?(@key_type, type),
         {:ok, bin} <- Base.decode64(blob),
         true <- embedded_type(bin) == type do
      {:ok, "#{type} #{blob}"}
    else
      _ -> {:error, :invalid_public_key}
    end
  end

  def public_key(_), do: {:error, :invalid_public_key}

  @doc "Fingerprint of a public key line, as `<type> SHA256:<base64>`."
  @spec fingerprint(String.t()) :: {:ok, String.t()} | {:error, :invalid_public_key}
  def fingerprint(line) do
    with {:ok, normalized} <- public_key(line) do
      [type, blob] = String.split(normalized, " ")
      hash = :crypto.hash(:sha256, Base.decode64!(blob)) |> Base.encode64(padding: false)
      {:ok, "#{type} SHA256:#{hash}"}
    end
  end

  @doc """
  Normalise an operator-supplied fingerprint: the pinned format, a full
  `ssh-keygen -l` line, or a bare `SHA256:<base64>`. MD5 is refused.
  """
  @spec normalize_fingerprint(String.t() | nil) ::
          {:ok, String.t()} | {:error, :invalid_fingerprint}
  def normalize_fingerprint(value) when is_binary(value) do
    tokens = String.split(String.trim(value), ~r/\s+/)

    case Enum.find(tokens, &Regex.match?(@sha256, &1)) do
      nil -> {:error, :invalid_fingerprint}
      hash -> {:ok, with_type(declared_type(tokens), hash)}
    end
  end

  def normalize_fingerprint(_), do: {:error, :invalid_fingerprint}

  defp declared_type(tokens) do
    Enum.find(tokens, &Regex.match?(@key_type, &1)) ||
      Enum.find_value(tokens, &Map.get(@keygen_types, &1)) ||
      ecdsa_from_keygen(tokens)
  end

  # `256 SHA256:… comment (ECDSA)` — the curve follows from the bit count.
  defp ecdsa_from_keygen([bits | _] = tokens) do
    if List.last(tokens) == "(ECDSA)" and bits in ~w(256 384 521),
      do: "ecdsa-sha2-nistp#{bits}"
  end

  defp with_type(nil, hash), do: hash
  defp with_type(type, hash), do: "#{type} #{hash}"

  @doc "True when a fingerprint is pinned (not nil/blank)."
  @spec pinned?(String.t() | nil) :: boolean()
  def pinned?(value) when is_binary(value), do: String.trim(value) != ""
  def pinned?(_), do: false

  @doc """
  Does the `offered` fingerprint (always typed, from the handshake) satisfy
  the `pinned` one? The SHA-256 must be equal; a declared pinned type must be
  equal too. Unpinned never matches.
  """
  @spec matches?(String.t() | nil, String.t()) :: boolean()
  def matches?(pinned, offered) do
    with true <- pinned?(pinned),
         {:ok, pinned} <- normalize_fingerprint(pinned),
         {:ok, offered} <- normalize_fingerprint(offered) do
      split(pinned) |> same?(split(offered))
    else
      _ -> false
    end
  end

  defp split(fingerprint) do
    case String.split(fingerprint, " ") do
      [type, hash] -> {type, hash}
      [hash] -> {nil, hash}
    end
  end

  defp same?({nil, hash}, {_type, hash}), do: true
  defp same?({type, hash}, {type, hash}), do: true
  defp same?(_, _), do: false

  @doc "One `known_hosts` line for OpenSSH (`[addr]:port` form off port 22)."
  @spec known_hosts_line(String.t(), :inet.port_number(), String.t()) :: String.t()
  def known_hosts_line(address, 22, public_key), do: "#{address} #{public_key}"
  def known_hosts_line(address, port, public_key), do: "[#{address}]:#{port} #{public_key}"

  @doc """
  Host-key algorithm order for `:ssh.connect` `modify_algorithms: [prepend:
  [public_key: …]]`: the pinned key type first, then the fixed order.
  """
  @spec algorithm_preference(String.t() | nil) :: [atom()]
  def algorithm_preference(pinned) do
    first =
      case pinned do
        value when is_binary(value) ->
          value |> String.split(" ") |> List.first() |> then(&Map.get(@type_algorithms, &1, []))

        _ ->
          []
      end

    Enum.uniq(first ++ @fixed_order)
  end

  @doc "Encode an Erlang public key (from the handshake) to line + fingerprint."
  @spec from_erlang_key(term()) ::
          {:ok, %{public_key: String.t(), fingerprint: String.t()}}
          | {:error, :invalid_public_key}
  def from_erlang_key(key) do
    line = [{key, []}] |> :ssh_file.encode(:openssh_key) |> to_string()

    with {:ok, public_key} <- public_key(line),
         {:ok, fingerprint} <- fingerprint(public_key) do
      {:ok, %{public_key: public_key, fingerprint: fingerprint}}
    end
  rescue
    _ -> {:error, :invalid_public_key}
  catch
    _, _ -> {:error, :invalid_public_key}
  end

  # The key blob starts with its own type string; it must agree with the
  # line's prefix or the line is forged/garbled.
  defp embedded_type(<<len::32, type::binary-size(len), _rest::binary>>), do: type
  defp embedded_type(_), do: nil
end
