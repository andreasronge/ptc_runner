defmodule PtcRunner.TestSupport.SubAgentTestHelpers do
  @moduledoc """
  Shared test helper functions for SubAgent tests.
  """

  alias PtcRunner.SubAgent

  @doc """
  Creates a test SubAgent with default configuration.

  ## Options
  - `:mission` - Agent mission (default: "Test")
  - `:tools` - Tool map (default: %{})
  - `:max_turns` - Maximum turns (default: 2)
  - Plus any other SubAgent options (`:max_depth`, `:timeout`, etc.)

  ## Examples

      iex> agent = PtcRunner.TestSupport.SubAgentTestHelpers.test_agent()
      iex> agent.mission
      "Test"

      iex> agent = PtcRunner.TestSupport.SubAgentTestHelpers.test_agent(prompt: "Custom")
      iex> agent.mission
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
  (return {:value 42})
  ```|
  """
  def simple_return_llm do
    fn _ ->
      {:ok, ~S|```clojure
(return {:value 42})
```|}
    end
  end

  @doc """
  Creates a parent-child agent pair with the child wrapped as a tool.

  ## Options
  - `:child` - Options for the child agent (merged with `[max_turns: 1]`)
  - `:parent` - Options for the parent agent (merged with `[max_turns: 2]`)
  - `:tool` - Options passed to `SubAgent.as_tool/2`
  - `:tool_name` - Name of the child tool in parent's tool map (default: "child")

  ## Examples

      iex> %{parent: parent, child: child} = PtcRunner.TestSupport.SubAgentTestHelpers.parent_child_agents()
      iex> parent.max_turns
      2
      iex> child.max_turns
      1
  """
  def parent_child_agents(opts \\ []) do
    child_opts = Keyword.get(opts, :child, [])
    parent_opts = Keyword.get(opts, :parent, [])
    tool_opts = Keyword.get(opts, :tool, [])
    tool_name = Keyword.get(opts, :tool_name, "child")

    # Ensure child has a description for as_tool requirement
    child = test_agent(Keyword.merge([max_turns: 1, description: "Child agent"], child_opts))
    child_tool = SubAgent.as_tool(child, tool_opts)

    parent =
      test_agent(Keyword.merge([max_turns: 2, tools: %{tool_name => child_tool}], parent_opts))

    %{parent: parent, child: child, child_tool: child_tool}
  end

  @doc """
  Creates an LLM function that routes responses based on message content patterns.

  Routes are evaluated in order and the first matching pattern's response is returned.
  If no pattern matches, returns a default clojure program that calls return with nil.

  ## Arguments
  - `routes` - List of tuples defining patterns and responses:
    - `{pattern, response}` - Match when message content contains `pattern` string
    - `{{:turn, n}, response}` - Match when turn equals `n`

  ## Examples

      iex> llm = PtcRunner.TestSupport.SubAgentTestHelpers.routing_llm([
      ...>   {"Double", "```clojure\\n(* 2 data/n)\\n```"},
      ...>   {{:turn, 1}, "```clojure\\n(tool/double {:n 5})\\n```"}
      ...> ])
      iex> {:ok, response} = llm.(%{messages: [%{content: "Double 5"}], turn: 1})
      iex> response
      "```clojure\\n(* 2 data/n)\\n```"
  """
  def routing_llm(routes) do
    fn %{messages: msgs, turn: turn} ->
      content = msgs |> List.last() |> Map.get(:content)

      response =
        Enum.find_value(routes, fn
          {pattern, response} when is_binary(pattern) ->
            if content =~ pattern, do: response

          {{:turn, n}, response} when is_integer(n) ->
            if turn == n, do: response

          _ ->
            nil
        end)

      {:ok, response || ~S|```clojure
(return {:value nil})
```|}
    end
  end

  @doc """
  Creates an LLM function that returns responses in sequence for tool calling mode.

  Each response can be a map with `:tool_calls` and/or `:content` keys.
  When responses are exhausted, returns an empty JSON object.
  """
  def tool_calling_llm(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn _input ->
      resp =
        Agent.get_and_update(agent, fn
          [h | t] -> {h, t}
          [] -> {%{content: "{}", tokens: nil}, []}
        end)

      {:ok, resp}
    end
  end
end
