defmodule PtcRunner.SubAgent.Namespace.ExecutionHistory do
  @moduledoc "Renders tool call history and println output."

  alias PtcRunner.Lisp.Format

  @doc """
  Render tool calls made during successful turns.

  Returns `;; No tool calls made` for empty list, otherwise formatted list
  with header and entries.

  ## Examples

      iex> PtcRunner.SubAgent.Namespace.ExecutionHistory.render_tool_calls([], 20)
      ";; No tool calls made"

      iex> call = %{name: "search", args: %{query: "hello"}}
      iex> PtcRunner.SubAgent.Namespace.ExecutionHistory.render_tool_calls([call], 20)
      ";; Tool calls made:\\n;   search({:query \\"hello\\"})"
  """
  @spec render_tool_calls([map()], non_neg_integer()) :: String.t()
  def render_tool_calls([], _limit), do: ";; No tool calls made"

  def render_tool_calls(tool_calls, limit) do
    # FIFO: keep most recent when limit exceeded
    calls_to_render = Enum.take(tool_calls, -limit)

    lines =
      Enum.map(calls_to_render, fn %{name: name, args: args} ->
        {args_str, _truncated} = Format.to_clojure(args, limit: 3, printable_limit: 60)
        ";   #{name}(#{args_str})"
      end)

    [";; Tool calls made:" | lines] |> Enum.join("\n")
  end

  @doc """
  Render println output from successful turns.

  Returns `nil` when `has_println` is false (no output section needed),
  otherwise a formatted list with header and output lines.

  ## Examples

      iex> PtcRunner.SubAgent.Namespace.ExecutionHistory.render_output([], 15, false)
      nil

      iex> PtcRunner.SubAgent.Namespace.ExecutionHistory.render_output(["hello", "world"], 15, true)
      ";; Output:\\nhello\\nworld"
  """
  @spec render_output([String.t()], non_neg_integer(), boolean()) :: String.t() | nil
  def render_output(_prints, _limit, false), do: nil

  def render_output(prints, limit, true) do
    # FIFO: keep most recent when limit exceeded
    prints_to_render = Enum.take(prints, -limit)
    [";; Output:" | prints_to_render] |> Enum.join("\n")
  end
end
