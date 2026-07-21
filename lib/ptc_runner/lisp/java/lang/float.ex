defmodule PtcRunner.Lisp.Java.Lang.Float do
  @moduledoc """
  Closed implementation of the admitted `java.lang.Float` surface.
  """

  alias PtcRunner.Lisp.Java.Lang.FloatingParser

  @spec parse_float([String.t() | nil]) ::
          {:ok, PtcRunner.Lisp.Java.Primitive.t()}
          | {:error, PtcRunner.Lisp.Java.Condition.t()}
  def parse_float(arguments), do: FloatingParser.parse(arguments, :float)
end
