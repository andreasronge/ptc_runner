defmodule GitQuery.CLI.Formatter do
  @moduledoc "Shared CLI formatting for trace summaries"

  @doc """
  Print a trace summary to the console.

  ## Options

  - `:show_status` - Include status field (default: false)
  """
  def print_summary(summary, opts \\ []) do
    show_status = Keyword.get(opts, :show_status, false)

    Mix.shell().info("  Duration:   #{summary.duration_ms || "N/A"}ms")
    Mix.shell().info("  Turns:      #{summary.turns || "N/A"}")
    Mix.shell().info("  LLM calls:  #{summary.llm_calls}")
    Mix.shell().info("  Tool calls: #{summary.tool_calls}")

    if show_status do
      Mix.shell().info("  Status:     #{summary.status || "N/A"}")
    end

    if summary.tokens do
      # Handle both atom and string keys
      input = summary.tokens[:input] || summary.tokens["input"]
      output = summary.tokens[:output] || summary.tokens["output"]
      Mix.shell().info("  Tokens:     #{input} in / #{output} out")
    end
  end
end
