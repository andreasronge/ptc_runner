defmodule PtcRunner.Operations do
  @moduledoc """
  Built-in operations for the DSL.

  Implements built-in operations for the DSL (Phase 1: literal, load, var, pipe,
  filter, map, select, eq, sum, count; Phase 2: get, neq, gt, gte, lt, lte, first,
  last, nth, reject, contains, avg, min, max; Phase 3: let, if, and, or, not, merge,
  concat, zip).
  """

  alias PtcRunner.Context
  alias PtcRunner.Interpreter

  @doc """
  Evaluates a built-in operation.

  ## Arguments
    - op: Operation name
    - node: Operation definition map
    - context: Execution context
    - eval_fn: Function to recursively evaluate expressions

  ## Returns
    - `{:ok, result}` on success
    - `{:error, reason}` on failure
  """
  @spec eval(String.t(), map(), Context.t(), function()) ::
          {:ok, any()} | {:error, {atom(), String.t()}}

  # Data operations
  def eval("literal", node, _context, _eval_fn) do
    {:ok, Map.get(node, "value")}
  end

  def eval("load", node, context, _eval_fn) do
    name = Map.get(node, "name")
    Context.get_var(context, name)
  end

  def eval("var", node, context, _eval_fn) do
    name = Map.get(node, "name")
    Context.get_var(context, name)
  end

  def eval("let", node, context, _eval_fn) do
    name = Map.get(node, "name")
    value_expr = Map.get(node, "value")
    in_expr = Map.get(node, "in")

    case Interpreter.eval(value_expr, context) do
      {:error, _} = err ->
        err

      {:ok, value} ->
        new_context = Context.put_var(context, name, value)
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

      {:ok, result} ->
        if result in [false, nil] do
          Interpreter.eval(else_expr, context)
        else
          Interpreter.eval(then_expr, context)
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

      {:ok, result} ->
        if result in [false, nil] do
          {:ok, true}
        else
          {:ok, false}
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

  # Collection operations
  def eval("filter", node, context, eval_fn) do
    where_clause = Map.get(node, "where")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data} ->
        if is_list(data) do
          filter_list(data, where_clause, context, eval_fn)
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

      {:ok, data} ->
        if is_list(data) do
          map_list(data, expr, context, eval_fn)
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

      {:ok, data} ->
        if is_list(data) do
          select_list(data, fields)
        else
          {:error, {:execution_error, "select requires a list, got #{inspect(data)}"}}
        end
    end
  end

  # Comparison
  def eval("eq", node, context, eval_fn), do: eval_comparison(node, context, eval_fn, "eq", &==/2)

  def eval("neq", node, context, eval_fn),
    do: eval_comparison(node, context, eval_fn, "neq", &!=/2)

  def eval("gt", node, context, eval_fn), do: eval_comparison(node, context, eval_fn, "gt", &>/2)

  def eval("gte", node, context, eval_fn),
    do: eval_comparison(node, context, eval_fn, "gte", &>=/2)

  def eval("lt", node, context, eval_fn), do: eval_comparison(node, context, eval_fn, "lt", &</2)

  def eval("lte", node, context, eval_fn),
    do: eval_comparison(node, context, eval_fn, "lte", &<=/2)

  def eval("contains", node, context, eval_fn) do
    field = Map.get(node, "field")
    value = Map.get(node, "value")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data} ->
        if is_map(data) do
          field_value = Map.get(data, field)
          {:ok, contains_value?(field_value, value)}
        else
          {:error, {:execution_error, "contains requires a map, got #{inspect(data)}"}}
        end
    end
  end

  # Access operations
  def eval("get", node, context, eval_fn) do
    path = Map.get(node, "path", [])

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data} ->
        result =
          if path == [] do
            data
          else
            get_nested(data, path)
          end

        handle_get_result(result, node)
    end
  end

  # Aggregations
  def eval("sum", node, context, eval_fn) do
    field = Map.get(node, "field")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data} ->
        if is_list(data) do
          sum_list(data, field)
        else
          {:error, {:execution_error, "sum requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("count", _node, context, eval_fn) do
    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data} ->
        if is_list(data) do
          {:ok, length(data)}
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

      {:ok, data} ->
        if is_list(data) do
          avg_list(data, field)
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

      {:ok, data} ->
        if is_list(data) do
          min_list(data, field)
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

      {:ok, data} ->
        if is_list(data) do
          max_list(data, field)
        else
          {:error, {:execution_error, "max requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("first", _node, context, eval_fn) do
    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data} ->
        if is_list(data) do
          {:ok, List.first(data)}
        else
          {:error, {:execution_error, "first requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval("last", _node, context, eval_fn) do
    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data} ->
        if is_list(data) do
          {:ok, List.last(data)}
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

      {:ok, data} ->
        eval_nth(data, index)
    end
  end

  def eval("reject", node, context, eval_fn) do
    where_clause = Map.get(node, "where")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data} ->
        if is_list(data) do
          reject_list(data, where_clause, context, eval_fn)
        else
          {:error, {:execution_error, "reject requires a list, got #{inspect(data)}"}}
        end
    end
  end

  def eval(op, _node, _context, _eval_fn) do
    {:error, {:execution_error, "Unknown operation '#{op}'"}}
  end

  # Helper functions

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

  defp eval_comparison(node, context, eval_fn, op_name, compare_fn) do
    field = Map.get(node, "field")
    value = Map.get(node, "value")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data} ->
        if is_map(data) do
          data_value = Map.get(data, field)
          {:ok, compare_fn.(data_value, value)}
        else
          {:error, {:execution_error, "#{op_name} requires a map, got #{inspect(data)}"}}
        end
    end
  end

  defp eval_pipe([], acc, _context, _eval_fn) do
    {:ok, acc}
  end

  defp eval_pipe([step | rest], acc, context, eval_fn) do
    # Create a wrapper that evaluates the current step with accumulated value
    step_with_input = Map.put(step, "__input", acc)

    case Interpreter.eval(step_with_input, context) do
      {:ok, result} -> eval_pipe(rest, result, context, eval_fn)
      {:error, _} = err -> err
    end
  end

  defp eval_and([], _context), do: {:ok, true}

  defp eval_and([cond_expr | rest], context) do
    case Interpreter.eval(cond_expr, context) do
      {:error, _} = err ->
        err

      {:ok, result} when result in [false, nil] ->
        {:ok, false}

      {:ok, _} ->
        eval_and(rest, context)
    end
  end

  defp eval_or([], _context), do: {:ok, false}

  defp eval_or([cond_expr | rest], context) do
    case Interpreter.eval(cond_expr, context) do
      {:error, _} = err ->
        err

      {:ok, result} when result in [false, nil] ->
        eval_or(rest, context)

      {:ok, _} ->
        {:ok, true}
    end
  end

  defp filter_list(data, where_clause, context, _eval_fn) do
    Enum.reduce_while(data, {:ok, []}, fn item, {:ok, acc} ->
      # Inject item as __input for evaluation
      where_clause_with_input = Map.put(where_clause, "__input", item)

      case Interpreter.eval(where_clause_with_input, context) do
        {:ok, true} ->
          {:cont, {:ok, acc ++ [item]}}

        {:ok, false} ->
          {:cont, {:ok, acc}}

        {:ok, result} ->
          {:halt,
           {:error,
            {:execution_error, "filter where clause must return boolean, got #{inspect(result)}"}}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp reject_list(data, where_clause, context, _eval_fn) do
    Enum.reduce_while(data, {:ok, []}, fn item, {:ok, acc} ->
      # Inject item as __input for evaluation
      where_clause_with_input = Map.put(where_clause, "__input", item)

      case Interpreter.eval(where_clause_with_input, context) do
        {:ok, true} ->
          {:cont, {:ok, acc}}

        {:ok, false} ->
          {:cont, {:ok, acc ++ [item]}}

        {:ok, result} ->
          {:halt,
           {:error,
            {:execution_error, "reject where clause must return boolean, got #{inspect(result)}"}}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp map_list(data, expr, context, _eval_fn) do
    Enum.reduce_while(data, {:ok, []}, fn item, {:ok, acc} ->
      # Inject item as __input for evaluation
      expr_with_input = Map.put(expr, "__input", item)

      case Interpreter.eval(expr_with_input, context) do
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp select_list(data, fields) do
    result =
      Enum.map(data, fn item ->
        if is_map(item) do
          Map.take(item, fields)
        else
          item
        end
      end)

    {:ok, result}
  end

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

  defp contains_value?(field_value, value) when is_list(field_value), do: value in field_value

  defp contains_value?(field_value, value) when is_binary(field_value) and is_binary(value),
    do: String.contains?(field_value, value)

  defp contains_value?(field_value, value) when is_map(field_value),
    do: Map.has_key?(field_value, value)

  defp contains_value?(_field_value, _value), do: false

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

  defp eval_merge([], _context) do
    {:ok, %{}}
  end

  defp eval_merge(objects, context) do
    Enum.reduce_while(objects, {:ok, %{}}, fn obj_expr, {:ok, acc} ->
      case Interpreter.eval(obj_expr, context) do
        {:error, _} = err ->
          {:halt, err}

        {:ok, obj} when is_map(obj) ->
          {:cont, {:ok, Map.merge(acc, obj)}}

        {:ok, obj} ->
          {:halt, {:error, {:execution_error, "merge requires map values, got #{inspect(obj)}"}}}
      end
    end)
  end

  defp eval_concat([], _context) do
    {:ok, []}
  end

  defp eval_concat(lists, context) do
    Enum.reduce_while(lists, {:ok, []}, fn list_expr, {:ok, acc} ->
      case Interpreter.eval(list_expr, context) do
        {:error, _} = err ->
          {:halt, err}

        {:ok, list} when is_list(list) ->
          {:cont, {:ok, acc ++ list}}

        {:ok, list} ->
          {:halt,
           {:error, {:execution_error, "concat requires list values, got #{inspect(list)}"}}}
      end
    end)
  end

  defp eval_zip([], _context) do
    {:ok, []}
  end

  defp eval_zip(lists, context) do
    case eval_all_lists(lists, context, []) do
      {:error, _} = err ->
        err

      {:ok, evaluated_lists} ->
        {:ok, do_zip(evaluated_lists)}
    end
  end

  defp eval_all_lists([], _context, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp eval_all_lists([list_expr | rest], context, acc) do
    case Interpreter.eval(list_expr, context) do
      {:error, _} = err ->
        err

      {:ok, list} when is_list(list) ->
        eval_all_lists(rest, context, [list | acc])

      {:ok, list} ->
        {:error, {:execution_error, "zip requires list values, got #{inspect(list)}"}}
    end
  end

  defp do_zip([]), do: []
  defp do_zip([[] | _]), do: []

  defp do_zip(lists) do
    # Take first element from each list
    heads =
      Enum.map(lists, fn
        [h | _] -> h
        [] -> nil
      end)

    # Check if any list is empty
    if Enum.any?(heads, &is_nil/1) do
      []
    else
      # Recurse with tails
      tails = Enum.map(lists, fn [_ | t] -> t end)
      [heads | do_zip(tails)]
    end
  end
end
