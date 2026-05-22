defmodule PtcRunnerMcp.Agentic.Renderer do
  @moduledoc false

  @spec normalize_constraints(term()) :: {:ok, map(), [map()]} | {:error, String.t()}
  def normalize_constraints(nil), do: {:ok, %{}, []}

  def normalize_constraints(value) when is_map(value) do
    {known, warnings} =
      Enum.reduce(value, {%{}, []}, fn {key, val}, {acc, warnings} ->
        case key do
          "max_items" when is_integer(val) and val > 0 ->
            {Map.put(acc, "max_items", val), warnings}

          "preferred_fields" when is_list(val) ->
            fields = Enum.filter(val, &(is_binary(&1) and &1 != ""))
            {Map.put(acc, "preferred_fields", fields), warnings}

          other when is_binary(other) ->
            {acc, [warning("unsupported_constraint", other) | warnings]}

          other ->
            {acc, [warning("unsupported_constraint", inspect(other)) | warnings]}
        end
      end)

    {:ok, known, Enum.reverse(warnings)}
  end

  def normalize_constraints(value) do
    {:error, "argument `constraints` must be a JSON object, got #{type_label(value)}"}
  end

  @spec render(map(), map(), pos_integer()) :: {map(), [map()]}
  def render(execution_payload, constraints, default_max_result_bytes)
      when is_map(execution_payload) and is_map(constraints) do
    max_bytes = default_max_result_bytes

    result =
      execution_payload
      |> structured_value()
      |> enforce_max_items(Map.get(constraints, "max_items"))
      |> enforce_preferred_fields(Map.get(constraints, "preferred_fields", []))

    {result, truncated?} = truncate_to_bytes(result, max_bytes)
    answer = compact_answer(result, max_bytes)

    execution = %{
      "result_bytes" => encoded_size(%{"answer" => answer, "structured_result" => result}),
      "truncated" => truncated?,
      "max_result_bytes" => max_bytes
    }

    {%{"answer" => answer, "structured_result" => result, "execution" => execution},
     if(truncated?, do: [warning("max_result_bytes", max_bytes)], else: [])}
  end

  defp structured_value(%{"validated" => value}), do: value

  defp structured_value(%{"result" => result}) when is_binary(result) do
    result
    |> strip_repl_prefix()
    |> decode_result_string()
  end

  defp structured_value(%{"result" => result}), do: result
  defp structured_value(payload), do: Map.drop(payload, ["prints", "feedback", "truncated"])

  defp decode_result_string(result) do
    case Jason.decode(result) do
      {:ok, decoded} when is_binary(decoded) ->
        case Jason.decode(decoded) do
          {:ok, nested} -> nested
          {:error, _} -> decoded
        end

      {:ok, decoded} ->
        decoded

      {:error, _} ->
        result
    end
  end

  defp strip_repl_prefix("user=> " <> rest), do: String.trim(rest)
  defp strip_repl_prefix(other), do: other

  defp enforce_max_items(value, nil), do: value
  defp enforce_max_items(list, max) when is_list(list), do: Enum.take(list, max)

  defp enforce_max_items(map, max) when is_map(map) do
    case first_list_field(map) do
      nil -> map
      key -> Map.update!(map, key, &Enum.take(&1, max))
    end
  end

  defp enforce_max_items(value, _max), do: value

  defp first_list_field(map) do
    Enum.find_value(map, fn {key, value} ->
      if is_list(value), do: key
    end)
  end

  defp enforce_preferred_fields(value, []), do: value

  defp enforce_preferred_fields(list, fields) when is_list(list) do
    Enum.map(list, &enforce_preferred_fields(&1, fields))
  end

  defp enforce_preferred_fields(map, fields) when is_map(map) do
    if Enum.all?(fields, &Map.has_key?(map, &1)) do
      Map.take(map, fields)
    else
      Map.new(map, fn {key, value} -> {key, enforce_preferred_fields(value, fields)} end)
    end
  end

  defp enforce_preferred_fields(value, _fields), do: value

  defp truncate_to_bytes(value, max_bytes) do
    if encoded_size(value) <= max_bytes do
      {value, false}
    else
      preview =
        value
        |> compact_answer(max_bytes)
        |> binary_part_safe(max_bytes)

      {preview, true}
    end
  end

  defp compact_answer(value, max_bytes) when is_binary(value),
    do: binary_part_safe(value, max_bytes)

  defp compact_answer(value, max_bytes) do
    value
    |> Jason.encode!()
    |> binary_part_safe(max_bytes)
  end

  defp binary_part_safe(binary, max_bytes) do
    if byte_size(binary) <= max_bytes do
      binary
    else
      truncate_utf8(binary, max_bytes)
    end
  end

  defp truncate_utf8(_binary, max_bytes) when max_bytes <= 0, do: ""

  defp truncate_utf8(binary, max_bytes) do
    chunk = binary_part(binary, 0, max_bytes)

    if String.valid?(chunk) do
      chunk
    else
      truncate_utf8(binary, max_bytes - 1)
    end
  end

  defp encoded_size(value), do: value |> Jason.encode!() |> byte_size()

  defp warning(code, detail), do: %{"code" => code, "detail" => detail}

  defp type_label(v) when is_boolean(v), do: "boolean"
  defp type_label(v) when is_list(v), do: "array"
  defp type_label(v) when is_integer(v), do: "integer"
  defp type_label(v) when is_float(v), do: "number"
  defp type_label(_), do: "unknown"
end
