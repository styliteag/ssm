defmodule MctlContract.Params do
  @moduledoc """
  Shape checks of request bodies (types, slug format, known fields). The
  provider checks meaning. Each function returns `{:ok, params}` with only
  the known fields, or `{:error, %{field => [message]}}`.
  """

  # \A…\z: `$` would accept a trailing newline. The OpenAPI document
  # gets the ECMA form `^…$` (`slug_pattern/0`).
  @slug_source "[a-z0-9][a-z0-9-]{0,62}"
  @slug Regex.compile!("\\A#{@slug_source}\\z")
  # relay: the Orbit dashboard forwards the agent data (contract section 17)
  @modes ~w(push pull relay snmp)
  @max_name 255
  @max_addresses 32
  @max_id 255

  @doc "Contract host modes."
  def modes, do: @modes

  @doc "The slug pattern as a string (OpenAPI)."
  def slug_pattern, do: "^#{@slug_source}$"

  @doc """
  A path slug (`/customers/{slug}`, `/groups/{slug}`): `:ok` or an error
  message.
  """
  @spec path_slug(term()) :: :ok | {:error, String.t()}
  def path_slug(v), do: slug(v)

  @doc """
  A path id (`/hosts/{id}`, `/jobs/{id}`, `/maintenance/{id}`): non-empty
  UTF-8, at most #{@max_id} bytes, no control characters or whitespace.
  """
  @spec path_id(term()) :: :ok | {:error, String.t()}
  def path_id(v) when is_binary(v) and v != "" and byte_size(v) <= @max_id do
    if String.valid?(v) and not String.match?(v, ~r/[\s[:cntrl:]]/u),
      do: :ok,
      else: {:error, "id must be UTF-8 without whitespace or control characters"}
  end

  def path_id(_v), do: {:error, "id must be 1 to #{@max_id} bytes"}

  @doc """
  `POST /hosts`. `modes`: the modes the provider accepts (`modes/0`,
  capability `mode:<m>`); nil (no callback): every contract mode, the
  provider decides.
  """
  @spec host_create(term(), [String.t()] | nil) :: {:ok, map()} | {:error, map()}
  def host_create(body, modes \\ nil) do
    check(body, %{
      "name" => {:required, &name/1},
      "addresses" => {:optional, &addresses/1},
      "mode" => {:optional, &mode(&1, modes)},
      "customer" => {:optional, &nullable_slug/1},
      "groups" => {:optional, &slugs/1},
      "attributes" => {:optional, &create_attributes/1}
    })
  end

  @max_attributes 32
  @max_attribute_list 64
  @max_attributes_bytes 8192
  @attribute_key_source "[a-z][a-z0-9_]{0,63}"
  @attribute_key Regex.compile!("\\A#{@attribute_key_source}\\z")

  @doc """
  `PATCH /hosts/{id}`: `name`, `customer`, `groups`, `mode` and, when the
  provider lists updatable attribute keys (`updatable`, capability
  `update_attributes`), `attributes`: a JSON object of at most
  #{@max_attributes} keys matching `^#{@attribute_key_source}$`, each
  value a string, number, boolean, null or a list of at most
  #{@max_attribute_list} strings, #{@max_attributes_bytes} bytes encoded at
  most, and only keys of `updatable`. `updatable` nil (no capability):
  `attributes` are not supported.
  """
  @spec host_update(term(), [String.t()] | nil, [String.t()] | nil) ::
          {:ok, map()} | {:error, map()}
  def host_update(body, updatable \\ nil, modes \\ nil) do
    check(body, %{
      "name" => {:optional, &name/1},
      "customer" => {:optional, &nullable_slug/1},
      "groups" => {:optional, &slugs/1},
      "mode" => {:optional, &mode(&1, modes)},
      "attributes" => {:optional, &updatable_attributes(&1, updatable)}
    })
  end

  @doc "Most keys `attributes` in `PATCH /hosts/{id}` may have."
  def max_attributes, do: @max_attributes

  @doc "The attribute key pattern as a string (OpenAPI)."
  def attribute_key_pattern, do: "^#{@attribute_key_source}$"

  # `POST /hosts`: the same shape as on update; the provider decides
  # which keys it accepts
  defp create_attributes(attrs) when is_map(attrs), do: attribute_shape(attrs)
  defp create_attributes(_attrs), do: {:error, "must be an object"}

  defp updatable_attributes(_attrs, nil), do: {:error, "are not supported by this tool"}

  defp updatable_attributes(attrs, updatable) when is_map(attrs) do
    with :ok <- attribute_shape(attrs) do
      case attrs |> Map.keys() |> Enum.reject(&(&1 in updatable)) |> Enum.sort() do
        [] ->
          :ok

        unknown ->
          {:error,
           "not updatable: #{Enum.join(unknown, ", ")} (this tool accepts #{Enum.join(updatable, ", ")})"}
      end
    end
  end

  defp updatable_attributes(_attrs, _updatable), do: {:error, "must be an object"}

  defp attribute_shape(attrs) do
    cond do
      map_size(attrs) > @max_attributes ->
        {:error, "must have at most #{@max_attributes} keys"}

      not Enum.all?(Map.keys(attrs), &(is_binary(&1) and Regex.match?(@attribute_key, &1))) ->
        {:error, "keys must match #{attribute_key_pattern()}"}

      not Enum.all?(Map.values(attrs), &attribute_value?/1) ->
        {:error,
         "values must be a string, number, boolean, null or a list of at most " <>
           "#{@max_attribute_list} strings"}

      byte_size(Jason.encode!(attrs)) > @max_attributes_bytes ->
        {:error, "must be at most #{@max_attributes_bytes} bytes as JSON"}

      true ->
        :ok
    end
  end

  defp attribute_value?(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v),
    do: true

  defp attribute_value?(list) when is_list(list),
    do: length(list) <= @max_attribute_list and Enum.all?(list, &is_binary/1)

  defp attribute_value?(_v), do: false

  @spec named_create(term()) :: {:ok, map()} | {:error, map()}
  def named_create(body),
    do: check(body, %{"slug" => {:required, &slug/1}, "name" => {:required, &name/1}})

  @spec named_update(term()) :: {:ok, map()} | {:error, map()}
  def named_update(body), do: check(body, %{"name" => {:required, &name/1}})

  @doc """
  `POST /customers/{slug}/merge`: `into` (required slug of the target,
  not `source` itself); nothing else.
  """
  @spec customer_merge(term(), String.t()) :: {:ok, map()} | {:error, map()}
  def customer_merge(body, source) do
    case check(body, %{"into" => {:required, &slug/1}}) do
      {:ok, %{"into" => ^source}} ->
        {:error, %{"into" => ["must differ from the merged customer"]}}

      result ->
        result
    end
  end

  @max_address 253
  @max_probe_ports 5

  @doc "Most ports one `POST /probe/ssh` may check."
  def max_probe_ports, do: @max_probe_ports

  @doc "Longest address `POST /probe/ssh` accepts (a DNS name's limit)."
  def max_address, do: @max_address

  @doc """
  `POST /probe/ssh`: `address` (required: IP or DNS name, non-empty, at
  most 253 characters, no whitespace), `ports` (required: 1 to 5 distinct
  integers 1-65535), `jump_via` (optional: a host of the tool, non-empty
  name or positive integer id); nothing else.
  """
  @spec probe_ssh(term()) :: {:ok, map()} | {:error, map()}
  def probe_ssh(body) do
    check(body, %{
      "address" => {:required, &probe_address/1},
      "ports" => {:required, &probe_ports/1},
      "jump_via" => {:optional, &jump_via/1}
    })
  end

  defp probe_address(v) when is_binary(v) do
    cond do
      v == "" -> {:error, "must not be empty"}
      String.length(v) > @max_address -> {:error, "must be at most #{@max_address} characters"}
      String.match?(v, ~r/[\s[:cntrl:]]/u) -> {:error, "must not contain whitespace"}
      true -> :ok
    end
  end

  defp probe_address(_v), do: {:error, "must be a string"}

  defp probe_ports(list) when is_list(list) do
    cond do
      list == [] or length(list) > @max_probe_ports ->
        {:error, "must hold 1 to #{@max_probe_ports} ports"}

      not Enum.all?(list, &(is_integer(&1) and &1 in 1..65_535)) ->
        {:error, "must be integers 1-65535"}

      length(Enum.uniq(list)) != length(list) ->
        {:error, "must not repeat a port"}

      true ->
        :ok
    end
  end

  defp probe_ports(_v), do: {:error, "must be a list of ports"}

  defp jump_via(v) when is_binary(v) do
    cond do
      String.trim(v) == "" -> {:error, "must not be empty"}
      String.length(v) > @max_name -> {:error, "must be at most #{@max_name} characters"}
      control?(v) -> {:error, "must not contain control characters"}
      true -> :ok
    end
  end

  defp jump_via(v) when is_integer(v) and v > 0, do: :ok
  defp jump_via(_v), do: {:error, "must be a host name or a positive id"}

  @max_action 64
  @max_action_params_bytes 8192
  @max_action_params_depth 6

  @doc """
  `POST /hosts/{id}/actions`: `action` (string, at most #{@max_action}
  characters, no control characters), `params` (object, default `%{}`, at
  most #{@max_action_params_bytes} bytes as JSON and
  #{@max_action_params_depth} levels deep). The provider checks the values.
  """
  @spec host_action(term()) :: {:ok, map()} | {:error, map()}
  def host_action(body) do
    with {:ok, params} <-
           check(body, %{
             "action" => {:required, &action/1},
             "params" => {:optional, &action_params/1}
           }) do
      {:ok, Map.put_new(params, "params", %{})}
    end
  end

  defp action_params(v) when is_map(v) do
    cond do
      depth(v) > @max_action_params_depth ->
        {:error, "must be nested at most #{@max_action_params_depth} levels deep"}

      byte_size(Jason.encode!(v)) > @max_action_params_bytes ->
        {:error, "must be at most #{@max_action_params_bytes} bytes as JSON"}

      true ->
        :ok
    end
  end

  defp action_params(_v), do: {:error, "must be an object"}

  defp depth(v) when is_map(v), do: 1 + max_depth(Map.values(v))
  defp depth(v) when is_list(v), do: 1 + max_depth(v)
  defp depth(_v), do: 0

  defp max_depth(values), do: values |> Enum.map(&depth/1) |> Enum.max(fn -> 0 end)

  @max_window_days 30
  @max_lead_days 90
  @max_comment 1000

  @doc "Longest maintenance window in days."
  def max_window_days, do: @max_window_days

  @doc "How far ahead a maintenance window may start, in days."
  def max_lead_days, do: @max_lead_days

  @doc """
  `POST /hosts/{id}/maintenance`: `start`, `end` (ISO 8601 with offset,
  returned as UTC `DateTime`s; `end > start`, `end` after `now`, at most
  30 days, `start` at most 90 days ahead), `comment` (non-empty string,
  at most 1000 characters).
  """
  @spec maintenance_create(term(), DateTime.t()) :: {:ok, map()} | {:error, map()}
  def maintenance_create(body, now \\ DateTime.utc_now()) do
    with {:ok, params} <-
           check(body, %{
             "start" => {:required, &timestamp/1},
             "end" => {:required, &timestamp/1},
             "comment" => {:required, &comment/1}
           }) do
      params = %{params | "start" => utc!(params["start"]), "end" => utc!(params["end"])}
      window(params, now)
    end
  end

  defp window(%{"start" => from, "end" => to} = params, now) do
    cond do
      DateTime.compare(to, from) != :gt ->
        {:error, %{"end" => ["must be after start"]}}

      DateTime.compare(to, now) != :gt ->
        {:error, %{"end" => ["must be in the future"]}}

      DateTime.diff(to, from) > @max_window_days * 86_400 ->
        {:error, %{"end" => ["must be at most #{@max_window_days} days after start"]}}

      DateTime.diff(from, now) > @max_lead_days * 86_400 ->
        {:error, %{"start" => ["must be at most #{@max_lead_days} days ahead"]}}

      true ->
        {:ok, params}
    end
  end

  @doc "`POST /people/{key}/remove`: optional `hosts` (list of host ids)."
  @spec person_remove(term()) :: {:ok, map()} | {:error, map()}
  def person_remove(body), do: check(body, %{"hosts" => {:optional, &host_ids/1}})

  @doc """
  A person key: `oidc:<iss>|<sub>` (both parts non-empty) or
  `email:<address>`; UTF-8, at most 1024 bytes, no control characters.
  """
  @spec person_key(term()) :: :ok | {:error, String.t()}
  def person_key(key) when is_binary(key) and byte_size(key) <= 1024 do
    cond do
      not String.valid?(key) or String.match?(key, ~r/[[:cntrl:]]/u) -> person_key(nil)
      String.match?(key, ~r/\Aoidc:[^|]+\|.+\z/u) -> :ok
      String.match?(key, ~r/\Aemail:[^@\s]+@[^@\s]+\z/u) -> :ok
      true -> person_key(nil)
    end
  end

  def person_key(_key), do: {:error, "key must be oidc:<iss>|<sub> or email:<address>"}

  defp check(body, fields) when is_map(body) do
    unknown =
      body
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(fields, &1))
      |> Map.new(&{to_string(&1), ["is not a writable field"]})

    errors =
      Enum.reduce(fields, unknown, fn {field, {need, fun}}, acc ->
        case {Map.fetch(body, field), need} do
          {:error, :required} -> Map.put(acc, field, ["is required"])
          {:error, :optional} -> acc
          {{:ok, v}, _} -> add(acc, field, fun.(v))
        end
      end)

    if errors == %{}, do: {:ok, Map.take(body, Map.keys(fields))}, else: {:error, errors}
  end

  defp check(_body, _fields), do: {:error, %{"body" => ["must be a JSON object"]}}

  defp add(acc, _field, :ok), do: acc
  defp add(acc, field, {:error, msg}), do: Map.put(acc, field, [msg])

  defp name(v) when is_binary(v) do
    trimmed = String.trim(v)

    cond do
      trimmed == "" -> {:error, "must not be empty"}
      String.length(v) > @max_name -> {:error, "must be at most #{@max_name} characters"}
      control?(v) -> {:error, "must not contain control characters"}
      true -> :ok
    end
  end

  defp name(_v), do: {:error, "must be a string"}

  defp control?(v), do: String.match?(v, ~r/[[:cntrl:]]/u)

  defp slug(v) when is_binary(v) do
    if Regex.match?(@slug, v), do: :ok, else: {:error, "must match #{slug_pattern()}"}
  end

  defp slug(_v), do: {:error, "must be a string"}

  defp nullable_slug(nil), do: :ok
  defp nullable_slug(v), do: slug(v)

  defp slugs(list) when is_list(list) do
    if Enum.all?(list, &(slug(&1) == :ok)),
      do: :ok,
      else: {:error, "must be a list of slugs (#{slug_pattern()})"}
  end

  defp slugs(_v), do: {:error, "must be a list of slugs"}

  defp addresses(list) when is_list(list) do
    cond do
      length(list) > @max_addresses ->
        {:error, "must hold at most #{@max_addresses} addresses"}

      Enum.all?(list, &(probe_address(&1) == :ok)) ->
        :ok

      true ->
        {:error,
         "must be a list of non-empty strings of at most #{@max_address} characters " <>
           "without whitespace"}
    end
  end

  defp addresses(_v), do: {:error, "must be a list of strings"}

  defp mode(v) when v in @modes or is_nil(v), do: :ok
  defp mode(_v), do: {:error, "must be one of #{Enum.join(@modes, ", ")} or null"}

  # a contract mode the provider does not list in modes/0
  defp mode(v, nil), do: mode(v)

  defp mode(v, modes) do
    cond do
      mode(v) != :ok -> mode(v)
      is_nil(v) or v in modes -> :ok
      true -> {:error, "not supported by this tool (it accepts #{Enum.join(modes, ", ")})"}
    end
  end

  defp action(v) when is_binary(v) and v != "" do
    if String.length(v) <= @max_action and not control?(v),
      do: :ok,
      else: {:error, "must be at most #{@max_action} characters without control characters"}
  end

  defp action(_v), do: {:error, "must be a non-empty string"}

  defp timestamp(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, _dt, _offset} -> :ok
      _ -> {:error, "must be an ISO 8601 timestamp with offset"}
    end
  end

  defp timestamp(_v), do: {:error, "must be an ISO 8601 timestamp with offset"}

  defp utc!(v) do
    {:ok, dt, _offset} = DateTime.from_iso8601(v)
    dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
  end

  defp comment(v) when is_binary(v) do
    cond do
      String.trim(v) == "" -> {:error, "must not be empty"}
      String.length(v) > @max_comment -> {:error, "must be at most #{@max_comment} characters"}
      true -> :ok
    end
  end

  defp comment(_v), do: {:error, "must be a string"}

  defp host_ids(list) when is_list(list) and list != [] do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, "must be a list of host ids (strings)"}
  end

  defp host_ids(_v), do: {:error, "must be a non-empty list of host ids"}
end
