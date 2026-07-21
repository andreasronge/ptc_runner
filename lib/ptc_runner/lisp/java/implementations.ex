defmodule PtcRunner.Lisp.Java.Implementations do
  @moduledoc false

  @handlers %{
    boolean_parse_boolean: {PtcRunner.Lisp.Java.Lang.Boolean, :parse_boolean},
    double_nan: {PtcRunner.Lisp.Java.Lang.Double, :nan},
    double_negative_infinity: {PtcRunner.Lisp.Java.Lang.Double, :negative_infinity},
    double_parse_double: {PtcRunner.Lisp.Java.Lang.Double, :parse_double},
    double_positive_infinity: {PtcRunner.Lisp.Java.Lang.Double, :positive_infinity},
    float_parse_float: {PtcRunner.Lisp.Java.Lang.Float, :parse_float},
    integer_parse_int: {PtcRunner.Lisp.Java.Lang.Integer, :parse_int},
    long_parse_long: {PtcRunner.Lisp.Java.Lang.Long, :parse_long}
  }

  @spec keys() :: %{atom() => true}
  def keys, do: Map.new(@handlers, fn {key, _handler} -> {key, true} end)

  @spec fetch(atom()) :: {:ok, {module(), atom()}} | :error
  def fetch(key), do: Map.fetch(@handlers, key)
end
