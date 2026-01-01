defmodule PtcRunner.Lisp.Analyze.Predicates do
  @moduledoc """
  Predicate analysis for `where` clauses and predicate combinators.

  Transforms predicate expressions (where, all-of, any-of, none-of) from
  RawAST into CoreAST representations used for filtering collections.
  """

  @doc """
  Analyzes a `where` expression.

  Takes the arguments to a where form and an analyzer function for nested values.

  ## Forms

  - `(where field)` - truthy check on field
  - `(where field op value)` - comparison using op

  """
  @spec analyze_where(list(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def analyze_where(args, analyze_fn) do
    case args do
      [field_ast] ->
        with {:ok, field_path} <- analyze_field_path(field_ast) do
          {:ok, {:where, field_path, :truthy, nil}}
        end

      [field_ast, {:symbol, op}, value_ast] ->
        with {:ok, field_path} <- analyze_field_path(field_ast),
             {:ok, op_tag} <- classify_where_op(op),
             {:ok, value} <- analyze_fn.(value_ast) do
          {:ok, {:where, field_path, op_tag, value}}
        end

      _ ->
        {:error, {:invalid_where_form, "expected (where field) or (where field op value)"}}
    end
  end

  @doc """
  Analyzes a predicate combinator (all-of, any-of, none-of).

  Takes the combinator kind, arguments, and an analyzer function for the predicates.
  """
  @spec analyze_pred_comb(atom(), list(), (list() -> {:ok, list()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def analyze_pred_comb(kind, args, analyze_list_fn) do
    with {:ok, preds} <- analyze_list_fn.(args) do
      {:ok, {:pred_combinator, kind, preds}}
    end
  end

  # ============================================================
  # Field path analysis
  # ============================================================

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

  # ============================================================
  # Where operator classification
  # ============================================================

  defp classify_where_op(:=), do: {:ok, :eq}
  defp classify_where_op(:"not="), do: {:ok, :not_eq}
  defp classify_where_op(:>), do: {:ok, :gt}
  defp classify_where_op(:<), do: {:ok, :lt}
  defp classify_where_op(:>=), do: {:ok, :gte}
  defp classify_where_op(:<=), do: {:ok, :lte}
  defp classify_where_op(:includes), do: {:ok, :includes}
  defp classify_where_op(:in), do: {:ok, :in}
  defp classify_where_op(op), do: {:error, {:invalid_where_operator, op}}
end
