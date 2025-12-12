defmodule PtcRunner.Json.Operations.Comparison do
  @moduledoc """
  Comparison operations for the JSON DSL.

  Implements comparison and containment checks: eq, neq, gt, gte, lt, lte, contains, in.
  """

  alias PtcRunner.Json.Operations.Helpers

  @doc """
  Evaluates a comparison operation.

  ## Arguments
    - op: Operation name
    - node: Operation definition map
    - context: Execution context
    - eval_fn: Function to recursively evaluate expressions

  ## Returns
    - `{:ok, result, memory}` on success
    - `{:error, reason}` on failure
  """
  @spec eval(String.t(), map(), any(), function()) ::
          {:ok, any(), map()} | {:error, {atom(), String.t()}}

  def eval("eq", node, context, eval_fn), do: eval_comparison(node, context, eval_fn, "eq", &==/2)

  def eval("neq", node, context, eval_fn),
    do: eval_comparison(node, context, eval_fn, "neq", &!=/2)

  def eval("gt", node, context, eval_fn), do: eval_comparison(node, context, eval_fn, "gt", &>/2)

  def eval("gte", node, context, eval_fn),
    do: eval_comparison(node, context, eval_fn, "gte", &>=/2)

  def eval("lt", node, context, eval_fn), do: eval_comparison(node, context, eval_fn, "lt", &</2)

  def eval("lte", node, context, eval_fn),
    do: eval_comparison(node, context, eval_fn, "lte", &<=/2)

  def eval("contains", node, context, eval_fn) do
    field = Map.get(node, "field")
    value = Map.get(node, "value")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_map(data) do
          field_value = Map.get(data, field)
          {:ok, contains_value?(field_value, value), memory}
        else
          {:error, {:execution_error, "contains requires a map, got #{inspect(data)}"}}
        end
    end
  end

  def eval("in", node, context, eval_fn) do
    field = Map.get(node, "field")
    value = Map.get(node, "value")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_map(data) do
          field_value = Map.get(data, field)
          {:ok, value_in?(field_value, value), memory}
        else
          {:error, {:execution_error, "in requires a map, got #{inspect(data)}"}}
        end
    end
  end

  # Private helpers

  defp eval_comparison(node, context, eval_fn, op_name, compare_fn) do
    field = Map.get(node, "field")
    value = Map.get(node, "value")

    case eval_fn.(context, nil) do
      {:error, _} = err ->
        err

      {:ok, data, memory} ->
        if is_map(data) do
          data_value = Map.get(data, field)
          {:ok, compare_fn.(data_value, value), memory}
        else
          {:error, {:execution_error, "#{op_name} requires a map, got #{inspect(data)}"}}
        end
    end
  end

  defp contains_value?(field_value, value) when is_list(field_value), do: value in field_value

  defp contains_value?(field_value, value) when is_binary(field_value) and is_binary(value),
    do: String.contains?(field_value, value)

  defp contains_value?(field_value, value) when is_map(field_value),
    do: Map.has_key?(field_value, value)

  defp contains_value?(_field_value, _value), do: false

  defp value_in?(set, value), do: Helpers.member_of?(value, set)
end
