defmodule PtcRunner.Json.Operations.Collection do
  @moduledoc """
  Collection operations for the JSON DSL.

  Implements collection transformations: filter, map, select, reject, filter_in.
  """

  alias PtcRunner.Json.Interpreter

  @doc """
  Evaluates a collection operation.

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

  def eval("filter", node, context, eval_fn) do
    where_clause = Map.get(node, "where")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        new_context = %{context | memory: memory}

        if is_list(data) do
          filter_list(data, where_clause, new_context, eval_fn)
        else
          {:error, {:execution_error, "filter requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("map", node, context, eval_fn) do
    expr = Map.get(node, "expr")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        new_context = %{context | memory: memory}

        if is_list(data) do
          map_list(data, expr, new_context, eval_fn)
        else
          {:error, {:execution_error, "map requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("select", node, context, eval_fn) do
    fields = Map.get(node, "fields", [])

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_list(data) do
          {:ok, select_list(data, fields), memory}
        else
          {:error, {:execution_error, "select requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("reject", node, context, eval_fn) do
    where_clause = Map.get(node, "where")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        new_context = %{context | memory: memory}

        if is_list(data) do
          reject_list(data, where_clause, new_context, eval_fn)
        else
          {:error, {:execution_error, "reject requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("filter_in", node, context, eval_fn) do
    field = Map.get(node, "field")
    value = Map.get(node, "value")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        new_context = %{context | memory: memory}

        if is_list(data) do
          filter_in_list(data, field, value, new_context)
        else
          {:error, {:execution_error, "filter_in requires a list, got #{inspect(data)}"}}
        end
    end
  end

  # Private helpers

  defp filter_list(data, where_clause, context, _eval_fn) do
    Enum.reduce_while(data, {:ok, [], context.memory}, fn item, {:ok, acc, memory} ->
      # Inject item as __input for evaluation
      where_clause_with_input = Map.put(where_clause, "__input", item)
      ctx = %{context | memory: memory}

      case Interpreter.eval(where_clause_with_input, ctx) do
        {:ok, true, new_memory} ->
          {:cont, {:ok, acc ++ [item], new_memory}}

        {:ok, false, new_memory} ->
          {:cont, {:ok, acc, new_memory}}

        {:ok, result, _memory} ->
          {:halt,
           {:error,
            {:execution_error, "filter where clause must return boolean, got #{inspect(result)}"}}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, result, final_memory} -> {:ok, result, final_memory}
      {:error, _} = err -> err
    end
  end

  defp reject_list(data, where_clause, context, _eval_fn) do
    Enum.reduce_while(data, {:ok, [], context.memory}, fn item, {:ok, acc, memory} ->
      # Inject item as __input for evaluation
      where_clause_with_input = Map.put(where_clause, "__input", item)
      ctx = %{context | memory: memory}

      case Interpreter.eval(where_clause_with_input, ctx) do
        {:ok, true, new_memory} ->
          {:cont, {:ok, acc, new_memory}}

        {:ok, false, new_memory} ->
          {:cont, {:ok, acc ++ [item], new_memory}}

        {:ok, result, _memory} ->
          {:halt,
           {:error,
            {:execution_error, "reject where clause must return boolean, got #{inspect(result)}"}}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, result, final_memory} -> {:ok, result, final_memory}
      {:error, _} = err -> err
    end
  end

  defp map_list(data, expr, context, _eval_fn) do
    Enum.reduce_while(data, {:ok, [], context.memory}, fn item, {:ok, acc, memory} ->
      # Inject item as __input for evaluation
      expr_with_input = Map.put(expr, "__input", item)
      ctx = %{context | memory: memory}

      case Interpreter.eval(expr_with_input, ctx) do
        {:ok, result, new_memory} -> {:cont, {:ok, acc ++ [result], new_memory}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, result, final_memory} -> {:ok, result, final_memory}
      {:error, _} = err -> err
    end
  end

  defp select_list(data, fields) do
    Enum.map(data, fn item ->
      if is_map(item) do
        Map.take(item, fields)
      else
        item
      end
    end)
  end

  defp filter_in_list(data, field, value, context) do
    result =
      Enum.filter(data, fn item ->
        if is_map(item) do
          field_value = Map.get(item, field)
          member?(field_value, value)
        else
          false
        end
      end)

    {:ok, result, context.memory}
  end

  defp member?(field_value, set) when is_list(set), do: field_value in set
  defp member?(field_value, set) when is_map(set), do: Map.has_key?(set, field_value)
  defp member?(_field_value, _set), do: false
end
