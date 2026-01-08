defmodule PtcRunner.Lisp.Eval.Helpers do
  @moduledoc """
  Shared helper functions for Lisp evaluation.

  Provides type error formatting and type description utilities.
  """

  alias PtcRunner.Lisp.Env

  @doc """
  Generates a type error tuple for FunctionClauseError in builtins.
  """
  @spec type_error_for_args(function(), [term()]) :: {:type_error, String.t(), term()}
  def type_error_for_args(fun, args) do
    fun_name = function_name(fun)

    case specific_type_error(fun_name, args) do
      {:ok, error} -> error
      :none -> generic_type_error(fun_name, args)
    end
  end

  # Specific error messages for common mistakes
  defp specific_type_error(name, [_, %MapSet{} = set])
       when name in [:take, :drop, :sort_by, :pluck, :take_while, :drop_while] do
    {:ok, {:type_error, "#{name} does not support sets (sets are unordered)", set}}
  end

  defp specific_type_error(name, [%MapSet{} = set])
       when name in [:first, :last, :nth, :reverse, :distinct, :flatten, :sort] do
    {:ok, {:type_error, "#{name} does not support sets (sets are unordered)", set}}
  end

  # first/last/nth on maps - maps are unordered
  defp specific_type_error(name, [%{} = _map] = args)
       when name in [:first, :last, :reverse, :sort] do
    {:ok,
     {:type_error,
      "#{name} does not support maps (maps are unordered). " <>
        "Use (keys m), (vals m), or (entries m) to get a sorted list", args}}
  end

  defp specific_type_error(:nth, [_n, %{} = _map] = args) do
    {:ok,
     {:type_error,
      "nth does not support maps (maps are unordered). " <>
        "Use (keys m), (vals m), or (entries m) to get a sorted list", args}}
  end

  defp specific_type_error(:update_vals, [f, m] = args) when is_function(f) and is_map(m) do
    {:ok,
     {:type_error,
      "update-vals expects (map, function) but got (function, map). " <>
        "Use -> (thread-first) instead of ->> (thread-last) with update-vals", args}}
  end

  defp specific_type_error(name, [key, %{} = _map] = args)
       when name in [:map, :mapv] and is_atom(key) and not is_boolean(key) do
    {:ok,
     {:type_error, "#{name}: keyword accessor requires a list of maps, got a single map", args}}
  end

  defp specific_type_error(:pluck, [key, %{} = _map] = args) when is_atom(key) do
    {:ok,
     {:type_error,
      "pluck expects a list of maps, got a single map. " <>
        "Use (:#{key} map) or (get map :#{key}) to access a single map", args}}
  end

  defp specific_type_error(:sort_by, [key, coll, comp] = args)
       when (is_atom(key) or is_binary(key) or is_function(key, 1)) and is_list(coll) and
              (is_function(comp) or comp in [:asc, :desc, :>, :<]) do
    {:ok,
     {:type_error,
      "sort-by expects (key, comparator, collection) but got (key, collection, comparator). " <>
        "Try: (sort-by #{inspect(key)} #{inspect(comp)} collection)", args}}
  end

  # reduce with map - suggest using entries
  defp specific_type_error(:reduce, [_f, %{} = _map] = args) do
    {:ok,
     {:type_error,
      "reduce only supports lists, not maps. " <>
        "To iterate over a map, use (entries my-map) to get [[key, value], ...] pairs", args}}
  end

  defp specific_type_error(:reduce, [_f, _init, %{} = _map] = args) do
    {:ok,
     {:type_error,
      "reduce only supports lists, not maps. " <>
        "To iterate over a map, use (entries my-map) to get [[key, value], ...] pairs", args}}
  end

  defp specific_type_error(_name, _args), do: :none

  defp generic_type_error(fun_name, args) do
    type_descriptions = Enum.map(args, &describe_type/1)

    {:type_error, "#{fun_name}: invalid argument types: #{Enum.join(type_descriptions, ", ")}",
     args}
  end

  @doc """
  Describes the type of a value for error messages.
  """
  @spec describe_type(term()) :: String.t()
  def describe_type(nil), do: "nil"
  def describe_type(%MapSet{}), do: "set"
  def describe_type(x) when is_list(x), do: "list"
  def describe_type(x) when is_map(x), do: "map"
  def describe_type(x) when is_binary(x), do: "string"
  def describe_type(x) when is_number(x), do: "number"
  def describe_type(x) when is_boolean(x), do: "boolean"
  def describe_type(x) when is_atom(x), do: "keyword"
  def describe_type(x) when is_function(x), do: "function"
  def describe_type(_), do: "unknown"

  @doc """
  Formats closure errors with helpful messages.
  """
  @spec format_closure_error(term()) :: String.t()
  def format_closure_error({:unbound_var, name}) do
    var_str = to_string(name)

    cond do
      # Check for common underscore/hyphen confusion
      String.contains?(var_str, "_") ->
        suggested = String.replace(var_str, "_", "-")
        "Undefined variable: #{var_str}. Hint: Use hyphens not underscores (try: #{suggested})"

      # Try to find similar builtin names
      suggestion = find_similar_builtin(name) ->
        "Undefined variable: #{var_str}. Did you mean: #{suggestion}"

      true ->
        "Undefined variable: #{var_str}"
    end
  end

  def format_closure_error(reason), do: "closure error: #{inspect(reason)}"

  # Find a similar builtin name using Jaro distance + heuristics
  defp find_similar_builtin(name) do
    name_str = to_string(name)
    builtins = Env.initial() |> Map.keys() |> Enum.map(&to_string/1)

    # Score each builtin: higher is better
    scored =
      builtins
      |> Enum.map(fn builtin ->
        jaro = String.jaro_distance(name_str, builtin)
        # Bonus for same sorted characters (catches transpositions like "mpa" -> "map")
        same_chars_bonus = if sorted_chars(name_str) == sorted_chars(builtin), do: 0.3, else: 0
        # Bonus for similar length (penalize long suggestions for short input)
        len_diff = abs(String.length(name_str) - String.length(builtin))
        len_penalty = len_diff * 0.05
        score = jaro + same_chars_bonus - len_penalty
        {builtin, score, jaro}
      end)
      |> Enum.filter(fn {_builtin, score, jaro} -> score > 0.8 or jaro > 0.85 end)
      |> Enum.max_by(fn {_builtin, score, _jaro} -> score end, fn -> nil end)

    case scored do
      {builtin, _score, _jaro} -> builtin
      nil -> nil
    end
  end

  defp sorted_chars(str) do
    str |> String.graphemes() |> Enum.sort()
  end

  # Extract function name from function reference
  defp function_name(fun) when is_function(fun) do
    case Function.info(fun, :name) do
      {:name, name} -> name
      _ -> :unknown
    end
  end
end
