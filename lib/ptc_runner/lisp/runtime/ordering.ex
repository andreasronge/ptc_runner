defmodule PtcRunner.Lisp.Runtime.Ordering do
  @moduledoc false

  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Eval.HostContext
  alias PtcRunner.Lisp.Java.Ordering, as: JavaOrdering
  alias PtcRunner.Lisp.Java.Primitive, as: JavaPrimitive
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Runtime.SpecialValues

  @type comparison :: :lt | :eq | :gt | :unordered

  @doc false
  @spec compare(term(), term()) :: -1 | 0 | 1
  def compare(left, right) do
    left = ordinary_value!(left)
    right = ordinary_value!(right)

    case JavaOrdering.compare(left, right) do
      {:ok, comparison} -> comparison_value(comparison)
      {:error, :invalid_java_value} -> invalid_java_ordering!()
      :not_java -> compare_clojure_values(left, right)
    end
  end

  @doc false
  @spec numeric_compare(term(), term()) :: comparison()
  def numeric_compare(left, right) do
    cond do
      SpecialValues.nan?(left) or SpecialValues.nan?(right) -> :unordered
      left == right -> :eq
      SpecialValues.neg_infinite?(left) -> :lt
      SpecialValues.neg_infinite?(right) -> :gt
      SpecialValues.pos_infinite?(left) -> :gt
      SpecialValues.pos_infinite?(right) -> :lt
      left < right -> :lt
      true -> :gt
    end
  end

  defp compare_clojure_values(nil, nil), do: 0
  defp compare_clojure_values(nil, _right), do: -1
  defp compare_clojure_values(_left, nil), do: 1

  defp compare_clojure_values(left, right) do
    cond do
      numeric?(left) and numeric?(right) ->
        left |> numeric_compare(right) |> ordered_comparison!("compare", left, right)

      is_binary(left) and is_binary(right) ->
        compare_strings(left, right)

      LispKeyword.keyword?(left) and LispKeyword.keyword?(right) ->
        compare_strings(LispKeyword.name(left), LispKeyword.name(right))

      is_boolean(left) and is_boolean(right) ->
        compare_booleans(left, right)

      is_list(left) and is_list(right) ->
        compare_vectors(left, right, &compare/2)

      true ->
        type_error!("compare", left, right)
    end
  end

  defp compare_vectors(left, right, comparator) do
    case compare_terms(length(left), length(right)) do
      0 -> compare_sequences(left, right, comparator)
      result -> result
    end
  end

  defp compare_sequences([], [], _comparator), do: 0
  defp compare_sequences([], [_ | _], _comparator), do: -1
  defp compare_sequences([_ | _], [], _comparator), do: 1

  defp compare_sequences([left | left_rest], [right | right_rest], comparator) do
    case comparator.(left, right) do
      0 -> compare_sequences(left_rest, right_rest, comparator)
      result -> result
    end
  end

  defp compare_strings(left, right) do
    compare_terms(utf16_view!(left), utf16_view!(right))
  end

  defp utf16_view!(value) do
    case :unicode.characters_to_binary(value, :utf8, {:utf16, :big}) do
      binary when is_binary(binary) -> binary
      _invalid -> HostContext.error!({:type_error, "compare: invalid UTF-8 string", [value]})
    end
  end

  defp ordinary_value!(%JavaPrimitive{} = primitive) do
    case JavaPrimitive.unwrap(primitive) do
      {:ok, value} -> value
      {:error, :invalid_java_value} -> invalid_java_ordering!()
    end
  end

  defp ordinary_value!(value), do: value

  defp compare_booleans(false, true), do: -1
  defp compare_booleans(true, false), do: 1
  defp compare_booleans(_left, _right), do: 0

  defp compare_terms(left, right) when left < right, do: -1
  defp compare_terms(left, right) when left > right, do: 1
  defp compare_terms(_left, _right), do: 0

  defp ordered_comparison!(:unordered, name, left, right) do
    raise "type_error: #{name}: unordered comparison with NaN: " <>
            Enum.join([Helpers.describe_type(left), Helpers.describe_type(right)], ", ")
  end

  defp ordered_comparison!(comparison, _name, _left, _right),
    do: comparison_value(comparison)

  defp comparison_value(:lt), do: -1
  defp comparison_value(:eq), do: 0
  defp comparison_value(:gt), do: 1

  defp numeric?(value), do: is_number(value) or SpecialValues.special?(value)

  @spec type_error!(String.t(), term(), term()) :: no_return()
  defp type_error!(name, left, right) do
    message =
      "#{name}: values are not comparable: #{Helpers.describe_type(left)}, " <>
        Helpers.describe_type(right)

    HostContext.error!({:type_error, message, [left, right]})
  end

  @spec invalid_java_ordering!() :: no_return()
  defp invalid_java_ordering!,
    do: HostContext.error!({:invalid_java_value, :java_object})
end
