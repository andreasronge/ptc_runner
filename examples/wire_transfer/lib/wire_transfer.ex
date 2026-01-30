defmodule WireTransfer do
  @moduledoc """
  Wire transfer example demonstrating the Navigator pattern.

  Shows idempotent execution, human-in-the-loop approval, and crash-safe
  re-invocation using the journaled task system.

  ## Usage

      # Turn 1: initiate
      {:ok, step} = WireTransfer.run(%{}, "bob", 5000)
      # step.return => %{status: :waiting, ...}

      # App writes manager decision
      journal = Map.put(step.journal, "manager_decision_bob_5000", :approved)

      # Turn 2: re-invoke
      {:ok, step} = WireTransfer.run(journal, "bob", 5000)
      # step.return => %{status: :completed, ...}
  """
  alias WireTransfer.Agent
  alias PtcRunner.SubAgent

  @doc """
  Run a wire transfer workflow.

  - `journal` — persisted journal map (empty map for first run)
  - `recipient` — transfer recipient name
  - `amount` — dollar amount to transfer
  - `opts` — optional keyword list (`:model` to override LLM model)
  """
  def run(journal \\ %{}, recipient, amount, opts \\ []) do
    agent = Agent.new()
    model = opts[:model] || LLMClient.default_model()

    llm_fn = fn input ->
      messages = [%{role: :system, content: input.system} | input.messages]

      case LLMClient.generate_text(model, messages) do
        {:ok, response} ->
          {:ok, %{content: response.content, tokens: response.tokens}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    context = %{
      "recipient" => recipient,
      "amount" => amount
    }

    SubAgent.run(agent, llm: llm_fn, context: context, journal: journal)
  end
end
