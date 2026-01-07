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

    # Use LLMClient as the default generator
    model = opts[:model] || LLMClient.default_model()

    llm_fn = fn input ->
      # SubAgent.Loop passes a map with :system and :messages
      messages = [%{role: :system, content: input.system} | input.messages]

      case LLMClient.generate_text(model, messages) do
        {:ok, response} ->
          {:ok, %{content: response.content, tokens: response.tokens}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # Merge query into context
    context = Map.put(opts[:context] || %{}, "query", query_string)

    SubAgent.run(agent, [llm: llm_fn] ++ opts |> Keyword.put(:context, context))
  end
end
