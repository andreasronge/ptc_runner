defmodule PtcRunner.Kernel.JSONValue do
  @moduledoc false

  def map?(value), do: is_map(value) and not is_struct(value) and value?(value)

  def value?(nil), do: true
  def value?(value) when is_boolean(value) or is_integer(value), do: true
  def value?(value) when is_float(value), do: value == value
  def value?(value) when is_binary(value), do: String.valid?(value)
  def value?(value) when is_list(value), do: Enum.all?(value, &value?/1)

  def value?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and String.valid?(key) and value?(item)
      end)

  def value?(_value), do: false
end
