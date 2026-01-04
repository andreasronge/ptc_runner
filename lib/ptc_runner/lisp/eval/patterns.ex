defmodule PtcRunner.Lisp.Eval.Patterns do
  @moduledoc """
  Pattern matching for let bindings in Lisp evaluation.

  Handles destructuring patterns including variables, map destructuring,
  sequence destructuring, and :as patterns.
  """

  import PtcRunner.Lisp.Runtime, only: [flex_fetch: 2]

  @type pattern :: term()
  @type bindings :: %{atom() => term()}
  @type match_result :: {:ok, bindings()} | {:error, {:destructure_error, String.t()}}

  @doc """
  Matches a pattern against a value, returning variable bindings on success.
  """
  @spec match_pattern(pattern(), term()) :: match_result()
  def match_pattern({:var, name}, value) do
    {:ok, %{name => value}}
  end

  def match_pattern({:destructure, {:keys, keys, defaults}}, value) when is_map(value) do
    bindings =
      Enum.reduce(keys, %{}, fn key, acc ->
        default = Keyword.get(defaults, key)

        val =
          case flex_fetch(value, key) do
            {:ok, v} -> v
            :error -> default
          end

        Map.put(acc, key, val)
      end)

    {:ok, bindings}
  end

  def match_pattern({:destructure, {:keys, _keys, _defaults}}, value) do
    {:error, {:destructure_error, "expected map, got #{inspect(value)}"}}
  end

  def match_pattern({:destructure, {:map, keys, renames, defaults}}, value) when is_map(value) do
    # First extract keys
    keys_bindings =
      Enum.reduce(keys, %{}, fn key, acc ->
        default = Keyword.get(defaults, key)

        val =
          case flex_fetch(value, key) do
            {:ok, v} -> v
            :error -> default
          end

        Map.put(acc, key, val)
      end)

    # Then extract renames
    renames_bindings =
      Enum.reduce(renames, %{}, fn {bind_name, source_key}, acc ->
        default = Keyword.get(defaults, bind_name)

        val =
          case flex_fetch(value, source_key) do
            {:ok, v} -> v
            :error -> default
          end

        Map.put(acc, bind_name, val)
      end)

    {:ok, Map.merge(keys_bindings, renames_bindings)}
  end

  def match_pattern({:destructure, {:map, _keys, _renames, _defaults}}, value) do
    {:error, {:destructure_error, "expected map, got #{inspect(value)}"}}
  end

  def match_pattern({:destructure, {:seq, patterns}}, value) when is_list(value) do
    if length(value) < length(patterns) do
      {:error,
       {:destructure_error,
        "expected at least #{length(patterns)} elements, got #{length(value)}"}}
    else
      patterns
      |> Enum.zip(value)
      |> Enum.reduce_while({:ok, %{}}, fn {pattern, val}, {:ok, acc} ->
        case match_pattern(pattern, val) do
          {:ok, bindings} -> {:cont, {:ok, Map.merge(acc, bindings)}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  def match_pattern({:destructure, {:seq, _}}, value) do
    {:error, {:destructure_error, "expected list, got #{inspect(value)}"}}
  end

  def match_pattern({:destructure, {:as, as_name, inner_pattern}}, value) do
    case match_pattern(inner_pattern, value) do
      {:ok, inner_bindings} -> {:ok, Map.put(inner_bindings, as_name, value)}
      {:error, _} = err -> err
    end
  end
end
