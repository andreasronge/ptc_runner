defmodule PtcRunner.Lisp.Java.Lang.System do
  @moduledoc """
  Closed implementation of the admitted `java.lang.System` surface.
  """

  alias PtcRunner.Lisp.Java.Primitive

  @doc "Returns the current Unix time as a Java `long`."
  @spec current_time_millis([]) :: {:ok, Primitive.t()}
  def current_time_millis([]) do
    Primitive.new(:long, Elixir.System.system_time(:millisecond))
  end
end
