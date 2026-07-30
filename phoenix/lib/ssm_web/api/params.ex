defmodule SsmWeb.Api.Params do
  @moduledoc """
  Request-parameter validation for the JSON API, mirroring the python stack's
  Pydantic `Field` constraints: same required fields, defaults, length and
  numeric bounds — violations yield the same 422 `VALIDATION_FAILED`.

  A spec is a keyword list: `name: [type: :string, required: true, min_len: 1,
  max_len: 128]`. Supported types: `:string`, `:integer`, `:boolean`; options:
  `required`, `default`, `nilable`, `min_len`/`max_len`, `min`/`max`.
  """

  @type spec :: [{atom(), keyword()}]

  @doc "Create semantics: defaults are applied, `required` fields must be present."
  @spec validate(map(), spec()) :: {:ok, map()} | {:error, [map()]}
  def validate(params, spec) do
    spec
    |> Enum.reduce({%{}, []}, fn {key, opts}, acc -> check_full(params, key, opts, acc) end)
    |> finish()
  end

  @doc "PATCH semantics (`exclude_unset`): only keys present in the payload are validated/applied."
  @spec validate_partial(map(), spec()) :: {:ok, map()} | {:error, [map()]}
  def validate_partial(params, spec) do
    spec
    |> Enum.reduce({%{}, []}, fn {key, opts}, acc -> check_present(params, key, opts, acc) end)
    |> finish()
  end

  defp finish({attrs, []}), do: {:ok, attrs}
  defp finish({_attrs, errors}), do: {:error, Enum.reverse(errors)}

  defp check_full(params, key, opts, {attrs, errors}) do
    case Map.fetch(params, Atom.to_string(key)) do
      {:ok, value} ->
        apply_cast(key, value, opts, {attrs, errors})

      :error ->
        cond do
          Keyword.get(opts, :required, false) ->
            {attrs, [%{field: key, message: "field required"} | errors]}

          Keyword.has_key?(opts, :default) ->
            {Map.put(attrs, key, Keyword.fetch!(opts, :default)), errors}

          true ->
            {attrs, errors}
        end
    end
  end

  defp check_present(params, key, opts, {attrs, errors}) do
    case Map.fetch(params, Atom.to_string(key)) do
      {:ok, value} -> apply_cast(key, value, opts, {attrs, errors})
      :error -> {attrs, errors}
    end
  end

  defp apply_cast(key, value, opts, {attrs, errors}) do
    case cast(value, opts) do
      {:ok, cast} -> {Map.put(attrs, key, cast), errors}
      {:error, message} -> {attrs, [%{field: key, message: message} | errors]}
    end
  end

  defp cast(nil, opts) do
    if Keyword.get(opts, :nilable, false) do
      {:ok, nil}
    else
      {:error, "must not be null"}
    end
  end

  defp cast(value, opts) do
    case Keyword.fetch!(opts, :type) do
      :string -> cast_string(value, opts)
      :integer -> cast_integer(value, opts)
      :boolean -> cast_boolean(value)
    end
  end

  defp cast_string(value, opts) when is_binary(value) do
    min = Keyword.get(opts, :min_len, 0)
    max = Keyword.get(opts, :max_len)
    size = String.length(value)

    cond do
      size < min -> {:error, "must be at least #{min} characters"}
      max && size > max -> {:error, "must be at most #{max} characters"}
      true -> {:ok, value}
    end
  end

  defp cast_string(_value, _opts), do: {:error, "must be a string"}

  defp cast_integer(value, opts) when is_integer(value), do: check_bounds(value, opts)

  # Pydantic's lax mode coerces numeric strings; "" and junk are rejected.
  defp cast_integer(value, opts) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> check_bounds(int, opts)
      _ -> {:error, "must be an integer"}
    end
  end

  defp cast_integer(_value, _opts), do: {:error, "must be an integer"}

  defp check_bounds(int, opts) do
    min = Keyword.get(opts, :min)
    max = Keyword.get(opts, :max)

    cond do
      min && int < min -> {:error, "must be >= #{min}"}
      max && int > max -> {:error, "must be <= #{max}"}
      true -> {:ok, int}
    end
  end

  defp cast_boolean(value) when is_boolean(value), do: {:ok, value}
  defp cast_boolean("true"), do: {:ok, true}
  defp cast_boolean("false"), do: {:ok, false}
  defp cast_boolean(_value), do: {:error, "must be a boolean"}

  @doc "Parse a path id (`/hosts/:id`); non-integers are a validation failure."
  @spec parse_path_id(String.t()) :: {:ok, integer()} | :error
  def parse_path_id(raw) do
    case Integer.parse(raw) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end
end
