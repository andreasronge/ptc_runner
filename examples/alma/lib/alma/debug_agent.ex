defmodule Alma.DebugAgent do
  @moduledoc """
  Debug agent that analyzes parent designs using grep over runtime logs.

  Runs as a PTC-Lisp SubAgent with `grep`/`grep-n` builtin tools. The debug
  log is passed as context (`data/debug_log`) and the agent greps over it to
  search through actual runtime data (println output, tool call traces, error
  messages, return values) and returns a structured critique via `(return ...)`.

  The agent produces the same output format as the Analyst (`## Analysis` +
  `## Mandatory Constraints`) for compatibility with `MetaAgent`.
  """

  alias PtcRunner.SubAgent
  alias PtcRunner.TraceLog
  alias PtcRunner.TraceLog.Collector
  alias Alma.DebugLog

  @doc """
  Analyzes parent designs by grepping through their runtime logs.

  Returns `{:ok, critique, child_trace_id}` or `{:error, reason}`.
  When tracing is active, creates a separate child trace file for ptc_viewer drill-in.
  """
  @spec analyze([map()], keyword()) ::
          {:ok, String.t(), String.t() | nil} | {:error, term()}
  def analyze(parents, opts \\ []) do
    llm = Keyword.get(opts, :llm)

    if is_nil(llm) or Enum.empty?(parents) do
      {:ok, "", nil}
    else
      debug_log = DebugLog.format_parents(parents, opts)

      # Skip analysis when debug log has no runtime data (e.g., seed designs
      # that were never evaluated with runtime logging)
      if String.length(debug_log) < 200 or
           not String.contains?(debug_log, ["TOOL ", "PRINT:", "ERROR:", "RETURN:"]) do
        {:ok, "", nil}
      else
        agent =
          SubAgent.new(
            name: "debug_agent",
            prompt: mission_prompt(parents, debug_log),
            system_prompt: %{prefix: system_prompt()},
            builtin_tools: [:grep],
            max_turns: 5,
            timeout: 15_000,
            max_heap: 6_250_000
          )

        run_agent(agent, llm, debug_log)
      end
    end
  end

  defp run_agent(agent, llm, debug_log) do
    case TraceLog.current_collector() do
      nil ->
        # No tracing — run normally
        case SubAgent.run(agent, llm: llm, context: %{"debug_log" => debug_log}) do
          {:ok, step} -> {:ok, step.return || "", nil}
          {:error, reason} -> {:error, reason}
        end

      collector ->
        # Create child trace file for viewer drill-in
        child_trace_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
        trace_dir = collector |> Collector.path() |> Path.dirname()
        child_path = Path.join(trace_dir, "trace_#{child_trace_id}.jsonl")
        parent_trace_id = Collector.trace_id(collector)

        child_trace_context = %{
          trace_id: child_trace_id,
          parent_span_id: PtcRunner.SubAgent.Telemetry.current_span_id(),
          depth: 1,
          trace_dir: trace_dir
        }

        {:ok, result, _path} =
          TraceLog.with_trace(
            fn ->
              SubAgent.run(agent,
                llm: llm,
                context: %{"debug_log" => debug_log},
                trace_context: child_trace_context
              )
            end,
            path: child_path,
            trace_id: child_trace_id,
            meta: %{parent_trace_id: parent_trace_id, depth: 1, tool_name: "debug_agent"}
          )

        case result do
          {:ok, step} -> {:ok, step.return || "", child_trace_id}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp system_prompt do
    """
    You are a memory design debugger. You have access to runtime logs from \
    memory design evaluations. The debug log is in `data/debug_log`. Use the \
    `grep` and `grep-n` tools to search for patterns in it.

    Example: `(tool/grep {:pattern "ERROR:" :text data/debug_log})`
    Example: `(tool/grep-n {:pattern "FAILED" :text data/debug_log :context 2})`

    Useful grep patterns:
    - `"TOOL find-similar.*\\[\\]"` — recall queries that returned empty results
    - `"ERROR:"` — runtime errors in mem-update or recall
    - `"FAILED"` — failed episodes
    - `"RETURN:.*\\"\\"" ` — recall returning empty advice
    - `"PRINT:"` — debug println output from the design
    - `"TOOL store-obs"` — what observations were stored
    - `"TOOL graph-update"` — what graph edges were added
    - `"TOOL graph-path.*nil"` — path queries that found no route

    Your final message is the output that gets used. Structure it in two sections:

    ## Analysis
    Cite specific evidence from the logs. Quote relevant log lines you found \
    via grep. Identify:
    - Whether recall is returning useful advice or empty/generic text
    - Whether mem-update is storing enough observations
    - Whether tool calls are succeeding or failing
    - Whether the graph is being built and queried effectively
    - Any println debug output that reveals issues

    ## Mandatory Constraints
    Based on your analysis, list 2-4 concrete constraints that the NEXT design \
    MUST satisfy. These are hard requirements, not suggestions. Address the \
    specific weaknesses you found in the logs.

    Keep your analysis under 400 words. Return the full analysis text \
    via `(return "your analysis...")`.
    """
  end

  defp mission_prompt(parents, debug_log) do
    parent_summary =
      parents
      |> Enum.map(fn p ->
        name = Map.get(p.design, :name, "unknown")
        score = Float.round(p.score * 1.0, 2)
        "- #{name} (score: #{score})"
      end)
      |> Enum.join("\n")

    """
    Analyze these parent memory designs:
    #{parent_summary}

    Debug log is in `data/debug_log` (#{String.length(debug_log)} chars). \
    Search it with `(tool/grep {:pattern "..." :text data/debug_log})`.

    Focus areas:
    1. Recall quality — is the advice specific and useful, or empty/generic?
    2. Store usage — are observations being stored effectively?
    3. Errors — any runtime failures in mem-update or recall?
    4. Graph — is the spatial graph being built and queried?
    5. Debug output — any println clues about what's happening?

    Search the debug log using grep, then return your analysis via \
    `(return "...")`.
    """
  end
end
