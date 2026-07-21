defmodule PtcRunner.Lisp.Java.Lang.Long do
  @moduledoc """
  Closed implementation of the admitted `java.lang.Long` surface.
  """

  alias PtcRunner.Lisp.Java.Lang.IntegralParser

  @spec parse_long([String.t() | nil]) ::
          {:ok, PtcRunner.Lisp.Java.Primitive.t()}
          | {:error, PtcRunner.Lisp.Java.Condition.t()}
  def parse_long(arguments), do: IntegralParser.parse(arguments, :long)
end
