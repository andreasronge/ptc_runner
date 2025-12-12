defmodule PtcRunner.Json.Operations.Arithmetic do
  @moduledoc """
  Arithmetic operations for the JSON DSL.

  Implements arithmetic operations: add, sub, mul, div, round, pct.
  """

  alias PtcRunner.Json.Interpreter

  @doc """
  Evaluates an arithmetic operation.

  ## Arguments
    - op: Operation name
    - node: Operation definition map
    - context: Execution context
    - eval_fn: Function to recursively evaluate expressions (unused for arithmetic)

  ## Returns
    - `{:ok, result, memory}` on success
    - `{:error, reason}` on failure
  """
  @spec eval(String.t(), map(), any(), function()) ::
          {:ok, any(), map()} | {:error, {atom(), String.t()}}

  def eval("add", node, context, _eval_fn),
    do: eval_binary_arithmetic(node, context, "add", &+/2)

  def eval("sub", node, context, _eval_fn),
    do: eval_binary_arithmetic(node, context, "sub", &-/2)

  def eval("mul", node, context, _eval_fn),
    do: eval_binary_arithmetic(node, context, "mul", &*/2)

  def eval("div", node, context, _eval_fn) do
    left_expr = Map.get(node, "left")
    right_expr = Map.get(node, "right")

    with {:ok, left_val, mem1} <- Interpreter.eval(left_expr, context),
         {:ok, right_val, mem2} <- Interpreter.eval(right_expr, %{context | memory: mem1}) do
      if is_number(left_val) and is_number(right_val) do
        if right_val == 0 do
          {:error, {:execution_error, "division by zero"}}
        else
          {:ok, left_val / right_val, Map.merge(mem1, mem2)}
        end
      else
        {:error,
         {:execution_error,
          "div requires numeric operands, got: #{inspect(left_val)}, #{inspect(right_val)}"}}
      end
    end
  end

  def eval("round", node, context, _eval_fn) do
    value_expr = Map.get(node, "value")
    precision = Map.get(node, "precision", 0)

    case Interpreter.eval(value_expr, context) do
      {:error, _} = err ->
        err

      {:ok, value, memory} ->
        if is_number(value) and is_integer(precision) do
          rounded = Float.round(value / 1, precision) * 1
          {:ok, rounded, memory}
        else
          {:error,
           {:execution_error,
            "round requires numeric value and integer precision, got: #{inspect(value)}, #{inspect(precision)}"}}
        end
    end
  end

  def eval("pct", node, context, _eval_fn) do
    part_expr = Map.get(node, "part")
    whole_expr = Map.get(node, "whole")

    with {:ok, part_val, mem1} <- Interpreter.eval(part_expr, context),
         {:ok, whole_val, mem2} <- Interpreter.eval(whole_expr, %{context | memory: mem1}) do
      if is_number(part_val) and is_number(whole_val) do
        if whole_val == 0 do
          {:error, {:execution_error, "division by zero"}}
        else
          {:ok, part_val / whole_val * 100, Map.merge(mem1, mem2)}
        end
      else
        {:error,
         {:execution_error,
          "pct requires numeric operands, got: #{inspect(part_val)}, #{inspect(whole_val)}"}}
      end
    end
  end

  # Private helpers

  defp eval_binary_arithmetic(node, context, op_name, op_fn) do
    left_expr = Map.get(node, "left")
    right_expr = Map.get(node, "right")

    with {:ok, left_val, mem1} <- Interpreter.eval(left_expr, context),
         {:ok, right_val, mem2} <- Interpreter.eval(right_expr, %{context | memory: mem1}) do
      if is_number(left_val) and is_number(right_val) do
        {:ok, op_fn.(left_val, right_val), Map.merge(mem1, mem2)}
      else
        {:error,
         {:execution_error,
          "#{op_name} requires numeric operands, got: #{inspect(left_val)}, #{inspect(right_val)}"}}
      end
    end
  end
end
