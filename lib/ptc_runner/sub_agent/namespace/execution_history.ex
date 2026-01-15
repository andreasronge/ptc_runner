defmodule PtcRunner.SubAgent.Namespace.ExecutionHistory do
  @moduledoc "Renders tool call history and println output."

  alias PtcRunner.Lisp.Format

  @doc """
  Render tool calls made during successful turns.

  Returns `;; No tool calls made` for empty list, otherwise formatted list
  with header and entries.

  Hidden fields (keys starting with `_`) in arguments are replaced with `[Hidden]`.

  ## Examples

      iex> PtcRunner.SubAgent.Namespace.ExecutionHistory.render_tool_calls([], 20)
      ";; No tool calls made"

      iex> call = %{name: "search", args: %{query: "hello"}}
      iex> PtcRunner.SubAgent.Namespace.ExecutionHistory.render_tool_calls([call], 20)
      ";; Tool calls made:\\n;   search({:query \\"hello\\"})"

      iex> call = %{name: "search", args: %{query: "test", _token: "secret123"}}
      iex> PtcRunner.SubAgent.Namespace.ExecutionHistory.render_tool_calls([call], 20)
      ";; Tool calls made:\\n;   search({:_token \\"[Hidden]\\" :query \\"test\\"})"
  """
  @spec render_tool_calls([map()], non_neg_integer()) :: String.t()
  def render_tool_calls([], _limit), do: ";; No tool calls made"

  def render_tool_calls(tool_calls, limit) do
    # FIFO: keep most recent when limit exceeded
    calls_to_render = Enum.take(tool_calls, -limit)

    lines =
      Enum.map(calls_to_render, fn %{name: name, args: args} ->
        filtered_args = filter_hidden_args(args)
        {args_str, _truncated} = Format.to_clojure(filtered_args, limit: 3, printable_limit: 60)
        ";   #{name}(#{args_str})"
      end)

    [";; Tool calls made:" | lines] |> Enum.join("\n")
  end

  # Replace values for hidden keys (underscore prefix) with [Hidden] marker
  defp filter_hidden_args(args) when is_map(args) do
    Map.new(args, fn {key, value} ->
      key_str = to_string(key)

      if String.starts_with?(key_str, "_") do
        {key, "[Hidden]"}
      else
        {key, value}
      end
    end)
  end

  defp filter_hidden_args(args), do: args

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
