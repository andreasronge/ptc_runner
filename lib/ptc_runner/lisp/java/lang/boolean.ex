defmodule PtcRunner.Lisp.Java.Lang.Boolean do
  @moduledoc """
  Closed implementation of the admitted `java.lang.Boolean` surface.
  """

  @spec parse_boolean([String.t() | nil]) :: {:ok, boolean()}
  def parse_boolean([nil]), do: {:ok, false}
  def parse_boolean([value]) when is_binary(value), do: {:ok, String.downcase(value) == "true"}
end
