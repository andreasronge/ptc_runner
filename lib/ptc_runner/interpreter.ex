defmodule PtcRunner.Interpreter do
  @moduledoc """
  Interprets and evaluates AST nodes.

  Recursively evaluates operations by dispatching to the Operations module.
  """

  alias PtcRunner.Context
  alias PtcRunner.Operations

  @doc """
  Evaluates an AST node in a given context.

  ## Arguments
    - node: The AST node to evaluate
    - context: The execution context

  ## Returns
    - `{:ok, result}` on success
    - `{:error, reason}` on failure
  """
  @spec eval(map(), Context.t()) :: {:ok, any()} | {:error, String.t()}
  def eval(node, context) when is_map(node) do
    # Handle input from pipe - if __input is set, use that value
    input = Map.get(node, "__input")
    node_without_input = Map.delete(node, "__input")

    case Map.get(node_without_input, "op") do
      nil ->
        {:error, "Missing required field 'op'"}

      op ->
        # For operations that need input (everything except literal, load, var)
        if input != nil and op not in ["literal", "load", "var"] do
          # Create a context with the input value available
          input_context = Context.put_var(context, "__input", input)
          eval_operation(op, node_without_input, input_context)
        else
          eval_operation(op, node_without_input, context)
        end
    end
  end

  def eval(node, _context) do
    {:error, "Node must be a map, got #{inspect(node)}"}
  end

  defp eval_operation(op, node, context) do
    # Create a wrapper function for recursive evaluation
    eval_fn = fn ctx, _acc ->
      # Get the input value if it exists
      input_value = Map.get(ctx.variables, "__input")

      if input_value != nil do
        {:ok, input_value}
      else
        {:error, "No input available"}
      end
    end

    Operations.eval(op, node, context, eval_fn)
  end
end
