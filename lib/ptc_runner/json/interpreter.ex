defmodule PtcRunner.Json.Interpreter do
  @moduledoc """
  Interprets and evaluates AST nodes.

  Recursively evaluates operations by dispatching to the Operations module,
  threading memory through the evaluation.
  """

  alias PtcRunner.Context
  alias PtcRunner.Json.Operations

  @doc """
  Evaluates an AST node in a given context.

  ## Arguments
    - node: The AST node to evaluate
    - context: The execution context

  ## Returns
    - `{:ok, result, memory}` on success
    - `{:error, reason}` on failure
  """
  @spec eval(map(), Context.t()) :: {:ok, any(), map()} | {:error, {atom(), String.t()}}
  def eval(node, context) when is_map(node) do
    # Handle input from pipe - if __input is set, use that value
    input = Map.get(node, "__input")
    node_without_input = Map.delete(node, "__input")

    case Map.get(node_without_input, "op") do
      nil ->
        # Check if this is an implicit object literal (no "op" field)
        if is_implicit_object(node_without_input) do
          eval_implicit_object(node_without_input, context)
        else
          {:error, {:execution_error, "Missing required field 'op'"}}
        end

      op ->
        # For operations that need input (everything except literal, load, var)
        if Map.has_key?(node, "__input") and op not in ["literal", "load", "var"] do
          # Create a context with the input value available
          input_context = Context.put_memory(context, "__input", input)
          eval_operation(op, node_without_input, input_context)
        else
          eval_operation(op, node_without_input, context)
        end
    end
  end

  def eval(node, _context) do
    {:error, {:execution_error, "Node must be a map, got #{inspect(node)}"}}
  end

  defp eval_operation(op, node, context) do
    # Create a wrapper function for recursive evaluation
    eval_fn = fn ctx, _acc ->
      # Get the input value if it exists
      if Map.has_key?(ctx.memory, "__input") do
        {:ok, Map.get(ctx.memory, "__input"), ctx.memory}
      else
        {:error, {:execution_error, "No input available"}}
      end
    end

    Operations.eval(op, node, context, eval_fn)
  end

  # Check if a map is an implicit object literal
  # An implicit object literal is a map that has no "op" field
  # Empty maps are implicit objects
  defp is_implicit_object(node) when is_map(node) do
    not Map.has_key?(node, "op")
  end

  # Evaluate an implicit object literal
  # Uses the same logic as the explicit "object" operation but on the map directly
  defp eval_implicit_object(fields_map, context) do
    Operations.eval_object(fields_map, context)
  end
end
