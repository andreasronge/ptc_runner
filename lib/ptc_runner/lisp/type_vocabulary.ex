defmodule PtcRunner.Lisp.TypeVocabulary do
  @moduledoc "Converts Elixir values to human-readable type labels."

  alias PtcRunner.Lisp.Env.Builtin
  alias PtcRunner.Lisp.Java.Callable, as: JavaCallable
  alias PtcRunner.Lisp.Java.Primitive, as: JavaPrimitive
  alias PtcRunner.Lisp.Java.Time.Duration, as: JavaDuration
  alias PtcRunner.Lisp.Java.Time.Instant, as: JavaInstant
  alias PtcRunner.Lisp.Java.Time.LocalDate, as: JavaLocalDate
  alias PtcRunner.Lisp.Java.Util.Date, as: JavaDate
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.RuntimeCallable
  alias PtcRunner.Lisp.SpecialBuiltin

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
  def type_of(value) do
    case semantic_type(value) do
      "list" -> "list[#{length(value)}]"
      "map" -> "map[#{map_size(value)}]"
      "set" -> "set[#{MapSet.size(value)}]"
      "function" -> if(match?({:closure, _, _, _, _, _}, value), do: "#fn[...]", else: "fn")
      type -> type
    end
  end

  @doc "Returns a traversal-free semantic type label suitable for bounded summaries."
  @spec semantic_type(term()) :: String.t()
  def semantic_type(nil), do: "nil"
  def semantic_type(value) when is_boolean(value), do: "boolean"
  def semantic_type(:nan), do: "nan"
  def semantic_type(:infinity), do: "infinity"
  def semantic_type(:negative_infinity), do: "infinity"
  def semantic_type(value) when is_integer(value), do: "integer"
  def semantic_type(value) when is_float(value), do: "float"
  def semantic_type(value) when is_binary(value), do: "string"
  def semantic_type(%LispKeyword{}), do: "keyword"
  def semantic_type(value) when is_list(value), do: "list"
  def semantic_type(%MapSet{}), do: "set"
  def semantic_type(%DateTime{}), do: "datetime"
  def semantic_type(%NaiveDateTime{}), do: "datetime"
  def semantic_type(%Date{}), do: "date"
  def semantic_type(%Time{}), do: "time"

  def semantic_type(%JavaCallable{} = callable),
    do: if(JavaCallable.valid?(callable), do: "function", else: "invalid-java-value")

  def semantic_type(%JavaPrimitive{kind: kind} = primitive) do
    cond do
      not JavaPrimitive.valid?(primitive) -> "invalid-java-value"
      kind in [:int, :long] -> "integer"
      true -> "float"
    end
  end

  def semantic_type(%JavaLocalDate{} = value),
    do: java_object_type(JavaLocalDate, value, "java.time.LocalDate")

  def semantic_type(%JavaInstant{} = value),
    do: java_object_type(JavaInstant, value, "java.time.Instant")

  def semantic_type(%JavaDuration{} = value),
    do: java_object_type(JavaDuration, value, "java.time.Duration")

  def semantic_type(%JavaDate{} = value),
    do: java_object_type(JavaDate, value, "java.util.Date")

  def semantic_type(value) when is_map(value) and not is_struct(value), do: "map"
  def semantic_type(value) when is_function(value), do: "function"
  def semantic_type(value) when is_atom(value), do: "keyword"
  def semantic_type(value), do: if(callable?(value), do: "function", else: "unknown")

  @doc "Returns whether a runtime value is one of PTC-Lisp's callable representations."
  @spec callable?(term()) :: boolean()
  def callable?(%Builtin{}), do: true
  def callable?(%RuntimeCallable{}), do: true
  def callable?(%JavaCallable{} = callable), do: JavaCallable.valid?(callable)
  def callable?(value) when is_function(value), do: true
  def callable?({:closure, _, _, _, _, _}), do: true
  def callable?({:normal, function}), do: is_function(function)
  def callable?({:variadic, function, _identity}), do: is_function(function)

  def callable?({:variadic_nonempty, name, function}),
    do: is_atom(name) and is_function(function)

  def callable?({:multi_arity, name, functions}),
    do: is_atom(name) and is_tuple(functions)

  def callable?({:special, name}), do: SpecialBuiltin.callable?(name)
  def callable?({:collect, function}), do: is_function(function)
  def callable?({:juxt_fn, functions}), do: is_list(functions)

  def callable?({tag, _value}) when tag in [:complement_fn, :constantly_fn], do: true

  def callable?({tag, functions}) when tag in [:comp_fn, :every_pred_fn, :some_fn],
    do: is_list(functions)

  def callable?({:partial_fn, _function, fixed}), do: is_list(fixed)
  def callable?({:fnil_fn, _function, _default}), do: true
  def callable?(_value), do: false

  defp java_object_type(module, value, label) do
    if module.valid?(value), do: label, else: "invalid-java-value"
  end
end
