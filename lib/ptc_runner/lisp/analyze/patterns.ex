defmodule PtcRunner.Lisp.Analyze.Patterns do
  @moduledoc """
  Pattern analysis and destructuring for let bindings and function parameters.

  Transforms RawAST pattern forms into CoreAST pattern representations.
  Supports simple variable bindings, sequential destructuring, and map destructuring
  with :keys, :or defaults, :as bindings, and renamed keys.
  """

  @doc """
  Analyzes a pattern AST for use in bindings.

  ## Examples

      iex> PtcRunner.Lisp.Analyze.Patterns.analyze_pattern({:symbol, :x})
      {:ok, {:var, :x}}

      iex> PtcRunner.Lisp.Analyze.Patterns.analyze_pattern({:vector, [{:symbol, :a}, {:symbol, :b}]})
      {:ok, {:destructure, {:seq, [{:var, :a}, {:var, :b}]}}}

  """
  @spec analyze_pattern(term()) :: {:ok, term()} | {:error, term()}
  def analyze_pattern({:symbol, name}), do: {:ok, {:var, name}}

  def analyze_pattern({:vector, elements}) do
    with {:ok, patterns} <- analyze_pattern_list(elements) do
      {:ok, {:destructure, {:seq, patterns}}}
    end
  end

  def analyze_pattern({:map, pairs}) do
    analyze_destructure_map(pairs)
  end

  def analyze_pattern(other) do
    {:error, {:unsupported_pattern, other}}
  end

  defp analyze_pattern_list(elements) do
    elements
    |> Enum.reduce_while({:ok, []}, fn elem, {:ok, acc} ->
      case analyze_pattern(elem) do
        {:ok, p} -> {:cont, {:ok, [p | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp analyze_destructure_map(pairs) do
    keys_pair =
      Enum.find(pairs, fn
        {{:keyword, k}, _} -> k == :keys
        _ -> false
      end)

    or_pair =
      Enum.find(pairs, fn
        {{:keyword, k}, _} -> k == :or
        _ -> false
      end)

    as_pair =
      Enum.find(pairs, fn
        {{:keyword, k}, _} -> k == :as
        _ -> false
      end)

    # Extract rename pairs (symbol keys paired with keyword values)
    rename_pairs =
      pairs
      |> Enum.filter(fn
        {{:symbol, _}, {:keyword, _}} -> true
        _ -> false
      end)

    with {:ok, keys} <- extract_keys_opt(keys_pair),
         {:ok, renames} <- extract_renames(rename_pairs),
         {:ok, defaults} <- extract_defaults(or_pair) do
      # Only create a pattern if we have keys, renames, or defaults
      has_keys = not Enum.empty?(keys)
      has_renames = not Enum.empty?(renames)
      has_defaults = not Enum.empty?(defaults)

      if has_keys || has_renames || has_defaults do
        base_pattern =
          if has_renames do
            {:destructure, {:map, keys, renames, defaults}}
          else
            {:destructure, {:keys, keys, defaults}}
          end

        maybe_wrap_as(base_pattern, as_pair)
      else
        {:error, {:unsupported_pattern, pairs}}
      end
    end
  end

  defp extract_keys_opt(keys_pair) do
    case keys_pair do
      {{:keyword, :keys}, {:vector, key_asts}} ->
        extract_keys(key_asts)

      nil ->
        {:ok, []}

      _ ->
        {:error, {:invalid_form, "invalid :keys destructuring form"}}
    end
  end

  defp extract_keys(key_asts) do
    Enum.reduce_while(key_asts, {:ok, []}, fn
      {:symbol, name}, {:ok, acc} ->
        {:cont, {:ok, [name | acc]}}

      {:keyword, k}, {:ok, acc} ->
        {:cont, {:ok, [k | acc]}}

      _other, _acc ->
        {:halt, {:error, {:invalid_form, "expected keyword or symbol in destructuring key"}}}
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp extract_renames(rename_pairs) do
    Enum.reduce_while(rename_pairs, {:ok, []}, fn
      {{:symbol, bind_name}, {:keyword, source_key}}, {:ok, acc} ->
        {:cont, {:ok, [{bind_name, source_key} | acc]}}

      _other, _acc ->
        {:halt, {:error, {:invalid_form, "rename pairs must be {symbol :keyword}"}}}
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp extract_defaults(or_pair) do
    case or_pair do
      {{:keyword, :or}, {:map, default_pairs}} ->
        extract_default_pairs(default_pairs)

      nil ->
        {:ok, []}
    end
  end

  defp extract_default_pairs(default_pairs) do
    Enum.reduce_while(default_pairs, {:ok, []}, fn
      {{:symbol, k}, v}, {:ok, acc} ->
        {:cont, {:ok, [{k, v} | acc]}}

      {_other_key, _v}, _acc ->
        {:halt, {:error, {:invalid_form, "default keys must be symbols"}}}
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp maybe_wrap_as(base_pattern, as_pair) do
    case as_pair do
      {{:keyword, :as}, {:symbol, as_name}} ->
        {:ok, {:destructure, {:as, as_name, base_pattern}}}

      nil ->
        {:ok, base_pattern}
    end
  end
end
