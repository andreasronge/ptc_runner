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

  def match_pattern({:destructure, {:keys, keys, defaults}}, value)
      when is_map(value) or is_nil(value) do
    value = value || %{}

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
    {:error, {:destructure_error, "expected map or nil, got #{inspect(value)}"}}
  end

  def match_pattern({:destructure, {:map, keys, renames, defaults}}, value)
      when is_map(value) or is_nil(value) do
    value = value || %{}
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
    result =
      Enum.reduce_while(renames, {:ok, keys_bindings}, fn {pattern, source_key}, {:ok, acc} ->
        # For renames, the default is keyed by the symbol name if it's a simple var
        # or we just pass nil and let the inner pattern handle its own defaults.
        default =
          case pattern do
            {:var, name} -> Keyword.get(defaults, name)
            _ -> nil
          end

        val =
          case flex_fetch(value, source_key) do
            {:ok, v} -> v
            :error -> default
          end

        case match_pattern(pattern, val) do
          {:ok, bindings} -> {:cont, {:ok, Map.merge(acc, bindings)}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    result
  end

  def match_pattern({:destructure, {:map, _keys, _renames, _defaults}}, value) do
    {:error, {:destructure_error, "expected map or nil, got #{inspect(value)}"}}
  end

  def match_pattern({:destructure, {:seq, patterns}}, value)
      when is_list(value) or is_nil(value) do
    value = value || []

    patterns
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {pattern, i}, {:ok, acc} ->
      val = Enum.at(value, i)

      case match_pattern(pattern, val) do
        {:ok, bindings} -> {:cont, {:ok, Map.merge(acc, bindings)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  def match_pattern({:destructure, {:seq, _}}, value) do
    {:error, {:destructure_error, "expected list or nil, got #{inspect(value)}"}}
  end

  # Rest pattern: [a b & rest] - binds leading patterns, then rest to remaining
  def match_pattern({:destructure, {:seq_rest, leading_patterns, rest_pattern}}, value)
      when is_list(value) or is_nil(value) do
    value = value || []
    leading_count = length(leading_patterns)
    {leading_values, rest_values} = Enum.split(value, leading_count)

    # Match leading patterns
    leading_result =
      leading_patterns
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, %{}}, fn {pattern, i}, {:ok, acc} ->
        val = Enum.at(leading_values, i)

        case match_pattern(pattern, val) do
          {:ok, bindings} -> {:cont, {:ok, Map.merge(acc, bindings)}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    # Then match rest pattern against remaining values
    case leading_result do
      {:ok, leading_bindings} ->
        case match_pattern(rest_pattern, rest_values) do
          {:ok, rest_bindings} -> {:ok, Map.merge(leading_bindings, rest_bindings)}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  def match_pattern({:destructure, {:seq_rest, _, _}}, value) do
    {:error, {:destructure_error, "expected list or nil, got #{inspect(value)}"}}
  end

  def match_pattern({:destructure, {:as, as_name, inner_pattern}}, value) do
    case match_pattern(inner_pattern, value) do
      {:ok, inner_bindings} -> {:ok, Map.put(inner_bindings, as_name, value)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Coerces a value to match the expected shape of a pattern.

  Used for rest-arg keyword arguments: when a variadic rest pattern expects map
  destructuring, converts a flat key-value list to a map. Returns an error tuple
  for odd-length lists. Returns the value unchanged for non-map patterns.

  ## Examples

      iex> pattern = {:destructure, {:keys, [:a], []}}
      iex> PtcRunner.Lisp.Eval.Patterns.coerce_for_pattern(pattern, [:a, 1])
      %{a: 1}

      iex> PtcRunner.Lisp.Eval.Patterns.coerce_for_pattern({:var, :xs}, [1, 2])
      [1, 2]
  """
  @spec coerce_for_pattern(pattern(), term()) ::
          term() | {:error, {:destructure_error, String.t()}}
  def coerce_for_pattern({:destructure, {:keys, _, _}}, args) when is_list(args),
    do: pairs_to_map(args)

  def coerce_for_pattern({:destructure, {:map, _, _, _}}, args) when is_list(args),
    do: pairs_to_map(args)

  def coerce_for_pattern({:destructure, {:as, _, inner}}, args) when is_list(args),
    do: coerce_for_pattern(inner, args)

  def coerce_for_pattern(_pattern, value), do: value

  defp pairs_to_map(list) when rem(length(list), 2) == 1,
    do:
      {:error, {:destructure_error, "keyword args must be even, got odd count: #{length(list)}"}}

  defp pairs_to_map(list) do
    list
    |> Enum.chunk_every(2)
    |> Enum.into(%{}, fn [k, v] -> {k, v} end)
  end
end
