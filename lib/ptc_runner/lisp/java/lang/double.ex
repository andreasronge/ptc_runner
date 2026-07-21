defmodule PtcRunner.Lisp.Java.Lang.Double do
  @moduledoc """
  Closed implementation of the admitted `java.lang.Double` surface.
  """

  alias PtcRunner.Lisp.Java.Lang.FloatingParser

  @spec parse_double([String.t() | nil]) ::
          {:ok, PtcRunner.Lisp.Java.Primitive.t()}
          | {:error, PtcRunner.Lisp.Java.Condition.t()}
  def parse_double(arguments), do: FloatingParser.parse(arguments, :double)

  @spec positive_infinity([]) :: {:ok, PtcRunner.Lisp.Java.Primitive.t()}
  def positive_infinity([]), do: FloatingParser.constant(:infinity)

  @spec negative_infinity([]) :: {:ok, PtcRunner.Lisp.Java.Primitive.t()}
  def negative_infinity([]), do: FloatingParser.constant(:negative_infinity)

  @spec nan([]) :: {:ok, PtcRunner.Lisp.Java.Primitive.t()}
  def nan([]), do: FloatingParser.constant(:nan)
end
