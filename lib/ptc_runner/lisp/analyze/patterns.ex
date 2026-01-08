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
    case split_at_ampersand(elements) do
      {:rest, leading, rest_elem} ->
        with {:ok, leading_patterns} <- analyze_pattern_list(leading),
             {:ok, rest_pattern} <- analyze_pattern(rest_elem) do
          {:ok, {:destructure, {:seq_rest, leading_patterns, rest_pattern}}}
        end

      :no_rest ->
        with {:ok, patterns} <- analyze_pattern_list(elements) do
          {:ok, {:destructure, {:seq, patterns}}}
        end

      {:error, _} = err ->
        err
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

  # Splits vector elements at & symbol for rest pattern destructuring.
  # Returns {:rest, leading_elements, rest_element} or :no_rest
  defp split_at_ampersand(elements) do
    case Enum.split_while(elements, &(&1 != {:symbol, :&})) do
      {_all, []} ->
        :no_rest

      {_, [{:symbol, :&}]} ->
        {:error, {:invalid_form, "& must be followed by a pattern"}}

      {leading, [{:symbol, :&}, rest]} ->
        {:rest, leading, rest}

      {_, [{:symbol, :&}, _ | extra]} ->
        {:error,
         {:invalid_form,
          "& must be followed by exactly one pattern, got extra: #{inspect(extra)}"}}
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

    # Extract rename/nested pattern pairs (pattern keys paired with keyword/symbol source keys)
    special_keys = [:keys, :or, :as]

    rename_pairs =
      pairs
      |> Enum.filter(fn
        {{:keyword, k}, _} -> k not in special_keys
        _ -> true
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
      {pattern_ast, source_key_ast}, {:ok, acc} ->
        with {:ok, pattern} <- analyze_pattern(pattern_ast),
             {:ok, source_key} <- extract_source_key(source_key_ast) do
          {:cont, {:ok, [{pattern, source_key} | acc]}}
        else
          {:error, _} = err -> {:halt, err}
        end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp extract_source_key({:keyword, k}), do: {:ok, k}
  defp extract_source_key({:symbol, k}), do: {:ok, k}
  defp extract_source_key({:string, s}), do: {:ok, s}

  defp extract_source_key(other),
    do: {:error, {:invalid_form, "invalid source key: #{inspect(other)}"}}

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
      {{:symbol, k}, v_ast}, {:ok, acc} ->
        # For now, we only support literal defaults to avoid recursive dependency on Analyze.analyze
        # but we unwrap them so they don't return internal tuples.
        case unwrap_literal(v_ast) do
          {:ok, v} -> {:cont, {:ok, [{k, v} | acc]}}
          {:error, _} = err -> {:halt, err}
        end

      {_other_key, _v}, _acc ->
        {:halt, {:error, {:invalid_form, "default keys must be symbols"}}}
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp unwrap_literal({:string, s}), do: {:ok, s}
  defp unwrap_literal({:keyword, k}), do: {:ok, k}
  defp unwrap_literal(n) when is_integer(n) or is_float(n), do: {:ok, n}
  defp unwrap_literal(nil), do: {:ok, nil}
  defp unwrap_literal(true), do: {:ok, true}
  defp unwrap_literal(false), do: {:ok, false}

  defp unwrap_literal(other),
    do:
      {:error,
       {:invalid_form,
        "only literal defaults are supported in :or for now, got #{inspect(other)}"}}

  defp maybe_wrap_as(base_pattern, as_pair) do
    case as_pair do
      {{:keyword, :as}, {:symbol, as_name}} ->
        {:ok, {:destructure, {:as, as_name, base_pattern}}}

      nil ->
        {:ok, base_pattern}
    end
  end
end
