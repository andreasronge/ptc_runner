defmodule PtcRunner.Lisp.Analyze.Conditionals do
  @moduledoc """
  Conditional analysis for `if`, `if-not`, `when`, `when-not`, `if-let`,
  `when-let`, and `cond` forms.

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
end
