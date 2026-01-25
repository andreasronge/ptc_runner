defmodule GitQuery.Anchor do
  @moduledoc """
  Builds anchor context to prevent goal drift.

  The anchor keeps the original question visible throughout the pipeline,
  ensuring steps don't lose track of the user's intent.

  Supports three modes:
  - `:full` - Pass entire original question
  - `:constraints` - Extract intent + constraints via SubAgent
  - `:summary` - Summarize question to core intent via SubAgent
  """

  alias PtcRunner.SubAgent

  @doc """
  Build anchor based on mode.

  ## Parameters

  - `question` - The original user question
  - `mode` - Anchor mode: `:full`, `:constraints`, or `:summary`
  - `llm` - LLM function for modes that need extraction

  ## Examples

      iex> GitQuery.Anchor.build("commits from last week", :full, fn _ -> nil end)
      %{original_question: "commits from last week"}
  """
  @spec build(String.t(), atom(), function()) :: map()
  def build(question, :full, _llm) do
    %{original_question: question}
  end

  def build(question, :constraints, llm) do
    case extract_constraints(question, llm) do
      {:ok, result} ->
        %{
          original_question: question,
          intent: result["intent"],
          constraints: result["constraints"]
        }

      {:error, _reason} ->
        # Fallback to full mode on error
        %{original_question: question}
    end
  end

  def build(question, :summary, llm) do
    case summarize_question(question, llm) do
      {:ok, result} ->
        %{
          original_question: question,
          intent: result["intent"]
        }

      {:error, _reason} ->
        # Fallback to full mode on error
        %{original_question: question}
    end
  end

  # Extract intent and constraints from the question
  defp extract_constraints(question, llm) do
    agent =
      SubAgent.new(
        prompt: """
        Extract the core intent and constraints from this git query question.

        Question: {{question}}

        Identify:
        - intent: what the user fundamentally wants to know
        - constraints: specific filters or requirements (time ranges, authors, file paths, etc.)

        Examples:
        - "commits from last week" -> intent: "find commits", constraints: ["last week"]
        - "who contributed most this month" -> intent: "find top contributor", constraints: ["this month"]
        - "interesting commits from alice last week" -> intent: "find notable commits from contributor", constraints: ["last week", "author: alice"]
        """,
        signature: "(question :string) -> {intent :string, constraints [:string]}",
        output: :json,
        max_turns: 1,
        timeout: 10_000
      )

    case SubAgent.run(agent, llm: llm, context: %{question: question}) do
      {:ok, step} -> {:ok, step.return}
      {:error, step} -> {:error, step.fail}
    end
  end

  # Summarize the question to its core intent
  defp summarize_question(question, llm) do
    agent =
      SubAgent.new(
        prompt: """
        Summarize this git query question to its core intent in a brief phrase.

        Question: {{question}}

        Keep it concise but include key constraints.

        Examples:
        - "commits from last week" -> "recent commits, past week"
        - "who contributed the most code this month" -> "top contributor, this month"
        - "interesting commits from the most active contributor last week" -> "top contributor's notable commits, past week"
        """,
        signature: "(question :string) -> {intent :string}",
        output: :json,
        max_turns: 1,
        timeout: 10_000
      )

    case SubAgent.run(agent, llm: llm, context: %{question: question}) do
      {:ok, step} -> {:ok, step.return}
      {:error, step} -> {:error, step.fail}
    end
  end
end
