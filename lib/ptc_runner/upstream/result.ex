defmodule PtcRunner.Upstream.Result do
  @moduledoc """
  Transport-neutral upstream call result helpers.
  """

  @type reason ::
          :upstream_unavailable
          | :upstream_error
          | :tool_error
          | :auth_failed
          | :rate_limited
          | :timeout
          | :response_too_large
          | :cap_exhausted

  @type t :: {:ok, json()} | {:error, reason(), String.t()}

  @type json ::
          nil
          | boolean()
          | number()
          | binary()
          | [json()]
          | %{optional(binary()) => json()}

  @doc "Builds the PTC-Lisp-visible tagged success shape."
  @spec success(term()) :: map()
  def success(value) do
    %{
      ok: true,
      value: value,
      value_kind: value_kind(value)
    }
  end

  @doc "Builds the PTC-Lisp-visible tagged recoverable failure shape."
  @spec error(atom(), String.t()) :: map()
  def error(reason, message) when is_atom(reason) and is_binary(message) do
    %{ok: false, reason: reason, message: message}
  end

  @doc "Decorates a structured payload with upstream call diagnostics."
  @spec decorate_payload(map(), [map()]) :: map()
  def decorate_payload(payload, []) when is_map(payload), do: payload

  def decorate_payload(payload, entries) when is_map(payload) and is_list(entries) do
    payload
    |> Map.put("upstream_calls", Enum.map(entries, &Map.delete(&1, "result_overview")))
    |> maybe_put_upstream_results(entries)
  end

  @doc "Projects raw upstream-call entries to compact result summaries."
  @spec compact_result_entries([map()]) :: [map()]
  def compact_result_entries(entries) when is_list(entries) do
    entries
    |> Enum.map(&compact_result_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Builds a compact, LLM-facing overview of an upstream result value."
  @spec result_overview(term(), atom()) :: map()
  def result_overview(value, value_kind) when is_atom(value_kind) do
    %{
      "value_kind" => Atom.to_string(value_kind),
      "shape" => shape(value),
      "preview" => preview(value)
    }
  end

  @spec value_kind(term()) :: :json | :text | :none
  def value_kind(nil), do: :json
  def value_kind(value) when is_binary(value), do: :text

  def value_kind(value)
      when is_boolean(value) or is_number(value) or is_list(value) or is_map(value), do: :json

  def value_kind(_), do: :none

  defp maybe_put_upstream_results(payload, entries) do
    case compact_result_entries(entries) do
      [] -> payload
      summaries -> Map.put(payload, "upstream_results", summaries)
    end
  end

  defp compact_result_entry(%{"status" => "ok", "result_overview" => overview} = entry)
       when is_map(overview) do
    %{
      "server" => Map.get(entry, "server"),
      "tool" => Map.get(entry, "tool"),
      "status" => "ok"
    }
    |> Map.merge(overview)
  end

  defp compact_result_entry(%{"status" => "error"} = entry) do
    %{
      "server" => Map.get(entry, "server"),
      "tool" => Map.get(entry, "tool"),
      "status" => "error"
    }
    |> maybe_put("reason", Map.get(entry, "reason"))
    |> maybe_put("error", Map.get(entry, "error"))
  end

  defp compact_result_entry(_entry), do: nil

  defp shape(value) when is_map(value) do
    keys = value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    "map keys=#{inspect(Enum.take(keys, 8))} count=#{length(keys)}"
  end

  defp shape(value) when is_list(value), do: "list count=#{length(value)}"
  defp shape(value) when is_binary(value), do: "string bytes=#{byte_size(value)}"
  defp shape(value) when is_integer(value), do: "integer"
  defp shape(value) when is_float(value), do: "number"
  defp shape(value) when is_boolean(value), do: "boolean"
  defp shape(nil), do: "nil"
  defp shape(_value), do: "unknown"

  defp preview(value) when is_binary(value), do: truncate(value, 240)

  defp preview(value) do
    value
    |> compact_value()
    |> encode_or_inspect()
    |> truncate(240)
  end

  defp compact_value(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.take(8)
    |> Map.new(fn {key, val} -> {to_string(key), compact_leaf(val)} end)
  end

  defp compact_value(value) when is_list(value) do
    value
    |> Enum.take(5)
    |> Enum.map(&compact_leaf/1)
  end

  defp compact_value(value), do: compact_leaf(value)

  defp compact_leaf(value) when is_binary(value), do: truncate(value, 120)
  defp compact_leaf(value) when is_map(value), do: %{"type" => "map", "keys" => map_keys(value)}
  defp compact_leaf(value) when is_list(value), do: %{"type" => "list", "count" => length(value)}
  defp compact_leaf(value), do: value

  defp map_keys(value) do
    value
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> Enum.take(8)
  end

  defp encode_or_inspect(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value, limit: 20, printable_limit: 200)
    end
  end

  defp truncate(text, max_bytes) when is_binary(text) and byte_size(text) <= max_bytes, do: text

  defp truncate(text, max_bytes) when is_binary(text) do
    truncate_utf8(text, max_bytes) <> "..."
  end

  defp truncate_utf8(_text, max_bytes) when max_bytes <= 0, do: ""

  defp truncate_utf8(text, max_bytes) do
    chunk = binary_part(text, 0, max_bytes)

    if String.valid?(chunk) do
      chunk
    else
      truncate_utf8(text, max_bytes - 1)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
