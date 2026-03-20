defmodule PtcRunner.Lisp.Analyze.Conditionals do
  @moduledoc """
  Conditional analysis for `if`, `if-not`, `when`, `when-not`, `if-let`,
  `when-let`, `if-some`, `when-some`, `when-first`, `cond`, `case`, and `condp` forms.

  Transforms conditional expressions into CoreAST `{:if, ...}` nodes,
  using callback functions for analyzing sub-expressions and wrapping bodies.
  """

  # ============================================================
  # if
  # ============================================================

  @doc """
  Analyzes an `if` form.
  """
  def analyze_if([cond_ast, then_ast, else_ast], tail?, analyze_fn, _wrap_body_fn) do
    with {:ok, c} <- analyze_fn.(cond_ast, false),
         {:ok, t} <- analyze_fn.(then_ast, tail?),
         {:ok, e} <- analyze_fn.(else_ast, tail?) do
      {:ok, {:if, c, t, e}}
    end
  end

  def analyze_if([cond_ast, then_ast], tail?, analyze_fn, _wrap_body_fn) do
    with {:ok, c} <- analyze_fn.(cond_ast, false),
         {:ok, t} <- analyze_fn.(then_ast, tail?) do
      {:ok, {:if, c, t, nil}}
    end
  end

  def analyze_if(_, _tail?, _analyze_fn, _wrap_body_fn) do
    {:error, {:invalid_arity, :if, "expected (if cond then else?)"}}
  end

  # ============================================================
  # if-not
  # ============================================================

  @doc """
  Analyzes an `if-not` form. Desugars by swapping then/else branches.
  """
  # Desugar (if-not test then else) -> (if test else then)
  def analyze_if_not([cond_ast, then_ast, else_ast], tail?, analyze_fn, _wrap_body_fn) do
    with {:ok, c} <- analyze_fn.(cond_ast, false),
         {:ok, t} <- analyze_fn.(then_ast, tail?),
         {:ok, e} <- analyze_fn.(else_ast, tail?) do
      {:ok, {:if, c, e, t}}
    end
  end

  # Desugar (if-not test then) -> (if test nil then)
  def analyze_if_not([cond_ast, then_ast], tail?, analyze_fn, _wrap_body_fn) do
    with {:ok, c} <- analyze_fn.(cond_ast, false),
         {:ok, t} <- analyze_fn.(then_ast, tail?) do
      {:ok, {:if, c, nil, t}}
    end
  end

  def analyze_if_not(_, _tail?, _analyze_fn, _wrap_body_fn) do
    {:error, {:invalid_arity, :"if-not", "expected (if-not cond then else?)"}}
  end

  # ============================================================
  # when
  # ============================================================

  @doc """
  Analyzes a `when` form. Desugars to `(if cond (do body...) nil)`.
  """
  def analyze_when([cond_ast, first_body | rest_body], tail?, analyze_fn, wrap_body_fn) do
    body_asts = [first_body | rest_body]

    with {:ok, c} <- analyze_fn.(cond_ast, false),
         {:ok, b} <- wrap_body_fn.(body_asts, tail?) do
      {:ok, {:if, c, b, nil}}
    end
  end

  def analyze_when(_, _tail?, _analyze_fn, _wrap_body_fn) do
    {:error, {:invalid_arity, :when, "expected (when cond body ...)"}}
  end

  # ============================================================
  # when-not
  # ============================================================

  @doc """
  Analyzes a `when-not` form. Desugars to `(if cond nil (do body...))`.
  """
  # Desugar (when-not cond body ...) -> (if cond nil (do body ...))
  def analyze_when_not([cond_ast, first_body | rest_body], tail?, analyze_fn, wrap_body_fn) do
    body_asts = [first_body | rest_body]

    with {:ok, c} <- analyze_fn.(cond_ast, false),
         {:ok, b} <- wrap_body_fn.(body_asts, tail?) do
      {:ok, {:if, c, nil, b}}
    end
  end

  def analyze_when_not(_, _tail?, _analyze_fn, _wrap_body_fn) do
    {:error, {:invalid_arity, :"when-not", "expected (when-not cond body ...)"}}
  end

  # ============================================================
  # if-let
  # ============================================================

  @doc """
  Analyzes an `if-let` form. Desugars to `(let [x cond] (if x then else))`.
  """
  # Desugar (if-let [x cond] then else) to (let [x cond] (if x then else))
  def analyze_if_let(
        [{:vector, [name_ast, cond_ast]}, then_ast, else_ast],
        tail?,
        analyze_fn,
        _wrap_body_fn
      ) do
    with {:ok, {:var, _} = name} <- analyze_simple_binding(name_ast),
         {:ok, c} <- analyze_fn.(cond_ast, false),
         {:ok, t} <- analyze_fn.(then_ast, tail?),
         {:ok, e} <- analyze_fn.(else_ast, tail?) do
      binding = {:binding, name, c}
      {:ok, {:let, [binding], {:if, name, t, e}}}
    end
  end

  def analyze_if_let(
        [{:vector, bindings}, _then_ast, _else_ast],
        _tail?,
        _analyze_fn,
        _wrap_body_fn
      )
      when length(bindings) != 2 do
    {:error, {:invalid_form, "if-let requires exactly one binding pair [name expr]"}}
  end

  def analyze_if_let(_, _tail?, _analyze_fn, _wrap_body_fn) do
    {:error, {:invalid_arity, :"if-let", "expected (if-let [name expr] then else)"}}
  end

  # ============================================================
  # when-let
  # ============================================================

  @doc """
  Analyzes a `when-let` form. Desugars to `(let [x cond] (if x body nil))`.
  """
  # Desugar (when-let [x cond] body ...) to (let [x cond] (if x body nil))
  def analyze_when_let(
        [{:vector, [name_ast, cond_ast]}, first_body | rest_body],
        tail?,
        analyze_fn,
        wrap_body_fn
      ) do
    body_asts = [first_body | rest_body]

    with {:ok, {:var, _} = name} <- analyze_simple_binding(name_ast),
         {:ok, c} <- analyze_fn.(cond_ast, false),
         {:ok, b} <- wrap_body_fn.(body_asts, tail?) do
      binding = {:binding, name, c}
      {:ok, {:let, [binding], {:if, name, b, nil}}}
    end
  end

  def analyze_when_let([{:vector, bindings} | _body_asts], _tail?, _analyze_fn, _wrap_body_fn)
      when length(bindings) != 2 do
    {:error, {:invalid_form, "when-let requires exactly one binding pair [name expr]"}}
  end

  def analyze_when_let(_, _tail?, _analyze_fn, _wrap_body_fn) do
    {:error, {:invalid_arity, :"when-let", "expected (when-let [name expr] body ...)"}}
  end

  # ============================================================
  # if-some
  # ============================================================

  @doc """
  Analyzes an `if-some` form. Desugars to `(let [x expr] (if (nil? x) else then))`.

  Unlike `if-let`, `if-some` only tests for nil — `false` binds successfully.
  """
  def analyze_if_some(
        [{:vector, [name_ast, cond_ast]}, then_ast, else_ast],
        tail?,
        analyze_fn,
        _wrap_body_fn,
        mark_shadow_fn
      ) do
    with {:ok, {:var, _} = name} <- analyze_simple_binding(name_ast),
         {:ok, c} <- analyze_fn.(cond_ast, false) do
      [then_ast, else_ast] = mark_shadow_fn.(name, [then_ast, else_ast])

      with {:ok, t} <- analyze_fn.(then_ast, tail?),
           {:ok, e} <- analyze_fn.(else_ast, tail?) do
        binding = {:binding, name, c}
        nil_check = {:call, {:var, :nil?}, [name]}
        {:ok, {:let, [binding], {:if, nil_check, e, t}}}
      end
    end
  end

  def analyze_if_some(
        [{:vector, [_name_ast, _cond_ast]}, _then_ast],
        _tail?,
        _analyze_fn,
        _wrap_body_fn,
        _mark_shadow_fn
      ) do
    {:error, {:invalid_arity, :"if-some", "expected (if-some [name expr] then else)"}}
  end

  def analyze_if_some(
        [{:vector, bindings}, _then_ast, _else_ast],
        _tail?,
        _analyze_fn,
        _wrap_body_fn,
        _mark_shadow_fn
      )
      when length(bindings) != 2 do
    {:error, {:invalid_form, "if-some requires exactly one binding pair [name expr]"}}
  end

  def analyze_if_some(_, _tail?, _analyze_fn, _wrap_body_fn, _mark_shadow_fn) do
    {:error, {:invalid_arity, :"if-some", "expected (if-some [name expr] then else)"}}
  end

  # ============================================================
  # when-some
  # ============================================================

  @doc """
  Analyzes a `when-some` form. Desugars to `(let [x expr] (if (nil? x) nil (do body...)))`.

  Unlike `when-let`, `when-some` only tests for nil — `false` binds successfully.
  """
  def analyze_when_some(
        [{:vector, [name_ast, cond_ast]}, first_body | rest_body],
        tail?,
        analyze_fn,
        wrap_body_fn,
        mark_shadow_fn
      ) do
    body_asts = [first_body | rest_body]

    with {:ok, {:var, _} = name} <- analyze_simple_binding(name_ast),
         {:ok, c} <- analyze_fn.(cond_ast, false) do
      body_asts = mark_shadow_fn.(name, body_asts)

      with {:ok, b} <- wrap_body_fn.(body_asts, tail?) do
        binding = {:binding, name, c}
        nil_check = {:call, {:var, :nil?}, [name]}
        {:ok, {:let, [binding], {:if, nil_check, nil, b}}}
      end
    end
  end

  def analyze_when_some(
        [{:vector, bindings} | _body_asts],
        _tail?,
        _analyze_fn,
        _wrap_body_fn,
        _mark_shadow_fn
      )
      when length(bindings) != 2 do
    {:error, {:invalid_form, "when-some requires exactly one binding pair [name expr]"}}
  end

  def analyze_when_some(_, _tail?, _analyze_fn, _wrap_body_fn, _mark_shadow_fn) do
    {:error, {:invalid_arity, :"when-some", "expected (when-some [name expr] body ...)"}}
  end

  # ============================================================
  # when-first
  # ============================================================

  @doc """
  Analyzes a `when-first` form.

  Desugars to:
      (let [__wf (seq coll)]
        (if (nil? __wf)
          nil
          (let [x (first __wf)]
            (do body...))))

  Binds `coll` once via `seq` to avoid double evaluation, then binds the
  first element if the sequence is non-empty.
  """
  def analyze_when_first(
        [{:vector, [name_ast, coll_ast]}, first_body | rest_body],
        tail?,
        analyze_fn,
        wrap_body_fn,
        mark_shadow_fn
      ) do
    body_asts = [first_body | rest_body]

    with {:ok, {:var, _} = name} <- analyze_simple_binding(name_ast),
         {:ok, coll} <- analyze_fn.(coll_ast, false) do
      body_asts = mark_shadow_fn.(name, body_asts)

      with {:ok, b} <- wrap_body_fn.(body_asts, tail?) do
        temp = {:var, :__wf}
        seq_call = {:call, {:var, :seq}, [coll]}
        first_call = {:call, {:var, :first}, [temp]}
        nil_check = {:call, {:var, :nil?}, [temp]}
        inner_let = {:let, [{:binding, name, first_call}], b}
        outer_let = {:let, [{:binding, temp, seq_call}], {:if, nil_check, nil, inner_let}}
        {:ok, outer_let}
      end
    end
  end

  def analyze_when_first(
        [{:vector, bindings} | _body_asts],
        _tail?,
        _analyze_fn,
        _wrap_body_fn,
        _mark_shadow_fn
      )
      when length(bindings) != 2 do
    {:error, {:invalid_form, "when-first requires exactly one binding pair [name expr]"}}
  end

  def analyze_when_first(_, _tail?, _analyze_fn, _wrap_body_fn, _mark_shadow_fn) do
    {:error, {:invalid_arity, :"when-first", "expected (when-first [name expr] body ...)"}}
  end

  # ============================================================
  # cond
  # ============================================================

  @doc """
  Analyzes a `cond` form. Desugars to nested `if` expressions.
  """
  def analyze_cond([], _tail?, _analyze_fn, _wrap_body_fn) do
    {:error, {:invalid_cond_form, "cond requires at least one test/result pair"}}
  end

  def analyze_cond(args, tail?, analyze_fn, _wrap_body_fn) do
    with {:ok, pairs, default} <- split_cond_args(args) do
      build_nested_if(pairs, default, tail?, analyze_fn)
    end
  end

  # ============================================================
  # case
  # ============================================================

  @doc """
  Analyzes a `case` form. Desugars to a let binding + nested `if` with equality checks.

  Test values must be compile-time constants (keywords, strings, numbers, booleans, nil).
  Grouped values `(:a :b)` match any value in the group.
  Returns nil if no match and no default.
  """
  def analyze_case([], _tail?, _analyze_fn, _wrap_body_fn) do
    {:error, {:invalid_form, "case requires at least an expression to test"}}
  end

  def analyze_case([expr_ast | clause_args], tail?, analyze_fn, _wrap_body_fn) do
    with {:ok, expr_core} <- analyze_fn.(expr_ast, false),
         {:ok, pairs, default_ast} <- split_case_clauses(clause_args) do
      temp = gensym("case")

      with {:ok, nested_if} <- build_case_if(pairs, default_ast, temp, tail?, analyze_fn) do
        {:ok, {:let, [{:binding, temp, expr_core}], nested_if}}
      end
    end
  end

  # ============================================================
  # condp
  # ============================================================

  @doc """
  Analyzes a `condp` form. Desugars to let bindings + nested `if` with predicate calls.

  Calls `(pred test-val expr)` for each clause. Both pred and expr are evaluated exactly once.
  Returns nil if no match and no default.
  The `:>>` form is not supported.
  """
  def analyze_condp(args, _tail?, _analyze_fn, _wrap_body_fn) when length(args) < 3 do
    {:error,
     {:invalid_form, "condp requires a predicate, an expression, and at least one clause"}}
  end

  def analyze_condp([pred_ast, expr_ast | clause_args], tail?, analyze_fn, _wrap_body_fn) do
    with {:ok, pred_core} <- analyze_fn.(pred_ast, false),
         {:ok, expr_core} <- analyze_fn.(expr_ast, false),
         {:ok, pairs, default_ast} <- split_condp_clauses(clause_args) do
      pred_temp = gensym("condp_pred")
      val_temp = gensym("condp_val")

      with {:ok, nested_if} <-
             build_condp_if(pairs, default_ast, pred_temp, val_temp, tail?, analyze_fn) do
        {:ok,
         {:let, [{:binding, pred_temp, pred_core}, {:binding, val_temp, expr_core}], nested_if}}
      end
    end
  end

  # ============================================================
  # Private helpers
  # ============================================================

  # Helper: only allow simple symbol bindings (no destructuring)
  defp analyze_simple_binding({:symbol, name}), do: {:ok, {:var, name}}

  defp analyze_simple_binding(_) do
    {:error, {:invalid_form, "binding must be a simple symbol, not a destructuring pattern"}}
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

  defp build_nested_if(pairs, default_ast, tail?, analyze_fn) do
    with {:ok, default_core} <- maybe_analyze(default_ast, tail?, analyze_fn) do
      pairs
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, default_core}, fn {c_ast, r_ast}, {:ok, acc} ->
        with {:ok, c} <- analyze_fn.(c_ast, false),
             {:ok, r} <- analyze_fn.(r_ast, tail?) do
          {:cont, {:ok, {:if, c, r, acc}}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp maybe_analyze(nil, _tail?, _analyze_fn), do: {:ok, nil}
  defp maybe_analyze(ast, tail?, analyze_fn), do: analyze_fn.(ast, tail?)

  # --- case helpers ---

  defp split_case_clauses(args) do
    len = length(args)

    cond do
      len == 0 ->
        {:ok, [], nil}

      rem(len, 2) == 1 ->
        # Odd count: last element is default
        {pairs_flat, [default]} = Enum.split(args, len - 1)

        with {:ok, pairs} <- validate_case_pairs(pairs_flat) do
          {:ok, pairs, default}
        end

      true ->
        with {:ok, pairs} <- validate_case_pairs(args) do
          {:ok, pairs, nil}
        end
    end
  end

  defp validate_case_pairs(args) do
    pairs = args |> Enum.chunk_every(2) |> Enum.map(fn [test, result] -> {test, result} end)

    Enum.reduce_while(pairs, {:ok, []}, fn {test, _result} = pair, {:ok, acc} ->
      case validate_case_test(test) do
        :ok -> {:cont, {:ok, acc ++ [pair]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_case_test({:keyword, _}), do: :ok
  defp validate_case_test({:string, _}), do: :ok
  defp validate_case_test(v) when is_integer(v), do: :ok
  defp validate_case_test(v) when is_float(v), do: :ok
  defp validate_case_test(true), do: :ok
  defp validate_case_test(false), do: :ok
  defp validate_case_test(nil), do: :ok

  defp validate_case_test({:list, []}) do
    {:error, {:invalid_form, "case grouped match must contain at least one value"}}
  end

  defp validate_case_test({:list, elements}) do
    Enum.reduce_while(elements, :ok, fn elem, :ok ->
      case validate_case_test_scalar(elem) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_case_test(_) do
    {:error,
     {:invalid_form,
      "case test values must be compile-time constants (keywords, strings, numbers, booleans, nil)"}}
  end

  # Scalar-only validation for elements inside grouped matches (no nested groups)
  defp validate_case_test_scalar({:keyword, _}), do: :ok
  defp validate_case_test_scalar({:string, _}), do: :ok
  defp validate_case_test_scalar(v) when is_integer(v), do: :ok
  defp validate_case_test_scalar(v) when is_float(v), do: :ok
  defp validate_case_test_scalar(true), do: :ok
  defp validate_case_test_scalar(false), do: :ok
  defp validate_case_test_scalar(nil), do: :ok

  defp validate_case_test_scalar(_) do
    {:error,
     {:invalid_form,
      "case test values must be compile-time constants (keywords, strings, numbers, booleans, nil)"}}
  end

  defp build_case_if(pairs, default_ast, temp, tail?, analyze_fn) do
    with {:ok, default_core} <- maybe_analyze(default_ast, tail?, analyze_fn) do
      pairs
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, default_core}, fn {test, result_ast}, {:ok, acc} ->
        with {:ok, condition} <- case_test_condition(test, temp, analyze_fn),
             {:ok, result} <- analyze_fn.(result_ast, tail?) do
          {:cont, {:ok, {:if, condition, result, acc}}}
        else
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp case_test_condition({:list, elements}, temp, analyze_fn) do
    # Grouped match: (val1 val2 ...) → {:or, [eq1, eq2, ...]}
    result =
      Enum.reduce_while(elements, {:ok, []}, fn elem, {:ok, acc} ->
        case analyze_fn.(elem, false) do
          {:ok, lit} -> {:cont, {:ok, acc ++ [{:call, {:var, :=}, [temp, lit]}]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, [single]} -> {:ok, single}
      {:ok, conditions} -> {:ok, {:or, conditions}}
      {:error, _} = err -> err
    end
  end

  defp case_test_condition(literal, temp, analyze_fn) do
    with {:ok, lit} <- analyze_fn.(literal, false) do
      {:ok, {:call, {:var, :=}, [temp, lit]}}
    end
  end

  # --- condp helpers ---

  defp split_condp_clauses([]) do
    {:error,
     {:invalid_form, "condp requires a predicate, an expression, and at least one clause"}}
  end

  defp split_condp_clauses(args) when rem(length(args), 2) == 1 do
    {pairs_flat, [default]} = Enum.split(args, length(args) - 1)

    if pairs_flat == [] do
      {:error, {:invalid_form, "condp requires at least one test/result clause pair"}}
    else
      with :ok <- check_condp_arrow(pairs_flat) do
        pairs = pairs_flat |> Enum.chunk_every(2) |> Enum.map(fn [t, r] -> {t, r} end)
        {:ok, pairs, default}
      end
    end
  end

  defp split_condp_clauses(args) do
    with :ok <- check_condp_arrow(args) do
      pairs = args |> Enum.chunk_every(2) |> Enum.map(fn [t, r] -> {t, r} end)
      {:ok, pairs, nil}
    end
  end

  # Structurally detect :>> in the result position of clause pairs (every other element starting at index 1)
  defp check_condp_arrow(pairs_flat) do
    pairs_flat
    |> Enum.chunk_every(2)
    |> Enum.reduce_while(:ok, fn
      [_test, result], :ok ->
        if arrow_keyword?(result) do
          {:halt,
           {:error, {:invalid_form, "condp :>> result-fn form is not supported in PTC-Lisp"}}}
        else
          {:cont, :ok}
        end

      [_default], :ok ->
        {:cont, :ok}
    end)
  end

  defp arrow_keyword?({:keyword, k}), do: to_string(k) == ">>"
  defp arrow_keyword?(_), do: false

  defp build_condp_if(pairs, default_ast, pred_temp, val_temp, tail?, analyze_fn) do
    with {:ok, default_core} <- maybe_analyze(default_ast, tail?, analyze_fn) do
      pairs
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, default_core}, fn {test_ast, result_ast}, {:ok, acc} ->
        with {:ok, test_core} <- analyze_fn.(test_ast, false),
             {:ok, result} <- analyze_fn.(result_ast, tail?) do
          condition = {:call, pred_temp, [test_core, val_temp]}
          {:cont, {:ok, {:if, condition, result, acc}}}
        else
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  # --- gensym ---

  defp gensym(prefix) do
    n = :erlang.unique_integer([:positive])
    {:var, :"__#{prefix}_#{n}"}
  end
end
