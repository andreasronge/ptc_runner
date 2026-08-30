defmodule PtcRunner.Kernel.JSONValue do
  @moduledoc """
  Internal validator for values that may cross JSON-shaped Kernel boundaries.

  Accepted values are nil, booleans, finite numbers, valid UTF-8 binaries,
  lists, and non-struct maps with unique binary keys.
  """

  @doc "Returns whether a value is a JSON-like map."
  def map?(value), do: is_map(value) and not is_struct(value) and value?(value)

  @doc "Returns whether a value is recursively JSON-like."
  def value?(nil), do: true
  def value?(value) when is_boolean(value) or is_integer(value), do: true
  def value?(value) when is_float(value), do: value == value
  def value?(value) when is_binary(value), do: String.valid?(value)
  def value?(value) when is_list(value), do: list_value?(value)

  def value?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and String.valid?(key) and value?(item)
      end)

  def value?(_value), do: false

  defp list_value?([]), do: true
  defp list_value?([item | rest]), do: value?(item) and list_value?(rest)
  defp list_value?(_improper_tail), do: false

  @doc "Normalizes atom keys and values into a JSON-like value."
  @spec normalize(term()) :: {:ok, term()} | :error
  def normalize(nil), do: {:ok, nil}
  def normalize(value) when is_boolean(value) or is_number(value), do: {:ok, value}
  def normalize(value) when is_binary(value), do: {:ok, value}
  def normalize(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  def normalize(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, normalized} ->
      case normalize(item) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      :error -> :error
    end
  end

  def normalize(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(normalized, key),
           {:ok, item} <- normalize(item) do
        {:cont, {:ok, Map.put(normalized, key, item)}}
      else
        _invalid -> {:halt, :error}
      end
    end)
  end

  def normalize(_value), do: :error

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: :error
end
