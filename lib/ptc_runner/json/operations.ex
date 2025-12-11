defmodule PtcRunner.Json.Operations do
  @moduledoc """
  Built-in operations for the DSL.

  Implements built-in operations for the DSL (Phase 1: literal, load, var, pipe,
  filter, map, select, eq, sum, count; Phase 2: get, neq, gt, gte, lt, lte, first,
  last, nth, reject, contains, avg, min, max; Phase 3: let, if, and, or, not, merge,
  concat, zip; Phase 4: keys, typeof - introspection operations).

  This module acts as a dispatcher, delegating to specialized sub-modules:
  - PtcRunner.Json.Operations.Comparison - eq, neq, gt, gte, lt, lte, contains
  - PtcRunner.Json.Operations.Aggregation - sum, count, avg, min, max
  - PtcRunner.Json.Operations.Collection - filter, map, select, reject
  - PtcRunner.Json.Operations.Access - get, first, last, nth, sort_by, max_by, min_by
  """

  alias PtcRunner.Context
  alias PtcRunner.Json.Interpreter
  alias PtcRunner.Json.Operations.Access
  alias PtcRunner.Json.Operations.Aggregation
  alias PtcRunner.Json.Operations.Collection
  alias PtcRunner.Json.Operations.Comparison

  @doc """
  Evaluates a built-in operation.

  ## Arguments
    - op: Operation name
    - node: Operation definition map
    - context: Execution context
    - eval_fn: Function to recursively evaluate expressions

  ## Returns
    - `{:ok, result, memory}` on success
    - `{:error, reason}` on failure
  """
  @spec eval(String.t(), map(), Context.t(), function()) ::
          {:ok, any(), map()} | {:error, {atom(), String.t()}}

  # Data operations
  def eval("literal", node, context, _eval_fn) do
    {:ok, Map.get(node, "value"), context.memory}
  end

  def eval("load", node, context, _eval_fn) do
    name = Map.get(node, "name")

    case Context.get_ctx(context, name) do
      {:ok, value} -> {:ok, value, context.memory}
      {:error, _} = err -> err
    end
  end

  def eval("var", node, context, _eval_fn) do
    name = Map.get(node, "name")

    case Context.get_memory(context, name) do
      {:ok, value} -> {:ok, value, context.memory}
      {:error, _} = err -> err
    end
  end

  def eval("let", node, context, _eval_fn) do
    name = Map.get(node, "name")
    value_expr = Map.get(node, "value")
    in_expr = Map.get(node, "in")

    case Interpreter.eval(value_expr, context) do
      {:error, _} = err ->
        err

      {:ok, value, memory} ->
        new_context = Context.put_memory(%{context | memory: memory}, name, value)
        Interpreter.eval(in_expr, new_context)
    end
  end

  def eval("if", node, context, _eval_fn) do
    condition_expr = Map.get(node, "condition")
    then_expr = Map.get(node, "then")
    else_expr = Map.get(node, "else")

    case Interpreter.eval(condition_expr, context) do
      {:error, _} = err ->
        err

      {:ok, result, memory} ->
        new_context = %{context | memory: memory}

        if result in [false, nil] do
          Interpreter.eval(else_expr, new_context)
        else
          Interpreter.eval(then_expr, new_context)
        end
    end
  end

  def eval("and", node, context, _eval_fn) do
    conditions = Map.get(node, "conditions", [])
    eval_and(conditions, context)
  end

  def eval("or", node, context, _eval_fn) do
    conditions = Map.get(node, "conditions", [])
    eval_or(conditions, context)
  end

  def eval("not", node, context, _eval_fn) do
    condition_expr = Map.get(node, "condition")

    case Interpreter.eval(condition_expr, context) do
      {:error, _} = err ->
        err

      {:ok, result, memory} ->
        if result in [false, nil] do
          {:ok, true, memory}
        else
          {:ok, false, memory}
        end
    end
  end

  def eval("merge", node, context, _eval_fn) do
    objects = Map.get(node, "objects", [])
    eval_merge(objects, context)
  end

  def eval("concat", node, context, _eval_fn) do
    lists = Map.get(node, "lists", [])
    eval_concat(lists, context)
  end

  def eval("zip", node, context, _eval_fn) do
    lists = Map.get(node, "lists", [])
    eval_zip(lists, context)
  end

  # Control flow
  def eval("pipe", node, context, eval_fn) do
    steps = Map.get(node, "steps", [])
    eval_pipe(steps, nil, context, eval_fn)
  end

  # Comparison operations - delegate to sub-module
  def eval(op, node, context, eval_fn)
      when op in ["eq", "neq", "gt", "gte", "lt", "lte", "contains"] do
    Comparison.eval(op, node, context, eval_fn)
  end

  # Collection operations - delegate to sub-module
  def eval(op, node, context, eval_fn) when op in ["filter", "map", "select", "reject"] do
    Collection.eval(op, node, context, eval_fn)
  end

  # Aggregation operations - delegate to sub-module
  def eval(op, node, context, eval_fn) when op in ["sum", "count", "avg", "min", "max"] do
    Aggregation.eval(op, node, context, eval_fn)
  end

  # Access operations - delegate to sub-module
  def eval(op, node, context, eval_fn)
      when op in ["get", "first", "last", "nth", "sort_by", "max_by", "min_by"] do
    Access.eval(op, node, context, eval_fn)
  end

  # Introspection operations
  def eval("keys", _node, context, eval_fn) do
    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_map(data) do
          {:ok, data |> Map.keys() |> Enum.sort(), memory}
        else
          {:error, {:execution_error, "keys requires a map, got #{inspect(data)}"}}
        end
    end
  end

  def eval("typeof", _node, context, eval_fn) do
    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        {:ok, get_type_name(data), memory}
    end
  end

  # Tool integration
  def eval("call", node, context, _eval_fn) do
    tool_name = Map.get(node, "tool")
    args = Map.get(node, "args", %{})

    case Map.get(context.tools, tool_name) do
      nil ->
        {:error, {:execution_error, "Tool '#{tool_name}' not found"}}

      tool_fn ->
        try do
          case tool_fn.(args) do
            {:error, reason} ->
              {:error, {:execution_error, "Tool '#{tool_name}' error: #{inspect(reason)}"}}

            result ->
              {:ok, result, context.memory}
          end
        rescue
          e -> {:error, {:execution_error, "Tool '#{tool_name}' raised: #{Exception.message(e)}"}}
        end
    end
  end

  def eval(op, _node, _context, _eval_fn) do
    {:error, {:execution_error, "Unknown operation '#{op}'"}}
  end

  # Helper functions for control flow operations

  defp eval_pipe([], acc, context, _eval_fn) do
    {:ok, acc, context.memory}
  end

  defp eval_pipe([step | rest], acc, context, eval_fn) do
    # Create a wrapper that evaluates the current step with accumulated value
    step_with_input = Map.put(step, "__input", acc)

    case Interpreter.eval(step_with_input, context) do
      {:ok, result, memory} ->
        new_context = %{context | memory: memory}
        eval_pipe(rest, result, new_context, eval_fn)

      {:error, _} = err ->
        err
    end
  end

  defp eval_and([], context), do: {:ok, true, context.memory}

  defp eval_and([cond_expr | rest], context) do
    case Interpreter.eval(cond_expr, context) do
      {:error, _} = err ->
        err

      {:ok, result, memory} when result in [false, nil] ->
        {:ok, false, memory}

      {:ok, _result, memory} ->
        new_context = %{context | memory: memory}
        eval_and(rest, new_context)
    end
  end

  defp eval_or([], context), do: {:ok, false, context.memory}

  defp eval_or([cond_expr | rest], context) do
    case Interpreter.eval(cond_expr, context) do
      {:error, _} = err ->
        err

      {:ok, result, memory} when result in [false, nil] ->
        new_context = %{context | memory: memory}
        eval_or(rest, new_context)

      {:ok, _result, memory} ->
        {:ok, true, memory}
    end
  end

  defp eval_merge([], context) do
    {:ok, %{}, context.memory}
  end

  defp eval_merge(objects, context) do
    Enum.reduce_while(objects, {:ok, %{}, context.memory}, fn obj_expr, {:ok, acc, memory} ->
      ctx = %{context | memory: memory}

      case Interpreter.eval(obj_expr, ctx) do
        {:error, _} = err ->
          {:halt, err}

        {:ok, obj, new_memory} when is_map(obj) ->
          {:cont, {:ok, Map.merge(acc, obj), new_memory}}

        {:ok, obj, _memory} ->
          {:halt, {:error, {:execution_error, "merge requires map values, got #{inspect(obj)}"}}}
      end
    end)
    |> case do
      {:ok, result, final_memory} -> {:ok, result, final_memory}
      {:error, _} = err -> err
    end
  end

  defp eval_concat([], context) do
    {:ok, [], context.memory}
  end

  defp eval_concat(lists, context) do
    Enum.reduce_while(lists, {:ok, [], context.memory}, fn list_expr, {:ok, acc, memory} ->
      ctx = %{context | memory: memory}

      case Interpreter.eval(list_expr, ctx) do
        {:error, _} = err ->
          {:halt, err}

        {:ok, list, new_memory} when is_list(list) ->
          {:cont, {:ok, acc ++ list, new_memory}}

        {:ok, list, _memory} ->
          {:halt,
           {:error, {:execution_error, "concat requires list values, got #{inspect(list)}"}}}
      end
    end)
    |> case do
      {:ok, result, final_memory} -> {:ok, result, final_memory}
      {:error, _} = err -> err
    end
  end

  defp eval_zip([], context) do
    {:ok, [], context.memory}
  end

  defp eval_zip(lists, context) do
    case eval_all_lists(lists, context, []) do
      {:error, _} = err ->
        err

      {:ok, evaluated_lists, memory} ->
        {:ok, Enum.zip_with(evaluated_lists, & &1), memory}
    end
  end

  defp eval_all_lists([], context, acc) do
    {:ok, Enum.reverse(acc), context.memory}
  end

  defp eval_all_lists([list_expr | rest], context, acc) do
    case Interpreter.eval(list_expr, context) do
      {:error, _} = err ->
        err

      {:ok, list, new_memory} when is_list(list) ->
        new_context = %{context | memory: new_memory}
        eval_all_lists(rest, new_context, [list | acc])

      {:ok, list, _memory} ->
        {:error, {:execution_error, "zip requires list values, got #{inspect(list)}"}}
    end
  end

  defp get_type_name(nil), do: "null"
  defp get_type_name(v) when is_map(v), do: "object"
  defp get_type_name(v) when is_list(v), do: "list"
  defp get_type_name(v) when is_binary(v), do: "string"
  defp get_type_name(v) when is_number(v), do: "number"
  defp get_type_name(v) when is_boolean(v), do: "boolean"
end
