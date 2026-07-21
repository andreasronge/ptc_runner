defmodule PtcRunner.Lisp.Java.Primitive do
  @moduledoc """
  Native Java numeric value whose primitive overload identity is observable.

  Ordinary PTC arithmetic intentionally unwraps this payload and therefore
  ends its Java provenance. Java dispatch validates the tag and range before
  using it for overload selection.
  """

  import Bitwise

  @enforce_keys [:kind, :value]
  defstruct [:kind, :value]

  @type kind :: :int | :long | :float | :double
  @type t :: %__MODULE__{kind: kind(), value: integer() | float() | atom()}

  @int_min -2_147_483_648
  @int_max 2_147_483_647
  @long_min -9_223_372_036_854_775_808
  @long_max 9_223_372_036_854_775_807
  @special_values [:infinity, :negative_infinity, :nan]

  @all_argument_numeric_consumers [
    :+,
    :-,
    :*,
    :/,
    :mod,
    :rem,
    :quot,
    :inc,
    :dec,
    :"+'",
    :"-'",
    :"*'",
    :"inc'",
    :"dec'",
    :abs,
    :max,
    :min,
    :floor,
    :ceil,
    :round,
    :trunc,
    :double,
    :float,
    :int,
    :sqrt,
    :pow,
    :"bit-and",
    :"bit-or",
    :"bit-xor",
    :"bit-and-not",
    :"bit-not",
    :"bit-shift-left",
    :"bit-shift-right",
    :"bit-clear",
    :"bit-set",
    :"bit-flip",
    :"bit-test",
    :=,
    :==,
    :"not=",
    :>,
    :<,
    :>=,
    :<=,
    :compare,
    :number?,
    :int?,
    :integer?,
    :float?,
    :double?,
    :rational?,
    :"nat-int?",
    :"neg-int?",
    :"pos-int?",
    :infinite?,
    :NaN?,
    :zero?,
    :pos?,
    :neg?,
    :even?,
    :odd?
  ]

  @positional_numeric_consumers %{
    {:nth, 2} => [1],
    {:nth, 3} => [1],
    {:take, 2} => [0],
    {:drop, 2} => [0],
    {:nthrest, 2} => [1],
    {:nthnext, 2} => [1],
    {:"take-last", 2} => [0],
    {:"drop-last", 2} => [0],
    {:partition, 2} => [0],
    {:partition, 3} => [0, 1],
    {:partition, 4} => [0, 1],
    {:"partition-all", 2} => [0],
    {:"partition-all", 3} => [0, 1],
    {:"split-at", 2} => [0],
    {:subvec, 2} => [1],
    {:subvec, 3} => [1, 2],
    {:range, 1} => :all,
    {:range, 2} => :all,
    {:range, 3} => :all,
    {:combinations, 2} => [1],
    {:subs, 2} => [1],
    {:subs, 3} => [1, 2],
    {:"index-of", 3} => [2],
    {:"last-index-of", 3} => [2],
    {:extract, 3} => [2],
    {:"extract-int", 3} => [2],
    {:"extract-int", 4} => [2],
    {:"java.util.Date.", 1} => [0],
    {:".plusDays", 2} => [1],
    {:".minusDays", 2} => [1],
    {:".indexOf", 3} => [2],
    {:".substring", 2} => [1],
    {:".substring", 3} => [1, 2]
  }

  @spec new(kind(), term()) :: {:ok, t()} | {:error, :invalid_java_value}
  def new(:int, value) when is_integer(value) and value >= @int_min and value <= @int_max,
    do: {:ok, %__MODULE__{kind: :int, value: value}}

  def new(:long, value) when is_integer(value) and value >= @long_min and value <= @long_max,
    do: {:ok, %__MODULE__{kind: :long, value: value}}

  def new(:float, value) when is_float(value),
    do: {:ok, %__MODULE__{kind: :float, value: round_float32(value)}}

  def new(:float, value) when value in @special_values,
    do: {:ok, %__MODULE__{kind: :float, value: value}}

  def new(:double, value) when is_float(value) or value in @special_values,
    do: {:ok, %__MODULE__{kind: :double, value: value}}

  def new(_kind, _value), do: {:error, :invalid_java_value}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{kind: kind, value: value} = primitive) do
    if exact_shape?(primitive) do
      case new(kind, value) do
        {:ok, canonical} -> same_primitive?(primitive, canonical)
        {:error, :invalid_java_value} -> false
      end
    else
      false
    end
  end

  def valid?(_), do: false

  @doc "Returns whether a raw value is representable by the Java primitive kind."
  @spec in_range?(kind(), term()) :: boolean()
  def in_range?(kind, value), do: match?({:ok, _primitive}, new(kind, value))

  @doc "Validates and unwraps only the numeric argument positions consumed by a PTC builtin."
  @spec prepare_arguments(atom(), [term()]) ::
          {:ok, [term()]} | {:error, :invalid_java_value}
  def prepare_arguments(name, arguments) do
    positions =
      if name in @all_argument_numeric_consumers,
        do: :all,
        else: Map.get(@positional_numeric_consumers, {name, length(arguments)}, [])

    arguments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      if positions == :all or index in positions do
        case ordinary_numeric_value(value) do
          {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
          {:error, :invalid_java_value} = error -> {:halt, error}
        end
      else
        {:cont, {:ok, [value | acc]}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, :invalid_java_value} = error -> error
    end
  end

  @doc "Validates and unwraps one Java primitive while leaving ordinary values unchanged."
  @spec ordinary_numeric_value(term()) :: {:ok, term()} | {:error, :invalid_java_value}
  def ordinary_numeric_value(%__MODULE__{} = primitive), do: unwrap(primitive)
  def ordinary_numeric_value(value), do: {:ok, value}

  @spec unwrap(t()) :: {:ok, integer() | float() | atom()} | {:error, :invalid_java_value}
  def unwrap(%__MODULE__{kind: kind, value: value} = primitive) do
    if exact_shape?(primitive), do: unwrap_exact(kind, value), else: {:error, :invalid_java_value}
  end

  def unwrap(%{__struct__: __MODULE__}), do: {:error, :invalid_java_value}

  defp unwrap_exact(kind, value) do
    case new(kind, value) do
      {:ok, canonical} ->
        if same_primitive?(%__MODULE__{kind: kind, value: value}, canonical),
          do: {:ok, value},
          else: {:error, :invalid_java_value}

      {:error, :invalid_java_value} = error ->
        error
    end
  end

  defp exact_shape?(primitive), do: map_size(primitive) == 3

  defp round_float32(value) do
    binary = <<value::float-32>>
    <<bits::unsigned-32>> = binary
    sign = bits >>> 31
    exponent = bits >>> 23 &&& 0xFF
    fraction = bits &&& 0x7FFFFF

    cond do
      exponent == 0xFF and fraction != 0 ->
        :nan

      exponent == 0xFF and sign == 1 ->
        :negative_infinity

      exponent == 0xFF ->
        :infinity

      true ->
        <<rounded::float-32>> = binary
        rounded
    end
  end

  defp same_primitive?(%__MODULE__{kind: kind, value: left}, %__MODULE__{kind: kind, value: right})
       when is_float(left) and is_float(right),
       do: <<left::float-64>> == <<right::float-64>>

  defp same_primitive?(%__MODULE__{} = left, %__MODULE__{} = right), do: left === right
end
