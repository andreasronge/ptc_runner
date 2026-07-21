defmodule PtcRunner.Lisp.TypeVocabulary do
  @moduledoc "Converts Elixir values to human-readable type labels."

  alias PtcRunner.Lisp.Java.Callable, as: JavaCallable
  alias PtcRunner.Lisp.Java.Primitive, as: JavaPrimitive
  alias PtcRunner.Lisp.Java.Time.Duration, as: JavaDuration
  alias PtcRunner.Lisp.Java.Time.Instant, as: JavaInstant
  alias PtcRunner.Lisp.Java.Time.LocalDate, as: JavaLocalDate
  alias PtcRunner.Lisp.Java.Util.Date, as: JavaDate
  alias PtcRunner.Lisp.Keyword, as: LispKeyword

  @doc """
  Returns a type label for any value.

  ## Examples

      iex> PtcRunner.Lisp.TypeVocabulary.type_of([])
      "list[0]"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of([1, 2, 3])
      "list[3]"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of(%{})
      "map[0]"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of(%{a: 1})
      "map[1]"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of(MapSet.new([1, 2]))
      "set[2]"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of(~U[2026-05-03 09:14:00Z])
      "datetime"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of(~D[2026-05-03])
      "date"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of({:closure, [], nil, %{}, [], %{}})
      "#fn[...]"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of("hello")
      "string"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of(42)
      "integer"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of(3.14)
      "float"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of(true)
      "boolean"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of(false)
      "boolean"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of(:foo)
      "keyword"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of(nil)
      "nil"

      iex> PtcRunner.Lisp.TypeVocabulary.type_of(fn -> :ok end)
      "fn"
  """
  @spec type_of(term()) :: String.t()
  def type_of([]), do: "list[0]"
  def type_of(list) when is_list(list), do: "list[#{length(list)}]"
  def type_of(%MapSet{} = set), do: "set[#{MapSet.size(set)}]"
  # Temporal structs are scalars semantically, even though they're maps in
  # Elixir's runtime. These clauses must precede the generic `is_map` match
  # below — the LLM-facing data inventory should say "datetime", not "map[7]".
  def type_of(%DateTime{}), do: "datetime"
  def type_of(%NaiveDateTime{}), do: "datetime"
  def type_of(%Date{}), do: "date"
  def type_of(%Time{}), do: "time"
  def type_of(%LispKeyword{}), do: "keyword"

  def type_of(%JavaCallable{} = callable),
    do: if(JavaCallable.valid?(callable), do: "fn", else: "invalid-java-value")

  def type_of(%JavaPrimitive{kind: kind} = primitive) do
    cond do
      not JavaPrimitive.valid?(primitive) -> "invalid-java-value"
      kind in [:int, :long] -> "integer"
      true -> "float"
    end
  end

  def type_of(%JavaLocalDate{} = value),
    do: java_object_type(JavaLocalDate, value, "java.time.LocalDate")

  def type_of(%JavaInstant{} = value),
    do: java_object_type(JavaInstant, value, "java.time.Instant")

  def type_of(%JavaDuration{} = value),
    do: java_object_type(JavaDuration, value, "java.time.Duration")

  def type_of(%JavaDate{} = value), do: java_object_type(JavaDate, value, "java.util.Date")

  def type_of(map) when is_map(map) and not is_struct(map), do: "map[#{map_size(map)}]"
  def type_of(s) when is_binary(s), do: "string"
  def type_of(n) when is_integer(n), do: "integer"
  def type_of(f) when is_float(f), do: "float"
  def type_of(true), do: "boolean"
  def type_of(false), do: "boolean"
  def type_of(nil), do: "nil"
  def type_of(a) when is_atom(a), do: "keyword"
  def type_of({:closure, _, _, _, _, _}), do: "#fn[...]"
  def type_of({:juxt_fn, fns}) when is_list(fns), do: "fn"
  def type_of({tag, _}) when tag in [:complement_fn, :constantly_fn], do: "fn"

  def type_of({tag, fns}) when tag in [:comp_fn, :every_pred_fn, :some_fn] and is_list(fns),
    do: "fn"

  def type_of({:partial_fn, _f, fixed}) when is_list(fixed), do: "fn"
  def type_of({:fnil_fn, _f, _default}), do: "fn"
  def type_of(f) when is_function(f), do: "fn"
  def type_of(_), do: "unknown"

  defp java_object_type(module, value, label) do
    if module.valid?(value), do: label, else: "invalid-java-value"
  end
end
