defmodule PtcRunner.Lisp.Eval.Helpers do
  @moduledoc """
  Shared helper functions for Lisp evaluation.

  Provides type error formatting and type description utilities.
  """

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

  defp specific_type_error(:sort_by, [key, coll, comp] = args)
       when (is_atom(key) or is_binary(key) or is_function(key, 1)) and is_list(coll) and
              (is_function(comp) or comp in [:asc, :desc, :>, :<]) do
    {:ok,
     {:type_error,
      "sort-by expects (key, comparator, collection) but got (key, collection, comparator). " <>
        "Try: (sort-by #{inspect(key)} #{inspect(comp)} collection)", args}}
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

    # Check for common underscore/hyphen confusion
    if String.contains?(var_str, "_") do
      suggested = String.replace(var_str, "_", "-")
      "Undefined variable: #{var_str}. Hint: Use hyphens not underscores (try: #{suggested})"
    else
      "Undefined variable: #{var_str}"
    end
  end

  def format_closure_error(reason), do: "closure error: #{inspect(reason)}"

  # Extract function name from function reference
  defp function_name(fun) when is_function(fun) do
    case Function.info(fun, :name) do
      {:name, name} -> name
      _ -> :unknown
    end
  end
end
