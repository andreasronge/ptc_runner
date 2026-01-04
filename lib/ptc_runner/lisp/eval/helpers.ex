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
    type_descriptions = Enum.map(args, &describe_type/1)

    case {fun_name, args} do
      # Sequence functions that don't support sets
      {name, [_, %MapSet{}]}
      when name in [:take, :drop, :sort_by, :pluck] ->
        {:type_error, "#{name} does not support sets (sets are unordered)", hd(tl(args))}

      {name, [_, %MapSet{}]}
      when name in [:take_while, :drop_while] ->
        {:type_error, "#{name} does not support sets (sets are unordered)", hd(tl(args))}

      {name, [%MapSet{}]}
      when name in [:first, :last, :nth, :reverse, :distinct, :flatten, :sort] ->
        {:type_error, "#{name} does not support sets (sets are unordered)", hd(args)}

      # update_vals with swapped arguments (function, map) instead of (map, function)
      {:update_vals, [f, m]} when is_function(f) and is_map(m) ->
        {:type_error,
         "update-vals expects (map, function) but got (function, map). " <>
           "Use -> (thread-first) instead of ->> (thread-last) with update-vals", args}

      _ ->
        {:type_error, "invalid argument types: #{Enum.join(type_descriptions, ", ")}", args}
    end
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
