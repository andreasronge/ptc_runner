defmodule PtcDemo.TraceAnalyzer.Agent do
  @moduledoc """
  Trace analysis agent — uses ptc_runner to investigate its own execution traces.

  Builds a multi-turn SubAgent with tools for listing, summarizing, inspecting,
  and comparing trace files. The agent interprets tool results to answer
  developer debugging questions.

  ## Usage

      {:ok, step} = PtcDemo.TraceAnalyzer.Agent.ask(
        "Why did the planned condition use more tokens than direct?",
        trace_dir: "demo/traces"
      )
  """

  alias PtcRunner.SubAgent
  alias PtcDemo.TraceAnalyzer.Tools

  @default_trace_dir "traces"

  @doc """
  Ask the trace analyzer a question about execution traces.

  ## Options

    * `:trace_dir` - Directory containing .jsonl trace files (default: "traces")
    * `:llm` - LLM callback function (default: builds from Agent.model())
    * `:max_turns` - Maximum turns (default: 8)
    * `:verbose` - Print trace debug output (default: false)
  """
  def ask(question, opts \\ []) do
    trace_dir = Keyword.get(opts, :trace_dir, @default_trace_dir)
    max_turns = Keyword.get(opts, :max_turns, 8)
    verbose = Keyword.get(opts, :verbose, false)

    # Use provided LLM callback or default to Agent's model string
    llm = Keyword.get_lazy(opts, :llm, fn -> PtcDemo.Agent.model() end)

    trace_path = trace_path()
    tools = Tools.build(trace_dir, exclude_file: Path.basename(trace_path))

    agent =
      SubAgent.new(
        name: "trace_analyzer",
        prompt: question,
        tools: tools,
        max_turns: max_turns,
        system_prompt: %{prefix: system_prompt()}
      )

    model = PtcDemo.Agent.model()

    {:ok, result, _path} =
      PtcRunner.TraceLog.with_trace(
        fn -> SubAgent.run(agent, llm: llm, context: %{}) end,
        path: trace_path,
        trace_kind: "analysis",
        producer: "demo.trace_analyzer",
        model: model,
        query: String.slice(question, 0, 200),
        meta: %{
          trace_dir: trace_dir,
          max_turns: max_turns
        }
      )

    if verbose do
      case result do
        {:ok, step} ->
          IO.puts("\n--- Trace Analyzer ---")
          IO.puts("Turns: #{step.usage[:turns]}")
          IO.puts("Tokens: #{step.usage[:total_tokens]}")
          IO.puts("\nAnswer:")

          answer =
            if is_binary(step.return), do: step.return, else: inspect(step.return, pretty: true)

          IO.puts(answer)

        {:error, step} ->
          IO.puts("\n--- Trace Analyzer FAILED ---")
          IO.puts("Error: #{inspect(step.fail)}")
      end
    end

    result
  end

  defp system_prompt do
    """
    You are a trace analyst for PTC-Lisp agent executions. You help developers \
    debug and understand agent behavior by analyzing execution traces.

    You have access to trace analysis tools:
    - `list_traces` — cheap; lists available traces with metadata
    - `trace_summary` — cheap; overview of a trace (turns, tokens, tools, errors)
    - `turn_detail` — expensive; detailed view of a specific turn
    - `diff_traces` — expensive; compares two traces side-by-side

    Investigation strategy:
    1. Start with `list_traces` to find relevant traces
    2. Use `trace_summary` to get an overview before drilling down
    3. Only use `turn_detail` when you need to see specific program code or errors
    4. Only use `include_messages: true` when you need to see the full prompt

    Be concise in your analysis. Focus on actionable findings, not restating raw data.
    """
  end

  defp trace_path do
    dir = "traces"
    File.mkdir_p!(dir)
    datetime = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    unique_id = :erlang.unique_integer([:positive])
    Path.join(dir, "analyzer_#{datetime}_#{unique_id}.jsonl")
  end
end
