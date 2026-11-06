defmodule SsmWeb.Mctl.HostParams do
  @moduledoc """
  Meaning checks for contract host bodies (the library already checked the
  shape) and the mapping between contract fields and the ssm `host` table.

  ssm specifics, documented in the host `attributes` schema:

    * `mode` — only `pull` (or none): ssm connects to the host.
    * `addresses` — exactly one (ssm stores one address per host).
    * `attributes` — `username` (default `root`), `port` (default 22),
      `jump_via` (an existing ssm host, by id or by name), `disabled`, `comment`, `key_fingerprint`
      (pre-seeds the host-key pin, ADR-0008: the create job then verifies
      instead of trusting on first use).
    * read-only `limited` / `limited_reason` — the login is not `root`, so
      ssm sees only the `authorized_keys` that user can access.
  """

  @attribute_keys ~w(username port jump_via disabled comment key_fingerprint)
  @read_only_keys ~w(limited limited_reason)

  @doc "JSON schema of the host `attributes` (embedded in the OpenAPI document)."
  def attributes_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "username" => %{"type" => "string", "default" => "root"},
        "port" => %{"type" => "integer", "minimum" => 1, "maximum" => 65_535, "default" => 22},
        "jump_via" => %{
          "type" => ["string", "integer", "null"],
          "description" => "jump host: an existing ssm host, by id or by name"
        },
        "disabled" => %{"type" => "boolean", "default" => false},
        "comment" => %{"type" => ["string", "null"]},
        "key_fingerprint" => %{
          "type" => ["string", "null"],
          "description" => "pinned SSH host key, `<type> SHA256:<base64>`"
        },
        "limited" => %{
          "type" => "boolean",
          "readOnly" => true,
          "description" =>
            "login is not root: ssm only sees the authorized_keys this user can access"
        },
        "limited_reason" => %{
          "type" => ["string", "null"],
          "readOnly" => true,
          "description" => "one sentence for the UI when `limited`"
        }
      }
    }
  end

  @doc """
  `POST /hosts` params → `{:ok, host_attrs, membership}` or
  `{:error, {:validation, %{field => [msg]}}}`.
  """
  @spec create(map()) :: {:ok, map(), map()} | {:error, {:validation, map()}}
  def create(params) do
    errors =
      %{}
      |> check_mode(Map.get(params, "mode"))
      |> check_addresses(Map.get(params, "addresses"))
      |> check_attributes(Map.get(params, "attributes") || %{})

    if errors == %{} do
      {:ok, host_attrs(params), params |> membership() |> Map.delete(:name)}
    else
      {:error, {:validation, errors}}
    end
  end

  @doc "The `name`/`customer`/`groups` keys present in `params`, as atom keys."
  @spec membership(map()) :: map()
  def membership(params) do
    for {key, atom} <- [{"name", :name}, {"customer", :customer}, {"groups", :groups}],
        Map.has_key?(params, key),
        into: %{},
        do: {atom, params[key]}
  end

  defp check_mode(errors, mode) when mode in [nil, "pull"], do: errors
  defp check_mode(errors, _mode), do: Map.put(errors, "mode", ["not supported by ssm"])

  defp check_addresses(errors, [address]) when is_binary(address) and address != "", do: errors

  defp check_addresses(errors, _),
    do: Map.put(errors, "addresses", ["ssm needs exactly one address"])

  defp check_attributes(errors, attrs) do
    Enum.reduce(attrs, errors, fn {key, value}, acc ->
      case check_attribute(key, value) do
        :ok -> acc
        {:error, message} -> Map.put(acc, "attributes.#{key}", [message])
      end
    end)
  end

  defp check_attribute("username", v) do
    if Ssm.Hosts.SshFields.valid_username?(v),
      do: :ok,
      else: {:error, "must be a login name (letters, digits, . _ -; not starting with -)"}
  end

  defp check_attribute("port", v) when is_integer(v) and v > 0 and v < 65_536, do: :ok
  defp check_attribute("jump_via", v) when is_nil(v), do: :ok

  defp check_attribute("jump_via", v) when (is_binary(v) and v != "") or is_integer(v), do: :ok

  defp check_attribute("disabled", v) when is_boolean(v), do: :ok
  defp check_attribute("comment", v) when is_nil(v) or is_binary(v), do: :ok

  defp check_attribute("key_fingerprint", v) when is_nil(v), do: :ok

  defp check_attribute("key_fingerprint", v) when is_binary(v) do
    case Ssm.Ssh.HostKey.normalize_fingerprint(v) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "must be an SSH SHA256 fingerprint (<type> SHA256:<base64>)"}
    end
  end

  defp check_attribute(key, _v) when key in @read_only_keys, do: {:error, "is read-only"}
  defp check_attribute(key, _v) when key in @attribute_keys, do: {:error, "has an invalid value"}
  defp check_attribute(_key, _v), do: {:error, "is not a known ssm attribute"}

  defp host_attrs(params) do
    attrs = Map.get(params, "attributes") || %{}
    [address] = params["addresses"]

    %{
      name: params["name"],
      address: address,
      username: Map.get(attrs, "username", "root"),
      port: Map.get(attrs, "port", 22),
      jump_via: Map.get(attrs, "jump_via"),
      disabled: Map.get(attrs, "disabled", false),
      comment: Map.get(attrs, "comment"),
      key_fingerprint: Map.get(attrs, "key_fingerprint")
    }
  end

  @doc """
  Resolve the `jump_via` reference of `create/1`'s host attrs (an ssm host
  id or name) to the host id; an unknown host is a validation error.
  """
  @spec resolve_jump(map()) :: {:ok, map()} | {:error, {:validation, map()}}
  def resolve_jump(%{jump_via: nil} = attrs), do: {:ok, attrs}

  def resolve_jump(%{jump_via: ref} = attrs) do
    case Ssm.Hosts.resolve_host_ref(ref) do
      {:ok, id} -> {:ok, %{attrs | jump_via: id}}
      :error -> {:error, {:validation, %{"attributes.jump_via" => ["no such ssm host"]}}}
    end
  end

  @doc "Parse an ssm host id from a contract string id."
  @spec parse_id(term()) :: {:ok, pos_integer()} | :error
  def parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  def parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  def parse_id(_), do: :error

  @doc """
  Map a failed host changeset to a provider error: uniqueness → a
  `conflict` whose details name the clashing field, everything else →
  validation errors under contract field names.
  """
  @spec changeset_error(Ecto.Changeset.t()) ::
          {:conflict, String.t(), map()} | {:validation, map()}
  def changeset_error(%Ecto.Changeset{errors: errors}) do
    case Enum.filter(errors, fn {_field, {_msg, meta}} -> meta[:constraint] == :unique end) do
      [] ->
        {:validation,
         errors
         |> Enum.group_by(&contract_field(elem(&1, 0)), fn {_f, {msg, _}} -> msg end)}

      unique ->
        {:conflict, "a host with this name or address already exists",
         Map.new(unique, fn {field, _} -> {conflict_field(field), ["already exists"]} end)}
    end
  end

  # Conflicts name the field as the client sees it in the request.
  defp conflict_field(:address), do: "address"
  defp conflict_field(field), do: to_string(field)

  defp contract_field(:name), do: "name"
  defp contract_field(:address), do: "addresses"
  defp contract_field(field), do: "attributes.#{field}"
end
