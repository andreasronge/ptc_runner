defmodule PtcRunner.Json.Operations.Access do
  @moduledoc """
  Element access operations for the JSON DSL.

  Implements element and item access: get, first, last, nth, sort_by, max_by, min_by.
  """

  @doc """
  Evaluates an access operation.

  ## Arguments
    - op: Operation name
    - node: Operation definition map
    - context: Execution context
    - eval_fn: Function to recursively evaluate expressions

  ## Returns
    - `{:ok, result, memory}` on success
    - `{:error, reason}` on failure
  """
  @spec eval(String.t(), map(), any(), function()) ::
          {:ok, any(), map()} | {:error, {atom(), String.t()}}

  def eval("get", node, context, eval_fn) do
    # Support both field (single key) and path (nested access)
    path =
      case Map.get(node, "field") do
        nil -> Map.get(node, "path", [])
        field -> [field]
      end

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        result =
          if path == [] do
            data
          else
            get_nested(data, path)
          end

        {_result_status, result_value} = handle_get_result(result, node)
        {:ok, result_value, memory}
    end
  end

  def eval("first", _node, context, eval_fn) do
    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          {:ok, List.first(data), memory}
        else
          {:error, {:execution_error, "first requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("last", _node, context, eval_fn) do
    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          {:ok, List.last(data), memory}
        else
          {:error, {:execution_error, "last requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("nth", node, context, eval_fn) do
    index = Map.get(node, "index")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        case eval_nth(data, index) do
          {:ok, result} -> {:ok, result, memory}
          {:error, _} = err -> err
        end
    end
  end

  def eval("sort_by", node, context, eval_fn) do
    field = Map.get(node, "field")
    order = Map.get(node, "order", "asc")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          {:ok, sort_by_list(data, field, order), memory}
        else
          {:error, {:execution_error, "sort_by requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("max_by", node, context, eval_fn) do
    field = Map.get(node, "field")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          {:ok, max_by_list(data, field), memory}
        else
          {:error, {:execution_error, "max_by requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("min_by", node, context, eval_fn) do
    field = Map.get(node, "field")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          {:ok, min_by_list(data, field), memory}
        else
          {:error, {:execution_error, "min_by requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("take", node, context, eval_fn) do
    count = Map.get(node, "count")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          {:ok, Enum.take(data, count), memory}
        else
          {:error, {:execution_error, "take requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("drop", node, context, eval_fn) do
    count = Map.get(node, "count")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          {:ok, Enum.drop(data, count), memory}
        else
          {:error, {:execution_error, "drop requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("distinct", _node, context, eval_fn) do
    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          {:ok, Enum.uniq(data), memory}
        else
          {:error, {:execution_error, "distinct requires a list, got #{inspect(data)}"}}
        end
    end
  end

  # Private helpers

  defp eval_nth(data, index) when is_list(data) do
    if is_integer(index) && index >= 0 do
      {:ok, Enum.at(data, index)}
    else
      {:error,
       {:execution_error, "nth index must be a non-negative integer, got #{inspect(index)}"}}
    end
  end

  defp eval_nth(data, _index) do
    {:error, {:execution_error, "nth requires a list, got #{inspect(data)}"}}
  end

  defp get_nested(data, path) when is_map(data) do
    path_as_atoms = Enum.map(path, &Access.key/1)
    get_in(data, path_as_atoms)
  end

  defp get_nested(_data, _path) do
    # Non-map values always return nil when accessing a path
    nil
  end

  defp handle_get_result(nil, node) do
    default = Map.get(node, "default")

    if Map.has_key?(node, "default") do
      {:ok, default}
    else
      {:ok, nil}
    end
  end

  defp handle_get_result(value, _node) do
    {:ok, value}
  end

  defp sort_by_list([], _field, _order), do: []

  defp sort_by_list(data, field, order) do
    sorter =
      case order do
        "desc" -> &>=/2
        _ -> &<=/2
      end

    Enum.sort_by(
      data,
      fn item ->
        if is_map(item), do: Map.get(item, field), else: nil
      end,
      sorter
    )
  end

  defp max_by_list([], _field), do: nil

  defp max_by_list(data, field) do
    data
    |> Enum.filter(fn item -> is_map(item) and Map.get(item, field) != nil end)
    |> case do
      [] -> nil
      items -> Enum.max_by(items, fn item -> Map.get(item, field) end)
    end
  end

  defp min_by_list([], _field), do: nil

  defp min_by_list(data, field) do
    data
    |> Enum.filter(fn item -> is_map(item) and Map.get(item, field) != nil end)
    |> case do
      [] -> nil
      items -> Enum.min_by(items, fn item -> Map.get(item, field) end)
    end
  end
end
