defmodule PtcRunner.Json.Operations.Aggregation do
  @moduledoc """
  Aggregation operations for the JSON DSL.

  Implements aggregations: sum, count, avg, min, max.
  """

  @doc """
  Evaluates an aggregation operation.

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

  def eval("sum", node, context, eval_fn) do
    field = Map.get(node, "field")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          case sum_list(data, field) do
            {:ok, result} -> {:ok, result, memory}
            {:error, _} = err -> err
          end
        else
          {:error, {:execution_error, "sum requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("count", _node, context, eval_fn) do
    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          {:ok, length(data), memory}
        else
          {:error, {:execution_error, "count requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("avg", node, context, eval_fn) do
    field = Map.get(node, "field")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          case avg_list(data, field) do
            {:ok, result} -> {:ok, result, memory}
          end
        else
          {:error, {:execution_error, "avg requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("min", node, context, eval_fn) do
    field = Map.get(node, "field")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          case min_list(data, field) do
            {:ok, result} -> {:ok, result, memory}
            {:error, _} = err -> err
          end
        else
          {:error, {:execution_error, "min requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("max", node, context, eval_fn) do
    field = Map.get(node, "field")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          case max_list(data, field) do
            {:ok, result} -> {:ok, result, memory}
            {:error, _} = err -> err
          end
        else
          {:error, {:execution_error, "max requires a list, got #{inspect(data)}"}}
        end
    end
  end

  # Private helpers

  defp sum_list(data, field) do
    Enum.reduce_while(data, {:ok, 0}, fn item, {:ok, acc} ->
      sum_item(item, field, acc)
    end)
  end

  defp sum_item(item, field, acc) do
    if is_map(item) do
      case Map.get(item, field) do
        val when is_number(val) ->
          {:cont, {:ok, acc + val}}

        nil ->
          {:cont, {:ok, acc}}

        val ->
          {:halt,
           {:error, {:execution_error, "sum requires numeric values, got #{inspect(val)}"}}}
      end
    else
      {:halt, {:error, {:execution_error, "sum requires list of maps, got #{inspect(item)}"}}}
    end
  end

  defp avg_list([], _field), do: {:ok, nil}

  defp avg_list(data, field) do
    {sum, count} =
      Enum.reduce(data, {0, 0}, fn item, {sum_acc, count_acc} ->
        case get_numeric_value(item, field) do
          {:ok, val} -> {sum_acc + val, count_acc + 1}
          :skip -> {sum_acc, count_acc}
        end
      end)

    if count == 0, do: {:ok, nil}, else: {:ok, sum / count}
  end

  defp min_list([], _field), do: {:ok, nil}

  defp min_list(data, field) do
    Enum.reduce(data, {:ok, nil}, fn item, acc ->
      update_min(acc, item, field)
    end)
  end

  defp update_min({:ok, nil}, item, field) do
    case get_item_value(item, field) do
      {:ok, val} -> {:ok, val}
      :skip -> {:ok, nil}
    end
  end

  defp update_min({:ok, min_val}, item, field) do
    case get_item_value(item, field) do
      {:ok, val} -> {:ok, min(min_val, val)}
      :skip -> {:ok, min_val}
    end
  end

  defp max_list([], _field), do: {:ok, nil}

  defp max_list(data, field) do
    Enum.reduce(data, {:ok, nil}, fn item, acc ->
      update_max(acc, item, field)
    end)
  end

  defp update_max({:ok, nil}, item, field) do
    case get_item_value(item, field) do
      {:ok, val} -> {:ok, val}
      :skip -> {:ok, nil}
    end
  end

  defp update_max({:ok, max_val}, item, field) do
    case get_item_value(item, field) do
      {:ok, val} -> {:ok, max(max_val, val)}
      :skip -> {:ok, max_val}
    end
  end

  defp get_numeric_value(item, field) when is_map(item) do
    case Map.get(item, field) do
      val when is_number(val) -> {:ok, val}
      nil -> :skip
      _val -> :skip
    end
  end

  defp get_numeric_value(_item, _field), do: :skip

  defp get_item_value(item, field) when is_map(item) do
    case Map.get(item, field) do
      nil -> :skip
      val -> {:ok, val}
    end
  end

  defp get_item_value(_item, _field), do: :skip
end
