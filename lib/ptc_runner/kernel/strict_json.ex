defmodule PtcRunner.Kernel.StrictJSON do
  @moduledoc """
  Bounded, duplicate-rejecting JSON admission for authority boundaries.

  Objects are decoded as ordered key-value pairs first, then recursively
  converted to ordinary maps only when every object key is unique. Decoding
  and trusted in-memory admission share the same depth, node, UTF-8, finite
  number, timeout, and heap limits.
  """

  alias Jason.OrderedObject
  alias PtcRunner.Kernel.BoundedWorker

  @max_depth 64
  @max_nodes 100_000
  @timeout_ms 1_000
  @max_heap_words 2_000_000

  @type error ::
          :invalid_json
          | :duplicate_json_key
          | {:duplicate_json_key, [binary() | non_neg_integer()]}
          | :json_depth_exceeded
          | :json_node_limit_exceeded

  @type located_error ::
          error()
          | {:invalid_json, [binary() | non_neg_integer() | {:map_key, non_neg_integer()}],
             :improper_list
             | :invalid_object_key
             | :invalid_utf8
             | :non_finite_float
             | :unsupported_value}

  @spec decode(binary(), keyword()) :: {:ok, term()} | {:error, error()}
  @doc """
  Decodes one JSON value under the shared structural admission limits.

  Options may only narrow `:max_depth` and `:max_nodes`.
  """
  def decode(source, opts \\ [])

  def decode(source, opts) when is_binary(source) and is_list(opts) do
    with {:ok, limits} <- limits(opts) do
      decode_bounded(source, Map.put(limits, :duplicate_locations?, false))
    end
  end

  def decode(_source, _opts), do: {:error, :invalid_json}

  @doc """
  Decodes one JSON value and retains the bounded parent location of a duplicate.

  Location segments are internal evidence. Callers must authorize them against
  their own closed schema before projecting a public path.
  """
  @spec decode_with_locations(binary(), keyword()) :: {:ok, term()} | {:error, error()}
  def decode_with_locations(source, opts \\ [])

  def decode_with_locations(source, opts) when is_binary(source) and is_list(opts) do
    with {:ok, limits} <- limits(opts) do
      decode_bounded(source, Map.put(limits, :duplicate_locations?, true))
    end
  end

  def decode_with_locations(_source, _opts), do: {:error, :invalid_json}

  @spec admit(term(), keyword()) :: {:ok, term()} | {:error, error()}
  @doc """
  Admits a trusted in-memory JSON value under the same limits as `decode/2`.

  Structs, non-binary keys, invalid UTF-8, improper lists, and non-finite
  floats are rejected.
  """
  def admit(value, opts \\ [])

  def admit(value, opts) when is_list(opts) do
    with {:ok, limits} <- limits(opts) do
      bounded(fn ->
        admit_value(
          value,
          limits
          |> Map.put(:ordered_objects?, false)
          |> Map.put(:duplicate_locations?, false)
          |> Map.put(:error_locations?, false)
        )
      end)
    end
  end

  def admit(_value, _opts), do: {:error, :invalid_json}

  @doc false
  @spec admit_with_locations(term(), keyword()) ::
          {:ok, term()} | {:error, located_error()}
  def admit_with_locations(value, opts \\ [])

  def admit_with_locations(value, opts) when is_list(opts) do
    with {:ok, limits} <- limits(opts) do
      bounded(fn ->
        admit_value(
          value,
          limits
          |> Map.put(:ordered_objects?, false)
          |> Map.put(:duplicate_locations?, true)
          |> Map.put(:error_locations?, true)
        )
      end)
    end
  end

  def admit_with_locations(_value, _opts), do: {:error, :invalid_json}

  defp decode_bounded(source, limits) do
    bounded(fn ->
      case Jason.decode(source, objects: :ordered_objects) do
        {:ok, decoded} ->
          admit_value(decoded, Map.put(limits, :ordered_objects?, true))

        {:error, _reason} ->
          {:error, :invalid_json}
      end
    end)
  end

  defp bounded(function) do
    case BoundedWorker.run(function,
           timeout_ms: @timeout_ms,
           max_heap_words: @max_heap_words
         ) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp limits(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)
      max_depth = Keyword.get(opts, :max_depth, @max_depth)
      max_nodes = Keyword.get(opts, :max_nodes, @max_nodes)

      if keys -- [:max_depth, :max_nodes] == [] and
           length(keys) == MapSet.size(MapSet.new(keys)) and
           is_integer(max_depth) and max_depth in 1..@max_depth and
           is_integer(max_nodes) and max_nodes in 1..@max_nodes do
        {:ok, %{max_depth: max_depth, max_nodes: max_nodes}}
      else
        {:error, :invalid_json}
      end
    else
      {:error, :invalid_json}
    end
  end

  defp admit_value(value, limits) do
    case value(value, 1, 0, limits, []) do
      {:ok, admitted, _nodes} -> {:ok, admitted}
      {:error, _reason} = error -> error
    end
  end

  defp value(_value, depth, _nodes, %{max_depth: max_depth}, _path) when depth > max_depth,
    do: {:error, :json_depth_exceeded}

  defp value(_value, _depth, nodes, %{max_nodes: max_nodes}, _path) when nodes >= max_nodes,
    do: {:error, :json_node_limit_exceeded}

  defp value(
         %OrderedObject{values: pairs},
         depth,
         nodes,
         %{ordered_objects?: true} = limits,
         path
       ) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if keys == Enum.uniq(keys),
      do: object(pairs, depth, nodes + 1, limits, path),
      else: duplicate_error(limits, path)
  end

  defp value(value, depth, nodes, limits, path) when is_map(value) and not is_struct(value),
    do: object(Map.to_list(value), depth, nodes + 1, limits, path)

  defp value(values, depth, nodes, limits, path) when is_list(values) do
    if proper_list?(values) do
      values
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], nodes + 1}, fn {item, index}, {:ok, admitted, count} ->
        case value(item, depth + 1, count, limits, path ++ [index]) do
          {:ok, item, next_count} -> {:cont, {:ok, [item | admitted], next_count}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, admitted, count} -> {:ok, Enum.reverse(admitted), count}
        {:error, _reason} = error -> error
      end
    else
      invalid_error(limits, path, :improper_list)
    end
  end

  defp value(value, _depth, nodes, limits, _path)
       when is_nil(value) or is_boolean(value) or is_integer(value),
       do: count_scalar(value, nodes, limits)

  defp value(value, _depth, nodes, limits, path) when is_float(value) do
    if finite_float?(value),
      do: count_scalar(value, nodes, limits),
      else: invalid_error(limits, path, :non_finite_float)
  end

  defp value(value, _depth, nodes, limits, path) when is_binary(value) do
    if String.valid?(value),
      do: count_scalar(value, nodes, limits),
      else: invalid_error(limits, path, :invalid_utf8)
  end

  defp value(_value, _depth, _nodes, limits, path),
    do: invalid_error(limits, path, :unsupported_value)

  defp object(pairs, depth, nodes, limits, path) do
    pairs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}, nodes}, fn
      {{key, item}, index}, {:ok, admitted, count} when is_binary(key) ->
        cond do
          not String.valid?(key) ->
            {:halt, invalid_error(limits, path ++ [{:map_key, index}], :invalid_utf8)}

          count >= limits.max_nodes ->
            {:halt, {:error, :json_node_limit_exceeded}}

          true ->
            case value(item, depth + 1, count + 1, limits, path ++ [key]) do
              {:ok, item, next_count} ->
                {:cont, {:ok, Map.put(admitted, key, item), next_count}}

              {:error, _reason} = error ->
                {:halt, error}
            end
        end

      {{_key, _item}, index}, _acc ->
        {:halt, invalid_error(limits, path ++ [{:map_key, index}], :invalid_object_key)}
    end)
  end

  defp invalid_error(%{error_locations?: true}, path, reason),
    do: {:error, {:invalid_json, path, reason}}

  defp invalid_error(_limits, _path, _reason), do: {:error, :invalid_json}

  defp duplicate_error(%{duplicate_locations?: true}, path),
    do: {:error, {:duplicate_json_key, path}}

  defp duplicate_error(_limits, _path), do: {:error, :duplicate_json_key}

  defp count_scalar(value, nodes, %{max_nodes: max_nodes}) do
    next = nodes + 1

    if next <= max_nodes do
      {:ok, value, next}
    else
      {:error, :json_node_limit_exceeded}
    end
  end

  defp finite_float?(value) do
    case :erlang.float_to_binary(value, [:short]) do
      "nan" -> false
      "inf" -> false
      "-inf" -> false
      _finite -> true
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false
end
