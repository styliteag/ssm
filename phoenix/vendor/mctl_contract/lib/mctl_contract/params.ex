defmodule MctlContract.Params do
  @moduledoc """
  Shape checks of request bodies (types, slug format, known fields). The
  provider checks meaning. Each function returns `{:ok, params}` with only
  the known fields, or `{:error, %{field => [message]}}`.
  """

  @slug ~r/^[a-z0-9][a-z0-9-]{0,62}$/
  @modes ~w(push pull snmp)
  @max_name 255

  @doc "Contract host modes."
  def modes, do: @modes

  @doc "The slug pattern as a string (OpenAPI)."
  def slug_pattern, do: Regex.source(@slug)

  @spec host_create(term()) :: {:ok, map()} | {:error, map()}
  def host_create(body) do
    check(body, %{
      "name" => {:required, &name/1},
      "addresses" => {:optional, &addresses/1},
      "mode" => {:optional, &mode/1},
      "customer" => {:optional, &nullable_slug/1},
      "groups" => {:optional, &slugs/1},
      "attributes" => {:optional, &object/1}
    })
  end

  @spec host_update(term()) :: {:ok, map()} | {:error, map()}
  def host_update(body) do
    check(body, %{
      "name" => {:optional, &name/1},
      "customer" => {:optional, &nullable_slug/1},
      "groups" => {:optional, &slugs/1},
      "mode" => {:optional, &mode/1}
    })
  end

  @spec named_create(term()) :: {:ok, map()} | {:error, map()}
  def named_create(body),
    do: check(body, %{"slug" => {:required, &slug/1}, "name" => {:required, &name/1}})

  @spec named_update(term()) :: {:ok, map()} | {:error, map()}
  def named_update(body), do: check(body, %{"name" => {:required, &name/1}})

  @doc "`POST /hosts/{id}/actions`: `action` (string), `params` (object, default `%{}`)."
  @spec host_action(term()) :: {:ok, map()} | {:error, map()}
  def host_action(body) do
    with {:ok, params} <-
           check(body, %{"action" => {:required, &action/1}, "params" => {:optional, &object/1}}) do
      {:ok, Map.put_new(params, "params", %{})}
    end
  end

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
  `email:<address>`; at most 1024 bytes, no control characters.
  """
  @spec person_key(term()) :: :ok | {:error, String.t()}
  def person_key(key) when is_binary(key) and byte_size(key) <= 1024 do
    cond do
      String.match?(key, ~r/[[:cntrl:]]/u) -> person_key(nil)
      String.match?(key, ~r/^oidc:[^|]+\|.+$/u) -> :ok
      String.match?(key, ~r/^email:[^@\s]+@[^@\s]+$/u) -> :ok
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
      true -> :ok
    end
  end

  defp name(_v), do: {:error, "must be a string"}

  defp slug(v) when is_binary(v) do
    if Regex.match?(@slug, v), do: :ok, else: {:error, "must match #{Regex.source(@slug)}"}
  end

  defp slug(_v), do: {:error, "must be a string"}

  defp nullable_slug(nil), do: :ok
  defp nullable_slug(v), do: slug(v)

  defp slugs(list) when is_list(list) do
    if Enum.all?(list, &(slug(&1) == :ok)),
      do: :ok,
      else: {:error, "must be a list of slugs (#{Regex.source(@slug)})"}
  end

  defp slugs(_v), do: {:error, "must be a list of slugs"}

  defp addresses(list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, "must be a list of non-empty strings"}
  end

  defp addresses(_v), do: {:error, "must be a list of strings"}

  defp mode(v) when v in @modes or is_nil(v), do: :ok
  defp mode(_v), do: {:error, "must be one of #{Enum.join(@modes, ", ")} or null"}

  defp action(v) when is_binary(v) and v != "", do: :ok
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

  defp object(v) when is_map(v), do: :ok
  defp object(_v), do: {:error, "must be an object"}
end
