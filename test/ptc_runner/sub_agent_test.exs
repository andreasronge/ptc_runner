defmodule PtcRunner.SubAgentTest do
  use ExUnit.Case, async: true

  doctest PtcRunner.SubAgent

  alias PtcRunner.SubAgent

  describe "new/1" do
    test "creates agent with minimal valid input (just prompt)" do
      assert {:ok, agent} = SubAgent.new(prompt: "Analyze the data")
      assert agent.prompt == "Analyze the data"
      assert agent.max_turns == 5
      assert agent.tools == %{}
      assert agent.signature == nil
      assert agent.tool_catalog == nil
      assert agent.prompt_limit == nil
      assert agent.mission_timeout == nil
      assert agent.llm_retry == nil
      assert agent.llm == nil
      assert agent.system_prompt == nil
    end

    test "creates agent with all fields provided" do
      email_tools = %{"list_emails" => fn _args -> [] end}

      assert {:ok, agent} =
               SubAgent.new(
                 prompt: "Find urgent emails for {{user}}",
                 signature: "(user :string) -> {count :int, _ids [:int]}",
                 tools: email_tools,
                 max_turns: 10,
                 tool_catalog: %{"reference" => "schema"},
                 prompt_limit: %{max_length: 1000},
                 mission_timeout: 60_000,
                 llm_retry: %{max_attempts: 3},
                 llm: :sonnet,
                 system_prompt: %{prefix: "You are an expert"}
               )

      assert agent.prompt == "Find urgent emails for {{user}}"
      assert agent.signature == "(user :string) -> {count :int, _ids [:int]}"
      assert agent.tools == email_tools
      assert agent.max_turns == 10
      assert agent.tool_catalog == %{"reference" => "schema"}
      assert agent.prompt_limit == %{max_length: 1000}
      assert agent.mission_timeout == 60_000
      assert agent.llm_retry == %{max_attempts: 3}
      assert agent.llm == :sonnet
      assert agent.system_prompt == %{prefix: "You are an expert"}
    end

    test "applies default values for optional fields" do
      assert {:ok, agent} = SubAgent.new(prompt: "Test")
      assert agent.max_turns == 5
      assert agent.tools == %{}
    end

    test "returns error when prompt is missing" do
      assert SubAgent.new(tools: %{}) == {:error, :missing_required_field}
      assert SubAgent.new([]) == {:error, :missing_required_field}
      assert SubAgent.new(max_turns: 10) == {:error, :missing_required_field}
    end

    test "returns error when prompt is not a string" do
      assert SubAgent.new(prompt: 123) == {:error, {:invalid_type, :prompt, :string}}
      assert SubAgent.new(prompt: :atom) == {:error, {:invalid_type, :prompt, :string}}
      assert SubAgent.new(prompt: nil) == {:error, {:invalid_type, :prompt, :string}}
      assert SubAgent.new(prompt: %{}) == {:error, {:invalid_type, :prompt, :string}}
    end

    test "returns error when tools is not a map" do
      assert SubAgent.new(prompt: "Test", tools: []) ==
               {:error, {:invalid_type, :tools, :map}}

      assert SubAgent.new(prompt: "Test", tools: "invalid") ==
               {:error, {:invalid_type, :tools, :map}}

      assert SubAgent.new(prompt: "Test", tools: 123) ==
               {:error, {:invalid_type, :tools, :map}}
    end

    test "returns error when max_turns is zero" do
      assert SubAgent.new(prompt: "Test", max_turns: 0) ==
               {:error, {:invalid_value, :max_turns, "must be positive integer"}}
    end

    test "returns error when max_turns is negative" do
      assert SubAgent.new(prompt: "Test", max_turns: -1) ==
               {:error, {:invalid_value, :max_turns, "must be positive integer"}}
    end

    test "returns error when max_turns is not an integer" do
      assert SubAgent.new(prompt: "Test", max_turns: 5.5) ==
               {:error, {:invalid_value, :max_turns, "must be positive integer"}}

      assert SubAgent.new(prompt: "Test", max_turns: "5") ==
               {:error, {:invalid_value, :max_turns, "must be positive integer"}}
    end

    test "allows llm as atom" do
      assert {:ok, agent} = SubAgent.new(prompt: "Test", llm: :haiku)
      assert agent.llm == :haiku
    end

    test "allows llm as function" do
      llm_fn = fn _input -> {:ok, "response"} end
      assert {:ok, agent} = SubAgent.new(prompt: "Test", llm: llm_fn)
      assert agent.llm == llm_fn
    end

    test "allows system_prompt as map" do
      opts = %{prefix: "Custom prefix", suffix: "Custom suffix"}
      assert {:ok, agent} = SubAgent.new(prompt: "Test", system_prompt: opts)
      assert agent.system_prompt == opts
    end

    test "allows system_prompt as function" do
      fn_opt = fn prompt -> "Modified: #{prompt}" end
      assert {:ok, agent} = SubAgent.new(prompt: "Test", system_prompt: fn_opt)
      assert agent.system_prompt == fn_opt
    end

    test "allows system_prompt as string" do
      assert {:ok, agent} = SubAgent.new(prompt: "Test", system_prompt: "Custom system prompt")
      assert agent.system_prompt == "Custom system prompt"
    end

    test "ignores unknown options (lenient per Elixir convention)" do
      assert {:ok, agent} =
               SubAgent.new(prompt: "Test", unknown_field: "ignored", another: 123)

      assert agent.prompt == "Test"
      # Unknown fields are simply not set in the struct
      refute Map.has_key?(agent, :unknown_field)
    end
  end
end
