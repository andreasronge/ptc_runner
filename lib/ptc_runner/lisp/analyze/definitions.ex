defmodule PtcRunner.Lisp.Analyze.Definitions do
  @moduledoc """
  Definition analysis for `def`, `defonce`, and `defn` forms.

  Transforms definition forms into CoreAST using callback functions for
  analyzing values, wrapping bodies, and analyzing function parameters.
  """

  @doc """
  Analyzes a `def` form.

  Takes `args` and `analyze_fn(ast) -> {:ok, core} | {:error, reason}`.
  """
  def analyze_def(args, analyze_fn), do: analyze_binding_form(:def, args, analyze_fn)

  @doc """
  Analyzes a `defonce` form.

  Takes `args` and `analyze_fn(ast) -> {:ok, core} | {:error, reason}`.
  """
  def analyze_defonce(args, analyze_fn), do: analyze_binding_form(:defonce, args, analyze_fn)

  @doc """
  Analyzes a `defn` form (desugars to def + fn).

  Takes `args`, `analyze_fn_params_fn(ast)`, and `wrap_body_fn(asts, tail?)`.
  """
  # (defn name docstring [params] body ...) - with docstring
  def analyze_defn(
        [
          {:symbol, name},
          {:string, docstring},
          {:vector, _} = params_ast,
          first_body | rest_body
        ],
        analyze_fn_params_fn,
        wrap_body_fn
      ) do
    body_asts = [first_body | rest_body]

    with {:ok, params} <- analyze_fn_params_fn.(params_ast),
         {:ok, body} <- wrap_body_fn.(body_asts, true) do
      {:ok, {:def, name, {:fn, params, body}, %{docstring: docstring}}}
    end
  end

  # (defn name [params] body ...) - without docstring
  def analyze_defn(
        [{:symbol, name}, {:vector, _} = params_ast, first_body | rest_body],
        analyze_fn_params_fn,
        wrap_body_fn
      ) do
    body_asts = [first_body | rest_body]

    with {:ok, params} <- analyze_fn_params_fn.(params_ast),
         {:ok, body} <- wrap_body_fn.(body_asts, true) do
      {:ok, {:def, name, {:fn, params, body}, %{}}}
    end
  end

  # Error: (defn name [params]) - missing body
  def analyze_defn([{:symbol, _name}, {:vector, _params}], _analyze_fn_params_fn, _wrap_body_fn) do
    {:error, {:invalid_arity, :defn, "expected (defn name [params] body), missing body"}}
  end

  # Error: (defn name) - missing params and body
  def analyze_defn([{:symbol, _name}], _analyze_fn_params_fn, _wrap_body_fn) do
    {:error, {:invalid_arity, :defn, "expected (defn name [params] body)"}}
  end

  # Error: multi-arity syntax (defn f ([x] ...) ([x y] ...))
  def analyze_defn([{:symbol, _name}, {:list, _} | _], _analyze_fn_params_fn, _wrap_body_fn) do
    {:error,
     {:invalid_form, "multi-arity defn not supported, use separate defn forms for each arity"}}
  end

  # Error: non-symbol name
  def analyze_defn([non_symbol | _], _analyze_fn_params_fn, _wrap_body_fn) do
    {:error, {:invalid_form, "defn name must be a symbol, got: #{inspect(non_symbol)}"}}
  end

  def analyze_defn(_, _analyze_fn_params_fn, _wrap_body_fn) do
    {:error, {:invalid_arity, :defn, "expected (defn name [params] body)"}}
  end

  # ============================================================
  # Shared def/defonce logic
  # ============================================================

  # (form name value)
  defp analyze_binding_form(tag, [{:symbol, name}, value_ast], analyze_fn) do
    with {:ok, value} <- analyze_fn.(value_ast) do
      {:ok, {tag, name, value, %{}}}
    end
  end

  # (form name docstring value)
  defp analyze_binding_form(tag, [{:symbol, name}, {:string, docstring}, value_ast], analyze_fn) do
    with {:ok, value} <- analyze_fn.(value_ast) do
      {:ok, {tag, name, value, %{docstring: docstring}}}
    end
  end

  defp analyze_binding_form(tag, [{:symbol, _name}], _analyze_fn) do
    {:error,
     {:invalid_arity, tag, "expected (#{tag} name value), got (#{tag} name) without value"}}
  end

  defp analyze_binding_form(tag, [{:symbol, _name} | _], _analyze_fn) do
    {:error,
     {:invalid_arity, tag, "expected (#{tag} name value) or (#{tag} name docstring value)"}}
  end

  defp analyze_binding_form(tag, [non_symbol | _], _analyze_fn) do
    {:error, {:invalid_form, "#{tag} name must be a symbol, got: #{inspect(non_symbol)}"}}
  end

  defp analyze_binding_form(tag, _, _analyze_fn) do
    {:error,
     {:invalid_arity, tag, "expected (#{tag} name value) or (#{tag} name docstring value)"}}
  end
end
