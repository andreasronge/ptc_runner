defmodule PtcRunner.Lisp.Eval.Where do
  @moduledoc """
  Where predicates and comparison helpers for Lisp evaluation.

  Handles building predicates for filtering operations and comparison logic.
  """

  import PtcRunner.Lisp.Runtime, only: [flex_get_in: 2]

  @doc """
  Builds a field accessor function from a field path AST node.
  """
  @spec build_field_accessor({:field, list()}) :: (map() -> term())
  def build_field_accessor({:field, segments}) do
    path =
      Enum.map(segments, fn
        {:keyword, k} -> k
        {:string, s} -> s
      end)

    fn row -> flex_get_in(row, path) end
  end

  @doc """
  Builds a predicate function for where expressions.
  """
  @spec build_where_predicate(atom(), (map() -> term()), term()) :: (map() -> boolean())
  def build_where_predicate(:truthy, accessor, _value),
    do: fn row -> truthy?(accessor.(row)) end

  def build_where_predicate(:eq, accessor, value),
    do: fn row -> safe_eq(accessor.(row), value) end

  def build_where_predicate(:not_eq, accessor, value),
    do: fn row -> not safe_eq(accessor.(row), value) end

  def build_where_predicate(:gt, accessor, value),
    do: fn row -> safe_cmp(accessor.(row), value, :>) end

  def build_where_predicate(:lt, accessor, value),
    do: fn row -> safe_cmp(accessor.(row), value, :<) end

  def build_where_predicate(:gte, accessor, value),
    do: fn row -> safe_cmp(accessor.(row), value, :>=) end

  def build_where_predicate(:lte, accessor, value),
    do: fn row -> safe_cmp(accessor.(row), value, :<=) end

  def build_where_predicate(:includes, accessor, value),
    do: fn row -> safe_includes(accessor.(row), value) end

  def build_where_predicate(:in, accessor, value),
    do: fn row -> safe_in(accessor.(row), value) end

  @doc """
  Builds a predicate combinator function (:all_of, :any_of, :none_of).
  """
  @spec build_pred_combinator(atom(), [(map() -> boolean())]) :: (map() -> boolean())
  def build_pred_combinator(:all_of, []), do: fn _row -> true end
  def build_pred_combinator(:any_of, []), do: fn _row -> false end
  def build_pred_combinator(:none_of, []), do: fn _row -> true end

  def build_pred_combinator(:all_of, fns),
    do: fn row -> Enum.all?(fns, & &1.(row)) end

  def build_pred_combinator(:any_of, fns),
    do: fn row -> Enum.any?(fns, & &1.(row)) end

  def build_pred_combinator(:none_of, fns),
    do: fn row -> not Enum.any?(fns, & &1.(row)) end

  @doc """
  Checks if a value is truthy (not nil or false).
  """
  @spec truthy?(term()) :: boolean()
  def truthy?(nil), do: false
  def truthy?(false), do: false
  def truthy?(_), do: true

  # Nil-safe comparison helpers
  defp safe_eq(nil, nil), do: true
  defp safe_eq(nil, _), do: false
  defp safe_eq(_, nil), do: false

  defp safe_eq(a, b) do
    a_normalized = normalize_for_comparison(a)
    b_normalized = normalize_for_comparison(b)
    a_normalized == b_normalized
  end

  defp safe_cmp(nil, _, _op), do: false
  defp safe_cmp(_, nil, _op), do: false
  defp safe_cmp(a, b, :>), do: a > b
  defp safe_cmp(a, b, :<), do: a < b
  defp safe_cmp(a, b, :>=), do: a >= b
  defp safe_cmp(a, b, :<=), do: a <= b

  # `in` operator: field value is member of collection
  defp safe_in(nil, _coll), do: false

  defp safe_in(value, coll) when is_list(coll) do
    normalized_value = normalize_for_comparison(value)

    Enum.any?(coll, fn item ->
      normalize_for_comparison(item) == normalized_value
    end)
  end

  defp safe_in(_, _), do: false

  # `includes` operator: collection includes value
  defp safe_includes(nil, _value), do: false

  defp safe_includes(coll, value) when is_list(coll) do
    normalized_value = normalize_for_comparison(value)

    Enum.any?(coll, fn item ->
      normalize_for_comparison(item) == normalized_value
    end)
  end

  defp safe_includes(coll, value) when is_binary(coll) and is_binary(value) do
    String.contains?(coll, value)
  end

  defp safe_includes(_, _), do: false

  # Coerce keywords to strings for comparison, but preserve other types
  # This allows LLM-generated keywords to match string data values
  defp normalize_for_comparison(value) when is_atom(value) and not is_boolean(value) do
    to_string(value)
  end

  defp normalize_for_comparison(value), do: value
end
