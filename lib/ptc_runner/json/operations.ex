defmodule PtcRunner.Json.Operations do
  @moduledoc """
  Built-in operations for the DSL.

  Implements built-in operations for the DSL (Phase 1: literal, load, var, pipe,
  filter, map, select, eq, sum, count; Phase 2: get, neq, gt, gte, lt, lte, first,
  last, nth, reject, contains, avg, min, max; Phase 3: let, if, and, or, not, merge,
  concat, zip; Phase 4: keys, typeof - introspection operations).
  """

  alias PtcRunner.Context
  alias PtcRunner.Json.Interpreter

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

  # Collection operations
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

      {:ok, data, memory} ->
        if is_map(data) do
          field_value = Map.get(data, field)
          {:ok, contains_value?(field_value, value), memory}
        else
          {:error, {:execution_error, "contains requires a map, got #{inspect(data)}"}}
        end
    end
  end

  # Access operations
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

  # Aggregations
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

      {:ok, data, memory} ->
        if is_map(data) do
          data_value = Map.get(data, field)
          {:ok, compare_fn.(data_value, value), memory}
        else
          {:error, {:execution_error, "#{op_name} requires a map, got #{inspect(data)}"}}
        end
    end
  end

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

  defp get_type_name(nil), do: "null"
  defp get_type_name(v) when is_map(v), do: "object"
  defp get_type_name(v) when is_list(v), do: "list"
  defp get_type_name(v) when is_binary(v), do: "string"
  defp get_type_name(v) when is_number(v), do: "number"
  defp get_type_name(v) when is_boolean(v), do: "boolean"
end
