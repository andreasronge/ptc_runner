defmodule PtcRunner.ToolExecutionError do
  @moduledoc """
  Exception raised when a tool execution fails.

  Carries the eval context so that tool calls can be properly recorded in traces
  even when the tool fails.

  ## Fields

  - `message`: Error message from the tool
  - `eval_ctx`: The evaluation context at time of failure (contains recorded tool_calls)
  - `tool_name`: Name of the tool that failed
  """

  defexception [:message, :eval_ctx, :tool_name]

  @impl true
  def exception(term) do
    case term do
      attrs when is_map(attrs) ->
        msg = attrs[:message] || "Tool execution failed"

        %__MODULE__{
          message: msg,
          eval_ctx: attrs[:eval_ctx],
          tool_name: attrs[:tool_name]
        }

      attrs when is_list(attrs) ->
        msg = Keyword.get(attrs, :message, "Tool execution failed")

        %__MODULE__{
          message: msg,
          eval_ctx: Keyword.get(attrs, :eval_ctx),
          tool_name: Keyword.get(attrs, :tool_name)
        }

      msg when is_binary(msg) ->
        %__MODULE__{message: msg, eval_ctx: nil, tool_name: nil}
    end
  end
end
