defmodule PtcRunner.Lisp.Analyze do
  @moduledoc """
  Validates and desugars RawAST into CoreAST.

  The analyzer transforms the parser's output (RawAST) into a validated,
  desugared intermediate form (CoreAST) that the interpreter can safely evaluate.

  ## Error Handling

  Returns `{:ok, CoreAST.t()}` on success or `{:error, error_reason()}` on failure.
  """

  alias PtcRunner.Lisp.CoreAST

  @type error_reason ::
          {:invalid_form, String.t()}
          | {:invalid_arity, atom(), String.t()}
          | {:invalid_where_form, String.t()}
          | {:invalid_where_operator, atom()}
          | {:invalid_call_tool_name, any()}
          | {:invalid_cond_form, String.t()}
          | {:invalid_thread_form, atom(), String.t()}
          | {:unsupported_pattern, term()}

  @spec analyze(term()) :: {:ok, CoreAST.t()} | {:error, error_reason()}
  def analyze(raw_ast) do
    do_analyze(raw_ast)
  end

  # ============================================================
  # Literals and basic values
  # ============================================================

  defp do_analyze(nil), do: {:ok, nil}
  defp do_analyze(true), do: {:ok, true}
  defp do_analyze(false), do: {:ok, false}
  defp do_analyze(n) when is_integer(n) or is_float(n), do: {:ok, n}

  defp do_analyze({:string, s}), do: {:ok, {:string, s}}
  defp do_analyze({:keyword, k}), do: {:ok, {:keyword, k}}

  # ============================================================
  # Collections
  # ============================================================

  defp do_analyze({:vector, elems}) do
    with {:ok, elems2} <- analyze_list(elems) do
      {:ok, {:vector, elems2}}
    end
  end

  defp do_analyze({:map, pairs}) do
    with {:ok, pairs2} <- analyze_pairs(pairs) do
      {:ok, {:map, pairs2}}
    end
  end

  defp do_analyze({:set, elems}) do
    with {:ok, elems2} <- analyze_list(elems) do
      {:ok, {:set, elems2}}
    end
  end

  # ============================================================
  # Short function syntax: #()
  # ============================================================

  defp do_analyze({:short_fn, body_asts}) do
    analyze_short_fn(body_asts)
  end

  # ============================================================
  # Symbols and variables
  # ============================================================

  defp do_analyze({:symbol, name}), do: {:ok, {:var, name}}
  defp do_analyze({:ns_symbol, :ctx, key}), do: {:ok, {:ctx, key}}
  defp do_analyze({:ns_symbol, :memory, key}), do: {:ok, {:memory, key}}

  # ============================================================
  # List forms (special forms and function calls)
  # ============================================================

  defp do_analyze({:list, [head | rest]} = list) do
    dispatch_list_form(head, rest, list)
  end

  defp do_analyze({:list, []}) do
    {:error, {:invalid_form, "Empty list is not a valid expression"}}
  end

  # Dispatch special forms based on the head symbol
  defp dispatch_list_form({:symbol, :let}, rest, _list), do: analyze_let(rest)
  defp dispatch_list_form({:symbol, :if}, rest, _list), do: analyze_if(rest)
  defp dispatch_list_form({:symbol, :fn}, rest, _list), do: analyze_fn(rest)
  defp dispatch_list_form({:symbol, :when}, rest, _list), do: analyze_when(rest)
  defp dispatch_list_form({:symbol, :"if-let"}, rest, _list), do: analyze_if_let(rest)
  defp dispatch_list_form({:symbol, :"when-let"}, rest, _list), do: analyze_when_let(rest)
  defp dispatch_list_form({:symbol, :cond}, rest, _list), do: analyze_cond(rest)
  defp dispatch_list_form({:symbol, :do}, rest, _list), do: analyze_do(rest)
  defp dispatch_list_form({:symbol, :->}, rest, _list), do: analyze_thread(:->, rest)
  defp dispatch_list_form({:symbol, :"->>"}, rest, _list), do: analyze_thread(:"->>", rest)
  defp dispatch_list_form({:symbol, :and}, rest, _list), do: analyze_and(rest)
  defp dispatch_list_form({:symbol, :or}, rest, _list), do: analyze_or(rest)
  defp dispatch_list_form({:symbol, :where}, rest, _list), do: analyze_where(rest)
  defp dispatch_list_form({:symbol, :"all-of"}, rest, _list), do: analyze_pred_comb(:all_of, rest)
  defp dispatch_list_form({:symbol, :"any-of"}, rest, _list), do: analyze_pred_comb(:any_of, rest)

  defp dispatch_list_form({:symbol, :"none-of"}, rest, _list),
    do: analyze_pred_comb(:none_of, rest)

  defp dispatch_list_form({:symbol, :call}, rest, _list), do: analyze_call_tool(rest)
  defp dispatch_list_form({:ns_symbol, :memory, :put}, rest, _list), do: analyze_memory_put(rest)
  defp dispatch_list_form({:ns_symbol, :memory, :get}, rest, _list), do: analyze_memory_get(rest)

  # Comparison operators (strict 2-arity per spec section 8.4)
  defp dispatch_list_form({:symbol, op}, rest, _list)
       when op in [:=, :"not=", :>, :<, :>=, :<=],
       do: analyze_comparison(op, rest)

  # Generic function call
  defp dispatch_list_form({:ns_symbol, ns, key}, [], _list) when ns in [:ctx, :memory] do
    {:ok, {ns, key}}
  end

  defp dispatch_list_form(_head, _rest, list), do: analyze_call(list)

  # ============================================================
  # Special form: do
  # ============================================================

  defp analyze_do(exprs_ast) do
    with {:ok, exprs} <- analyze_list(exprs_ast) do
      {:ok, {:do, exprs}}
    end
  end

  defp analyze_memory_put([key_ast, val_ast]) do
    with {:ok, key} <- do_analyze(key_ast),
         {:ok, val} <- do_analyze(val_ast) do
      {:ok, {:memory_put, key, val}}
    end
  end

  defp analyze_memory_put(_) do
    {:error, {:invalid_arity, :"memory/put", "expected (memory/put key value)"}}
  end

  defp analyze_memory_get([key_ast]) do
    with {:ok, key} <- do_analyze(key_ast) do
      {:ok, {:memory_get, key}}
    end
  end

  defp analyze_memory_get(_) do
    {:error, {:invalid_arity, :"memory/get", "expected (memory/get key)"}}
  end

  # ============================================================
  # Special form: if-let and when-let
  # ============================================================

  defp analyze_if_let([{:vector, [pattern_ast, value_ast]}, then_ast]) do
    analyze_if_let([{:vector, [pattern_ast, value_ast]}, then_ast, nil])
  end

  defp analyze_if_let([{:vector, [pattern_ast, value_ast]}, then_ast, else_ast]) do
    # Desugar: (if-let [x val] then else) -> (let [x val] (if x then else))
    # Note: Our 'let' already handles destructuring and bindings.
    # This is a slightly simplified version of Clojure's if-let but covers most agent needs.
    analyze_let([
      {:vector, [pattern_ast, value_ast]},
      {:list, [{:symbol, :if}, pattern_ast, then_ast, else_ast]}
    ])
  end

  defp analyze_if_let(_) do
    {:error,
     {:invalid_arity, :"if-let",
      "expected (if-let [pattern value] then) or (if-let [pattern value] then else)"}}
  end

  # Desugar: (when-let [x val] body) -> (if-let [x val] body nil)
  defp analyze_when_let([{:vector, [pattern_ast, value_ast]}, body_ast]) do
    analyze_if_let([{:vector, [pattern_ast, value_ast]}, body_ast, nil])
  end

  defp analyze_when_let(_) do
    {:error, {:invalid_arity, :"when-let", "expected (when-let [pattern value] body)"}}
  end

  # ============================================================
  # Special form: let
  # ============================================================

  defp analyze_let([bindings_ast | body_asts]) do
    with {:ok, bindings} <- analyze_bindings(bindings_ast),
         {:ok, body_exprs} <- analyze_list(body_asts) do
      case body_exprs do
        [] -> {:error, {:invalid_form, "let requires at least one body expression"}}
        [single] -> {:ok, {:let, bindings, single}}
        multiple -> {:ok, {:let, bindings, {:do, multiple}}}
      end
    end
  end

  defp analyze_let(_) do
    {:error, {:invalid_arity, :let, "expected (let [bindings] body)"}}
  end

  defp analyze_bindings({:vector, elems}) do
    if rem(length(elems), 2) != 0 do
      {:error, {:invalid_form, "let bindings require even number of forms"}}
    else
      elems
      |> Enum.chunk_every(2)
      |> Enum.reduce_while({:ok, []}, fn [pattern_ast, value_ast], {:ok, acc} ->
        with {:ok, pattern} <- analyze_pattern(pattern_ast),
             {:ok, value} <- do_analyze(value_ast) do
          {:cont, {:ok, [{:binding, pattern, value} | acc]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, rev} -> {:ok, Enum.reverse(rev)}
        other -> other
      end
    end
  end

  defp analyze_bindings(_) do
    {:error, {:invalid_form, "let bindings must be a vector"}}
  end

  # ============================================================
  # Pattern analysis (destructuring)
  # ============================================================

  defp analyze_pattern({:symbol, name}), do: {:ok, {:var, name}}

  defp analyze_pattern({:vector, elements}) do
    with {:ok, patterns} <- analyze_pattern_list(elements) do
      {:ok, {:destructure, {:seq, patterns}}}
    end
  end

  defp analyze_pattern({:map, pairs}) do
    analyze_destructure_map(pairs)
  end

  defp analyze_pattern(other) do
    {:error, {:unsupported_pattern, other}}
  end

  defp analyze_pattern_list(elements) do
    elements
    |> Enum.reduce_while({:ok, []}, fn elem, {:ok, acc} ->
      case analyze_pattern(elem) do
        {:ok, p} -> {:cont, {:ok, [p | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp analyze_destructure_map(pairs) do
    keys_pair =
      Enum.find(pairs, fn
        {{:keyword, k}, _} -> k == :keys
        _ -> false
      end)

    or_pair =
      Enum.find(pairs, fn
        {{:keyword, k}, _} -> k == :or
        _ -> false
      end)

    as_pair =
      Enum.find(pairs, fn
        {{:keyword, k}, _} -> k == :as
        _ -> false
      end)

    # Extract rename pairs (symbol keys paired with keyword values)
    rename_pairs =
      pairs
      |> Enum.filter(fn
        {{:symbol, _}, {:keyword, _}} -> true
        _ -> false
      end)

    with {:ok, keys} <- extract_keys_opt(keys_pair),
         {:ok, renames} <- extract_renames(rename_pairs),
         {:ok, defaults} <- extract_defaults(or_pair) do
      # Only create a pattern if we have keys, renames, or defaults
      has_keys = not Enum.empty?(keys)
      has_renames = not Enum.empty?(renames)
      has_defaults = not Enum.empty?(defaults)

      if has_keys || has_renames || has_defaults do
        base_pattern =
          if has_renames do
            {:destructure, {:map, keys, renames, defaults}}
          else
            {:destructure, {:keys, keys, defaults}}
          end

        maybe_wrap_as(base_pattern, as_pair)
      else
        {:error, {:unsupported_pattern, pairs}}
      end
    end
  end

  defp extract_keys_opt(keys_pair) do
    case keys_pair do
      {{:keyword, :keys}, {:vector, key_asts}} ->
        extract_keys(key_asts)

      nil ->
        {:ok, []}

      _ ->
        {:error, {:invalid_form, "invalid :keys destructuring form"}}
    end
  end

  defp extract_keys(key_asts) do
    Enum.reduce_while(key_asts, {:ok, []}, fn
      {:symbol, name}, {:ok, acc} ->
        {:cont, {:ok, [name | acc]}}

      {:keyword, k}, {:ok, acc} ->
        {:cont, {:ok, [k | acc]}}

      _other, _acc ->
        {:halt, {:error, {:invalid_form, "expected keyword or symbol in destructuring key"}}}
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp extract_renames(rename_pairs) do
    Enum.reduce_while(rename_pairs, {:ok, []}, fn
      {{:symbol, bind_name}, {:keyword, source_key}}, {:ok, acc} ->
        {:cont, {:ok, [{bind_name, source_key} | acc]}}

      _other, _acc ->
        {:halt, {:error, {:invalid_form, "rename pairs must be {symbol :keyword}"}}}
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp extract_defaults(or_pair) do
    case or_pair do
      {{:keyword, :or}, {:map, default_pairs}} ->
        extract_default_pairs(default_pairs)

      nil ->
        {:ok, []}
    end
  end

  defp extract_default_pairs(default_pairs) do
    Enum.reduce_while(default_pairs, {:ok, []}, fn
      {{:symbol, k}, v}, {:ok, acc} ->
        {:cont, {:ok, [{k, v} | acc]}}

      {_other_key, _v}, _acc ->
        {:halt, {:error, {:invalid_form, "default keys must be symbols"}}}
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp maybe_wrap_as(base_pattern, as_pair) do
    case as_pair do
      {{:keyword, :as}, {:symbol, as_name}} ->
        {:ok, {:destructure, {:as, as_name, base_pattern}}}

      nil ->
        {:ok, base_pattern}
    end
  end

  # ============================================================
  # Special form: if and when
  # ============================================================

  defp analyze_if([cond_ast, then_ast, else_ast]) do
    with {:ok, c} <- do_analyze(cond_ast),
         {:ok, t} <- do_analyze(then_ast),
         {:ok, e} <- do_analyze(else_ast) do
      {:ok, {:if, c, t, e}}
    end
  end

  defp analyze_if(_) do
    {:error, {:invalid_arity, :if, "expected (if cond then else)"}}
  end

  defp analyze_when([cond_ast, body_ast]) do
    with {:ok, c} <- do_analyze(cond_ast),
         {:ok, b} <- do_analyze(body_ast) do
      {:ok, {:if, c, b, nil}}
    end
  end

  defp analyze_when(_) do
    {:error, {:invalid_arity, :when, "expected (when cond body)"}}
  end

  # ============================================================
  # Special form: cond → nested if
  # ============================================================

  defp analyze_cond([]) do
    {:error, {:invalid_cond_form, "cond requires at least one test/result pair"}}
  end

  defp analyze_cond(args) do
    with {:ok, pairs, default} <- split_cond_args(args) do
      build_nested_if(pairs, default)
    end
  end

  defp split_cond_args(args) do
    case Enum.split(args, length(args) - 2) do
      {prefix, [{:keyword, :else}, default_ast]} ->
        validate_pairs(prefix, default_ast)

      _ ->
        validate_pairs(args, nil)
    end
  end

  defp validate_pairs(args, default_ast) do
    if rem(length(args), 2) != 0 do
      {:error, {:invalid_cond_form, "cond requires even number of test/result forms"}}
    else
      pairs = args |> Enum.chunk_every(2) |> Enum.map(fn [c, r] -> {c, r} end)
      {:ok, pairs, default_ast}
    end
  end

  defp build_nested_if(pairs, default_ast) do
    with {:ok, default_core} <- maybe_analyze(default_ast) do
      pairs
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, default_core}, fn {c_ast, r_ast}, {:ok, acc} ->
        with {:ok, c} <- do_analyze(c_ast),
             {:ok, r} <- do_analyze(r_ast) do
          {:cont, {:ok, {:if, c, r, acc}}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp maybe_analyze(nil), do: {:ok, nil}
  defp maybe_analyze(ast), do: do_analyze(ast)

  # ============================================================
  # Special form: fn (anonymous functions)
  # ============================================================

  defp analyze_fn([params_ast | body_asts]) do
    with {:ok, params} <- analyze_fn_params(params_ast),
         {:ok, body_exprs} <- analyze_list(body_asts) do
      case body_exprs do
        [] -> {:error, {:invalid_form, "fn requires at least one body expression"}}
        [single] -> {:ok, {:fn, params, single}}
        multiple -> {:ok, {:fn, params, {:do, multiple}}}
      end
    end
  end

  defp analyze_fn(_) do
    {:error, {:invalid_arity, :fn, "expected (fn [params] body)"}}
  end

  defp analyze_fn_params({:vector, param_asts}) do
    params =
      Enum.reduce_while(param_asts, {:ok, []}, fn ast, {:ok, acc} ->
        case analyze_pattern(ast) do
          {:ok, pattern} -> {:cont, {:ok, [pattern | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case params do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp analyze_fn_params(_) do
    {:error, {:invalid_form, "fn parameters must be a vector"}}
  end

  # ============================================================
  # Short function syntax: #()
  # ============================================================

  defp analyze_short_fn(body_asts) do
    # The parser gives us a list of AST elements that form the body
    # These could be:
    # 1. A single literal: #(42) -> [42]
    # 2. A function call: #(+ % 1) -> [{:symbol, :+}, {:symbol, :"%"}, 1]
    # 3. Any other single expression wrapped in a list

    # Convert body_asts into an actual body expression
    body_expr =
      case body_asts do
        [] ->
          nil

        [single_form] ->
          single_form

        multiple_forms ->
          # Multiple forms means it's likely a function call with args
          {:list, multiple_forms}
      end

    # Now find placeholders in the expression
    with placeholders_result <- extract_placeholders([body_expr]),
         {:ok, placeholders} <- validate_placeholder_result(placeholders_result),
         # 2. Determine arity
         arity <- determine_arity(placeholders),
         # 3. Generate parameter list [{:var, :p1}, {:var, :p2}, ...]
         params <- generate_params(arity),
         # 4. Replace placeholders in body
         transformed_body <- transform_body(body_expr, placeholders),
         # 5. Analyze the transformed body
         {:ok, analyzed_body} <- do_analyze(transformed_body) do
      {:ok, {:fn, params, analyzed_body}}
    end
  end

  defp validate_placeholder_result(:nested_short_fn) do
    {:error, {:invalid_form, "Nested #() anonymous functions are not allowed"}}
  end

  defp validate_placeholder_result(result) do
    result
  end

  # Extract all placeholder symbols (%, %1, %2, etc.) from AST
  defp extract_placeholders(asts) do
    # credo:disable-for-next-line
    try do
      placeholders =
        asts
        |> Enum.flat_map(&find_all_placeholders/1)
        |> Enum.uniq()

      {:ok, placeholders}
    catch
      :nested_short_fn ->
        :nested_short_fn
    end
  end

  # Recursively find all placeholder symbols in an AST node
  defp find_all_placeholders({:symbol, name}) do
    if placeholder?(name) do
      [name]
    else
      []
    end
  end

  defp find_all_placeholders({:vector, elems}) do
    Enum.flat_map(elems, &find_all_placeholders/1)
  end

  defp find_all_placeholders({:list, elems}) do
    Enum.flat_map(elems, &find_all_placeholders/1)
  end

  defp find_all_placeholders({:map, pairs}) do
    Enum.flat_map(pairs, fn {k, v} ->
      find_all_placeholders(k) ++ find_all_placeholders(v)
    end)
  end

  defp find_all_placeholders({:set, elems}) do
    Enum.flat_map(elems, &find_all_placeholders/1)
  end

  defp find_all_placeholders({:short_fn, _body_asts}) do
    # Nested #() is not allowed
    throw(:nested_short_fn)
  end

  defp find_all_placeholders(_), do: []

  # Check if a symbol name is a placeholder (%, %1, %2, etc.)
  defp placeholder?(name) do
    case to_string(name) do
      "%" -> true
      "%" <> rest -> String.match?(rest, ~r/^\d+$/)
      _ -> false
    end
  end

  # Determine arity from placeholders
  defp determine_arity(placeholders) do
    # Extract numeric placeholders
    numeric =
      placeholders
      |> Enum.filter(&(to_string(&1) != "%"))
      |> Enum.map(fn p ->
        p
        |> to_string()
        |> String.replace_leading("%", "")
        |> String.to_integer()
      end)

    case numeric do
      [] ->
        # Only % or no placeholders, arity is 1 if % exists, 0 otherwise
        if Enum.any?(placeholders, &(to_string(&1) == "%")) do
          1
        else
          0
        end

      nums ->
        Enum.max(nums)
    end
  end

  # Generate parameter list based on arity
  defp generate_params(0) do
    []
  end

  defp generate_params(arity) when arity > 0 do
    Enum.map(1..arity, fn i -> {:var, String.to_atom("p#{i}")} end)
  end

  # Transform body by replacing placeholders with parameter variables
  # credo:disable-for-next-line Credo.Check.Warning.UnusedVariable
  defp transform_body(asts, placeholders) when is_list(asts) do
    Enum.map(asts, &transform_body(&1, placeholders))
  end

  defp transform_body({:symbol, name}, _placeholders) when is_atom(name) do
    name_str = to_string(name)

    case placeholder?(name) do
      true ->
        param_name = placeholder_to_param(name_str)
        {:symbol, param_name}

      false ->
        {:symbol, name}
    end
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnusedVariable
  defp transform_body({:vector, elems}, placeholders) do
    {:vector, transform_body(elems, placeholders)}
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnusedVariable
  defp transform_body({:list, elems}, placeholders) do
    {:list, transform_body(elems, placeholders)}
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnusedVariable
  defp transform_body({:map, pairs}, placeholders) do
    {:map,
     Enum.map(pairs, fn {k, v} ->
       {transform_body(k, placeholders), transform_body(v, placeholders)}
     end)}
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnusedVariable
  defp transform_body({:set, elems}, placeholders) do
    {:set, transform_body(elems, placeholders)}
  end

  defp transform_body(node, _placeholders) do
    node
  end

  # Convert placeholder symbol to parameter variable name
  defp placeholder_to_param(name_str) when is_binary(name_str) do
    case name_str do
      "%" -> :p1
      "%" <> num_str -> String.to_atom("p#{num_str}")
    end
  end

  # ============================================================
  # Short-circuit logic: and/or
  # ============================================================

  defp analyze_and(args) do
    with {:ok, exprs} <- analyze_list(args) do
      {:ok, {:and, exprs}}
    end
  end

  defp analyze_or(args) do
    with {:ok, exprs} <- analyze_list(args) do
      {:ok, {:or, exprs}}
    end
  end

  # ============================================================
  # Threading macros: -> and ->>
  # ============================================================

  defp analyze_thread(kind, []) do
    {:error, {:invalid_thread_form, kind, "requires at least one expression"}}
  end

  defp analyze_thread(kind, [first | steps]) do
    with {:ok, acc} <- do_analyze(first) do
      thread_steps(kind, acc, steps)
    end
  end

  defp thread_steps(_kind, acc, []), do: {:ok, acc}

  defp thread_steps(kind, acc, [step | rest]) do
    with {:ok, acc2} <- apply_thread_step(kind, acc, step) do
      thread_steps(kind, acc2, rest)
    end
  end

  defp apply_thread_step(kind, acc, {:list, [f_ast | arg_asts]}) do
    with {:ok, f} <- do_analyze(f_ast),
         {:ok, args} <- analyze_list(arg_asts) do
      new_args =
        case kind do
          :-> -> [acc | args]
          :"->>" -> args ++ [acc]
        end

      {:ok, {:call, f, new_args}}
    end
  end

  defp apply_thread_step(_kind, acc, step_ast) do
    with {:ok, f} <- do_analyze(step_ast) do
      {:ok, {:call, f, [acc]}}
    end
  end

  # ============================================================
  # Predicates: where
  # ============================================================

  defp analyze_where(args) do
    case args do
      [field_ast] ->
        with {:ok, field_path} <- analyze_field_path(field_ast) do
          {:ok, {:where, field_path, :truthy, nil}}
        end

      [field_ast, value_ast] ->
        # Handle (where :field value) as (where :field = value)
        with {:ok, field_path} <- analyze_field_path(field_ast),
             {:ok, value} <- do_analyze(value_ast) do
          {:ok, {:where, field_path, :eq, value}}
        end

      [field_ast, {:symbol, op}, value_ast] ->
        with {:ok, field_path} <- analyze_field_path(field_ast),
             {:ok, op_tag} <- classify_where_op(op),
             {:ok, value} <- do_analyze(value_ast) do
          {:ok, {:where, field_path, op_tag, value}}
        end

      _ ->
        {:error, {:invalid_where_form, "expected (where field) or (where field op value)"}}
    end
  end

  defp analyze_field_path({:keyword, k}) do
    {:ok, {:field, [{:keyword, k}]}}
  end

  defp analyze_field_path({:vector, elems}) do
    with {:ok, segments} <- extract_field_segments(elems) do
      {:ok, {:field, segments}}
    end
  end

  defp analyze_field_path(other) do
    {:error, {:invalid_where_form, "field must be keyword or vector, got: #{inspect(other)}"}}
  end

  defp extract_field_segments(elems) do
    Enum.reduce_while(elems, {:ok, []}, fn
      {:keyword, k}, {:ok, acc} ->
        {:cont, {:ok, [{:keyword, k} | acc]}}

      {:string, s}, {:ok, acc} ->
        {:cont, {:ok, [{:string, s} | acc]}}

      _other, _acc ->
        {:halt,
         {:error, {:invalid_where_form, "field path elements must be keywords or strings"}}}
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp classify_where_op(:=), do: {:ok, :eq}
  defp classify_where_op(:"not="), do: {:ok, :not_eq}
  defp classify_where_op(:>), do: {:ok, :gt}
  defp classify_where_op(:<), do: {:ok, :lt}
  defp classify_where_op(:>=), do: {:ok, :gte}
  defp classify_where_op(:<=), do: {:ok, :lte}
  defp classify_where_op(:includes), do: {:ok, :includes}
  defp classify_where_op(:in), do: {:ok, :in}
  defp classify_where_op(op), do: {:error, {:invalid_where_operator, op}}

  # ============================================================
  # Predicate combinators: all-of, any-of, none-of
  # ============================================================

  defp analyze_pred_comb(kind, args) do
    with {:ok, preds} <- analyze_list(args) do
      {:ok, {:pred_combinator, kind, preds}}
    end
  end

  # ============================================================
  # Tool invocation: call
  # ============================================================

  defp analyze_call_tool([{:string, name}]) do
    {:ok, {:call_tool, name, {:map, []}}}
  end

  defp analyze_call_tool([{:string, name}, args_ast]) do
    with {:ok, args_core} <- do_analyze(args_ast) do
      case args_core do
        {:map, _} = args_map ->
          {:ok, {:call_tool, name, args_map}}

        other ->
          {:error, {:invalid_form, "call args must be a map, got: #{inspect(other)}"}}
      end
    end
  end

  defp analyze_call_tool([other | _]) do
    {:error,
     {:invalid_call_tool_name, "tool name must be string literal, got: #{inspect(other)}"}}
  end

  defp analyze_call_tool(_) do
    {:error,
     {:invalid_arity, :call, "expected (call \"tool-name\") or (call \"tool-name\" args)"}}
  end

  # ============================================================
  # Comparison operators (strict 2-arity)
  # ============================================================

  defp analyze_comparison(op, [left_ast, right_ast]) do
    with {:ok, left} <- do_analyze(left_ast),
         {:ok, right} <- do_analyze(right_ast) do
      {:ok, {:call, {:var, op}, [left, right]}}
    end
  end

  defp analyze_comparison(op, args) do
    {:error,
     {:invalid_arity, op,
      "comparison operators require exactly 2 arguments, got #{length(args)}. " <>
        "Use (and (#{op} a b) (#{op} b c)) for chained comparisons."}}
  end

  # ============================================================
  # Generic function call
  # ============================================================

  defp analyze_call({:list, [f_ast | arg_asts]}) do
    with {:ok, f} <- do_analyze(f_ast),
         {:ok, args} <- analyze_list(arg_asts) do
      {:ok, {:call, f, args}}
    end
  end

  # ============================================================
  # Helper functions
  # ============================================================

  defp analyze_list(xs) do
    xs
    |> Enum.reduce_while({:ok, []}, fn x, {:ok, acc} ->
      case do_analyze(x) do
        {:ok, x2} -> {:cont, {:ok, [x2 | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp analyze_pairs(pairs) do
    pairs
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      with {:ok, k2} <- do_analyze(k),
           {:ok, v2} <- do_analyze(v) do
        {:cont, {:ok, [{k2, v2} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end
end
