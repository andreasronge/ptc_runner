defmodule GitQuery.Pipeline do
  @moduledoc """
  Main orchestrator for the git query pipeline.

  Coordinates anchor building, planning, and step execution based on configuration.

  ## Flow

  1. Build anchor (keeps original question visible)
  2. Maybe plan (decide single vs multi-step)
  3. Execute steps
  """

  alias GitQuery.{Anchor, Config, Planner, StepExecutor}

  @doc """
  Run the pipeline with a question and configuration.

  ## Parameters

  - `question` - The user's natural language question
  - `tools` - Map of tool name to tool function
  - `llm` - LLM function
  - `config` - Pipeline configuration (default: adaptive preset)

  ## Returns

  - `{:ok, result}` - Result map with `data`, `summary`, `done`, `status`
  - `{:error, reason}` - Error description

  ## Examples

      config = GitQuery.Config.preset(:adaptive)
      {:ok, result} = GitQuery.Pipeline.run("commits from last week", tools, llm, config)
  """
  @spec run(String.t(), map(), function(), Config.t()) :: {:ok, map()} | {:error, any()}
  def run(question, tools, llm, config \\ Config.preset(:adaptive)) do
    # Build anchor to prevent goal drift
    anchor = Anchor.build(question, config.anchor_mode, llm)

    # Decide single vs multi-step execution
    case Planner.maybe_plan(question, tools, llm, config) do
      {:single, goal} ->
        StepExecutor.execute_single(anchor, goal, tools, llm, config)

      {:planned, steps} ->
        StepExecutor.execute_plan(anchor, steps, tools, llm, config)
    end
  end
end
