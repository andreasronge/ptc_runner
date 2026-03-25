defmodule PtcRunner.SubAgent.StringLlmIntegrationTest do
  use ExUnit.Case, async: false

  alias PtcRunner.SubAgent

  @moduledoc """
  Integration test exercising the full SubAgent.run(agent, llm: "alias") path:
  string alias → Registry.resolve! → LLM.callback → mock adapter → result.
  """

  defmodule MockAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def call(model, _req) do
      :persistent_term.put({__MODULE__, :last_model}, model)
      {:ok, %{content: "```clojure\n42\n```", tokens: %{input: 10, output: 5}}}
    end
  end

  setup do
    prev_adapter = Application.get_env(:ptc_runner, :llm_adapter)
    Application.put_env(:ptc_runner, :llm_adapter, MockAdapter)
    :persistent_term.put({MockAdapter, :last_model}, nil)

    on_exit(fn ->
      :persistent_term.erase({MockAdapter, :last_model})

      if prev_adapter,
        do: Application.put_env(:ptc_runner, :llm_adapter, prev_adapter),
        else: Application.delete_env(:ptc_runner, :llm_adapter)
    end)

    :ok
  end

  describe "SubAgent.run with string llm" do
    test "alias resolves through registry and reaches the adapter" do
      agent = SubAgent.new(prompt: "Return 42", max_turns: 1)

      {:ok, step} = SubAgent.run(agent, llm: "haiku")

      assert step.return == 42

      assert :persistent_term.get({MockAdapter, :last_model}) ==
               "openrouter:anthropic/claude-haiku-4.5"
    end

    test "provider:alias resolves correctly" do
      agent = SubAgent.new(prompt: "Return 42", max_turns: 1)

      {:ok, step} = SubAgent.run(agent, llm: "bedrock:haiku")

      assert step.return == 42

      assert :persistent_term.get({MockAdapter, :last_model}) ==
               "amazon_bedrock:anthropic.claude-haiku-4-5-20251001-v1:0"
    end

    test "full model ID passes through" do
      agent = SubAgent.new(prompt: "Return 42", max_turns: 1)

      {:ok, step} = SubAgent.run(agent, llm: "openrouter:anthropic/claude-haiku-4.5")

      assert step.return == 42

      assert :persistent_term.get({MockAdapter, :last_model}) ==
               "openrouter:anthropic/claude-haiku-4.5"
    end
  end
end
