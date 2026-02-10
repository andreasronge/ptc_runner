defmodule CodeScout do
  @moduledoc """
  Public API for Code Scout.
  """
  alias CodeScout.Agent
  alias PtcRunner.SubAgent

  @doc """
  Queries the codebase using the Code Scout agent.
  """
  def query(query_string, opts \\ []) do
    agent = Agent.new()

    # Apply compression option to agent if specified
    agent =
      if opts[:compression] do
        %{agent | compression: true}
      else
        agent
      end

    # Apply max_turns option to agent if specified
    agent =
      if opts[:max_turns] do
        %{agent | max_turns: opts[:max_turns]}
      else
        agent
      end

    model = opts[:model] || LLMClient.default_model()
    llm = LLMClient.callback(model, cache: true)

    # Merge query into context
    context = Map.put(opts[:context] || %{}, "query", query_string)

    SubAgent.run(agent, ([llm: llm] ++ opts) |> Keyword.put(:context, context))
  end
end
