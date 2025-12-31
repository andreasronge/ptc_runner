defmodule PtcRunner.TestSupport.SubAgentTestHelpers do
  @moduledoc """
  Shared test helper functions for SubAgent tests.
  """

  alias PtcRunner.SubAgent

  @doc """
  Creates a test SubAgent with default configuration.

  ## Options
  - `:prompt` - Agent prompt (default: "Test")
  - `:tools` - Tool map (default: %{})
  - `:max_turns` - Maximum turns (default: 2)
  - Plus any other SubAgent options (`:max_depth`, `:timeout`, etc.)

  ## Examples

      iex> agent = PtcRunner.TestSupport.SubAgentTestHelpers.test_agent()
      iex> agent.prompt
      "Test"

      iex> agent = PtcRunner.TestSupport.SubAgentTestHelpers.test_agent(prompt: "Custom")
      iex> agent.prompt
      "Custom"
  """
  def test_agent(opts \\ []) do
    defaults = [prompt: "Test", tools: %{}, max_turns: 2]
    SubAgent.new(Keyword.merge(defaults, opts))
  end

  @doc """
  Returns a simple LLM function that always returns a program calling `return` with `{:value 42}`.

  Useful for testing basic agent execution without real LLM calls.

  ## Examples

      iex> llm = PtcRunner.TestSupport.SubAgentTestHelpers.simple_return_llm()
      iex> {:ok, response} = llm.(%{})
      iex> response
      ~S|```clojure
      (call "return" {:value 42})
      ```|
  """
  def simple_return_llm do
    fn _ ->
      {:ok, ~S|```clojure
(call "return" {:value 42})
```|}
    end
  end
end
