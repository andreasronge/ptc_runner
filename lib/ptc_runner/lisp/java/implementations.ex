defmodule PtcRunner.Lisp.Java.Implementations do
  @moduledoc false

  @handlers %{
    boolean_parse_boolean: {PtcRunner.Lisp.Java.Lang.Boolean, :parse_boolean}
  }

  @spec keys() :: %{atom() => true}
  def keys, do: Map.new(@handlers, fn {key, _handler} -> {key, true} end)

  @spec fetch(atom()) :: {:ok, {module(), atom()}} | :error
  def fetch(key), do: Map.fetch(@handlers, key)
end
