defmodule PtcRunner.Lisp.Java.Lang.Integer do
  @moduledoc """
  Closed implementation of the admitted `java.lang.Integer` surface.
  """

  alias PtcRunner.Lisp.Java.Lang.IntegralParser

  @spec parse_int([String.t() | nil]) ::
          {:ok, PtcRunner.Lisp.Java.Primitive.t()}
          | {:error, PtcRunner.Lisp.Java.Condition.t()}
  def parse_int(arguments), do: IntegralParser.parse(arguments, :int)
end
