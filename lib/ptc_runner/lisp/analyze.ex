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

  # Comparison operators (strict 2-arity per spec section 8.4)
  defp dispatch_list_form({:symbol, op}, rest, _list)
       when op in [:=, :"not=", :>, :<, :>=, :<=],
       do: analyze_comparison(op, rest)

  # Generic function call
  defp dispatch_list_form(_head, _rest, list), do: analyze_call(list)

  # ============================================================
  # Special form: let
  # ============================================================

  defp analyze_let([bindings_ast, body_ast]) do
    with {:ok, bindings} <- analyze_bindings(bindings_ast),
         {:ok, body} <- do_analyze(body_ast) do
      {:ok, {:let, bindings, body}}
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

    case keys_pair do
      {{:keyword, :keys}, {:vector, key_asts}} ->
        with {:ok, keys} <- extract_keys(key_asts),
             {:ok, defaults} <- extract_defaults(or_pair) do
          base_pattern = {:destructure, {:keys, keys, defaults}}
          maybe_wrap_as(base_pattern, as_pair)
        end

      _ ->
        {:error, {:unsupported_pattern, pairs}}
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
      {{:keyword, k}, v}, {:ok, acc} ->
        {:cont, {:ok, [{k, v} | acc]}}

      {_other_key, _v}, _acc ->
        {:halt, {:error, {:invalid_form, "default keys must be keywords"}}}
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
  # Special form: if-let and when-let (conditional binding)
  # ============================================================

  # Desugar (if-let [x cond] then else) to (let [x cond] (if x then else))
  defp analyze_if_let([{:vector, [name_ast, cond_ast]}, then_ast, else_ast]) do
    with {:ok, {:var, _} = name} <- analyze_simple_binding(name_ast),
         {:ok, c} <- do_analyze(cond_ast),
         {:ok, t} <- do_analyze(then_ast),
         {:ok, e} <- do_analyze(else_ast) do
      binding = {:binding, name, c}
      {:ok, {:let, [binding], {:if, name, t, e}}}
    end
  end

  defp analyze_if_let([{:vector, bindings}, _then_ast, _else_ast]) when length(bindings) != 2 do
    {:error, {:invalid_form, "if-let requires exactly one binding pair [name expr]"}}
  end

  defp analyze_if_let(_) do
    {:error, {:invalid_arity, :"if-let", "expected (if-let [name expr] then else)"}}
  end

  # Desugar (when-let [x cond] body) to (let [x cond] (if x body nil))
  defp analyze_when_let([{:vector, [name_ast, cond_ast]}, body_ast]) do
    with {:ok, {:var, _} = name} <- analyze_simple_binding(name_ast),
         {:ok, c} <- do_analyze(cond_ast),
         {:ok, b} <- do_analyze(body_ast) do
      binding = {:binding, name, c}
      {:ok, {:let, [binding], {:if, name, b, nil}}}
    end
  end

  defp analyze_when_let([{:vector, bindings}, _body_ast]) when length(bindings) != 2 do
    {:error, {:invalid_form, "when-let requires exactly one binding pair [name expr]"}}
  end

  defp analyze_when_let(_) do
    {:error, {:invalid_arity, :"when-let", "expected (when-let [name expr] body)"}}
  end

  # Helper: only allow simple symbol bindings (no destructuring)
  defp analyze_simple_binding({:symbol, name}), do: {:ok, {:var, name}}

  defp analyze_simple_binding(_) do
    {:error, {:invalid_form, "binding must be a simple symbol, not a destructuring pattern"}}
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

  defp analyze_fn([params_ast, body_ast]) do
    with {:ok, params} <- analyze_fn_params(params_ast),
         {:ok, body} <- do_analyze(body_ast) do
      {:ok, {:fn, params, body}}
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
