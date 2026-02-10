defmodule CodeScout.Agent do
  @moduledoc """
  Configuration for the Code Scout SubAgent.

  Tools are defined with Elixir `@spec` annotations in `CodeScout.Tools`,
  and their signatures are automatically extracted to PTC-Lisp format.
  """
  alias PtcRunner.SubAgent
  alias CodeScout.Tools

  @doc """
  Returns a new Code Scout SubAgent.
  """
  def new do
    SubAgent.new(
      prompt: """
      You are Code Scout, an expert developer who helps users understand their codebase.
      Your task is to answer the user's query: "{{query}}"

      Domain: Elixir codebase implementing the PTC-Lisp interpreter.
      Scope: Restrict investigations to `lib/ptc_runner`.

      Strategy:
      1. Search for relevant keywords using grep.
      2. Analyze results with PTC-Lisp (println, filter, map, count, take, ...).
      3. Read promising files with read_file.
      4. Return a structured result matching the signature when you have enough information to answer the query.
      """,
      signature:
        "(query :string) -> {answer :string, relevant_files [:string], confidence :float}",
      tools: %{
        "grep" => &Tools.grep/1,
        "read_file" => &Tools.read_file/1
      },
      max_turns: 6,
      format_options: [
        feedback_limit: 20,
        feedback_max_chars: 2048
      ]
    )
  end
end
