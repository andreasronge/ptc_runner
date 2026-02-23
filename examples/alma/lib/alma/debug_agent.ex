defmodule Alma.DebugAgent do
  @moduledoc """
  Debug agent that analyzes parent designs using grep over runtime logs.

  Replaces `Alma.Analyst` with a SubAgent that has access to `grep`/`grep-n`
  builtin tools. Instead of a single-shot LLM call reading source + metrics,
  the debug agent can search through actual runtime data: println output,
  tool call traces, error messages, and return values from mem-update/recall.

  The agent produces the same output format as the Analyst (`## Analysis` +
  `## Mandatory Constraints`) for compatibility with `MetaAgent`.
  """

  alias PtcRunner.SubAgent
  alias Alma.DebugLog

  @doc """
  Analyzes parent designs by grepping through their runtime logs.

  Returns `{:ok, critique}` or `{:error, reason}`.
  """
  @spec analyze([map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def analyze(parents, opts \\ []) do
    llm = Keyword.get(opts, :llm)

    if is_nil(llm) or Enum.empty?(parents) do
      {:ok, ""}
    else
      debug_log = DebugLog.format_parents(parents, opts)

      # Skip analysis when debug log has no runtime data (e.g., seed designs
      # that were never evaluated with runtime logging)
      if String.length(debug_log) < 200 or
           not String.contains?(debug_log, ["TOOL ", "PRINT:", "ERROR:", "RETURN:"]) do
        {:ok, ""}
      else
        agent =
          SubAgent.new(
            name: "debug_agent",
            prompt: mission_prompt(parents, debug_log),
            system_prompt: %{prefix: system_prompt()},
            output: :text,
            builtin_tools: [:grep],
            max_turns: 5,
            timeout: 15_000,
            max_heap: 6_250_000
          )

        case SubAgent.run(agent, llm: llm, context: %{"debug_log" => debug_log}) do
          {:ok, step} ->
            {:ok, step.return || ""}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp system_prompt do
    """
    You are a memory design debugger. You have access to runtime logs from \
    memory design evaluations. Use the grep tools on `data/debug_log` \
    to search for patterns in the logs and produce evidence-based analysis.

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

    Keep your analysis under 400 words.
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

    Debug log available in `data/debug_log` (#{String.length(debug_log)} chars).

    Focus areas:
    1. Recall quality — is the advice specific and useful, or empty/generic?
    2. Store usage — are observations being stored effectively?
    3. Errors — any runtime failures in mem-update or recall?
    4. Graph — is the spatial graph being built and queried?
    5. Debug output — any println clues about what's happening?

    Search the debug log using the grep tools, then provide your analysis.
    """
  end
end
