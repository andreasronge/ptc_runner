defmodule GapAnalyzer.SubAgents do
  @moduledoc """
  Single-shot SubAgents used by the Gap Analyzer.

  Each agent does one focused task and returns structured results.
  Elixir drives the overall investigation loop.
  """

  alias PtcRunner.SubAgent
  alias GapAnalyzer.Tools

  @doc """
  Creates an investigator agent that analyzes pending requirements.

  This agent:
  1. Takes a list of requirements to investigate
  2. Searches for relevant policy sections
  3. Retrieves and compares full text
  4. Returns findings and any follow-up topics to explore

  Single-shot (max_turns: 1) - no conversation history accumulates.
  """
  def investigator do
    SubAgent.new(
      prompt: """
      You are investigating compliance requirements against company policy.

      For each requirement in `data/pending`:
      1. Search the policy for relevant sections using `search_policy`
      2. If matches found, retrieve full text with `get_policy` to verify coverage
      3. If no matches, retrieve the requirement's full text with `get_regulation` to understand the gap
      4. Determine if compliant or gap exists

      Use `data/previous_findings` for context on what was already analyzed.

      Return your findings as a list where each finding has:
      - requirement_id: the requirement ID (e.g., "REQ-1.1")
      - status: either "compliant" or "gap"
      - gap: description of the gap (only if status is "gap")
      - policy_refs: relevant policy section IDs
      - reasoning: brief explanation of your analysis

      Also return any follow-up topics worth investigating.
      """,
      signature:
        "(pending [{id :string, title :string, summary :string}], previous_findings [{requirement_id :string, status :string, gap :string?}]) -> {findings :any, follow_up_queries :any?}",
      tools: %{
        "search_regulations" => &Tools.search_regulations/1,
        "search_policy" => &Tools.search_policy/1,
        "get_regulation" => &Tools.get_regulation/1,
        "get_policy" => &Tools.get_policy/1
      },
      max_turns: 5,
      timeout: 60_000
    )
  end

  @doc """
  Creates a discovery agent that finds requirements to investigate.

  Searches for requirements related to a topic. Uses JSON mode for simplicity.
  """
  def discovery do
    SubAgent.new(
      prompt: """
      Search for security requirements related to: {{topic}}

      Use `search_regulations` to find relevant requirements.
      Return all matching requirements.
      """,
      signature: "(topic :string) -> {requirements :any}",
      tools: %{
        "search_regulations" => &Tools.search_regulations/1
      },
      max_turns: 2,
      timeout: 15_000
    )
  end

  @doc """
  Creates a summary agent that compiles final report.
  Uses JSON mode with mustache sections for direct list rendering.
  """
  def summarizer do
    SubAgent.new(
      prompt: """
      Compile a compliance gap analysis report from these findings:

      {{#findings}}
      ## {{requirement_id}}: {{status}}
      {{#gap}}Gap: {{gap}}{{/gap}}
      {{#policy_refs}}Policy references: {{policy_refs}}{{/policy_refs}}
      Reasoning: {{reasoning}}

      {{/findings}}

      Provide an executive summary highlighting:
      1. Overall compliance posture
      2. Critical gaps requiring immediate attention
      3. Recommendations prioritized by risk
      """,
      signature:
        "(findings [{requirement_id :string, status :string, gap :string?, policy_refs :string?, reasoning :string?}]) -> {summary :string, compliant_count :int, gap_count :int, critical_gaps :any, recommendations :any}",
      output: :json,
      max_turns: 1,
      timeout: 15_000
    )
  end
end
