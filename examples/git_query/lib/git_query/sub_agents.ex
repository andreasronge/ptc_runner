defmodule GitQuery.SubAgents do
  @moduledoc """
  SubAgents for the Git Query application.

  Uses a two-agent composition pattern:
  1. Explorer (PTC-Lisp) - Decides tool strategy, combines/filters results
  2. Synthesizer (JSON) - Converts findings to natural language
  """

  alias PtcRunner.SubAgent
  alias GitQuery.Tools

  @doc """
  Creates an explorer agent that analyzes the git repository.

  This agent:
  1. Analyzes the user's question to determine which tools to use
  2. Calls appropriate git tools to gather data
  3. Combines and filters results programmatically
  4. Returns structured findings for the synthesizer

  Uses PTC-Lisp for programmatic control over tool orchestration.
  """
  def explorer(repo_path) do
    SubAgent.new(
      prompt: """
      You are a git repository analyst. Answer questions about the repository at: #{repo_path}

      Analyze the user's question and use the appropriate git tools to find the answer.

      Available tools and when to use them:
      - `get_commits`: Get commit history with filters (author, date, path, message grep)
      - `get_author_stats`: Get commit counts by author (best for "who contributed most")
      - `get_file_stats`: Get most frequently changed files, can filter by author
      - `get_file_history`: Get history for a specific file
      - `get_diff_stats`: Get line change statistics

      The optional `path` parameter filters results to a subdirectory (e.g., "lib/").

      Date filters use git's date parsing, examples:
      - "1 month ago", "2 weeks ago", "yesterday"
      - "2024-01-01" for specific dates

      Strategy tips:
      - For "who contributed most" questions: use `get_author_stats`
      - For "what changed" questions: use `get_commits` or `get_file_stats`
      - For "files changed by a specific person": use `get_file_stats` with `author` filter
      - For questions about specific files: use `get_file_history`
      - Combine tools when needed (e.g., author stats + their file changes)

      Write your program in a single clean pass. Plan your approach, then write concise code.
      Do not repeat tool calls or redefine variables.

      Return findings as a list of data points with their type and content.
      Include a brief summary of what you found.
      """,
      signature: "(question :string) -> {findings [{type :string, data :any}], summary :string?}",
      tools: build_tools(repo_path),
      compression: true,
      max_turns: 5,
      timeout: 45_000
    )
  end

  @doc """
  Creates a synthesizer agent that converts findings to natural language.

  This agent:
  1. Receives the question and structured findings from the explorer
  2. Formulates a clear, natural language answer
  3. Returns a single answer string

  Uses JSON mode for simple output.
  """
  def synthesizer do
    SubAgent.new(
      prompt: """
      You are a helpful assistant that answers questions about git repositories.

      ## Question
      {{question}}

      ## Findings from Repository Analysis
      {{#summary}}Summary: {{summary}}{{/summary}}

      {{#findings}}
      - Type: {{type}}
        Data: {{data}}
      {{/findings}}

      Based on these findings, provide a clear, concise natural language answer.

      Focus on:
      - Directly answering the question
      - Highlighting key numbers and names
      - Being concise but complete

      If the findings are empty or insufficient, say so clearly.
      """,
      signature:
        "(question :string, findings [{type :string, data :any}], summary :string?) -> {answer :string}",
      output: :json,
      max_turns: 1,
      timeout: 15_000
    )
  end

  # Build tools map with repo_path pre-configured and PTC-Lisp signatures
  defp build_tools(repo_path) do
    sigs = Tools.signatures()

    %{
      "get_commits" => build_tool(&Tools.get_commits/1, repo_path, sigs[:get_commits]),
      "get_author_stats" =>
        build_tool(&Tools.get_author_stats/1, repo_path, sigs[:get_author_stats]),
      "get_file_stats" => build_tool(&Tools.get_file_stats/1, repo_path, sigs[:get_file_stats]),
      "get_file_history" =>
        build_tool(&Tools.get_file_history/1, repo_path, sigs[:get_file_history]),
      "get_diff_stats" => build_tool(&Tools.get_diff_stats/1, repo_path, sigs[:get_diff_stats])
    }
  end

  # Build a tool tuple with signature, description, and repo_path injection
  defp build_tool(fun, repo_path, {signature, description}) do
    wrapped_fun = fn params ->
      params
      |> Map.put("repo_path", repo_path)
      |> fun.()
    end

    {wrapped_fun, signature: signature, description: description}
  end
end
