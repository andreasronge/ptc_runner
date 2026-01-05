defmodule PtcRunner.SubAgent.NewTest do
  use ExUnit.Case, async: true

  doctest PtcRunner.SubAgent

  alias PtcRunner.SubAgent

  describe "new/1" do
    test "creates agent with minimal valid input (just prompt)" do
      agent = SubAgent.new(prompt: "Analyze the data")
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

      agent =
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
      agent = SubAgent.new(prompt: "Test")
      assert agent.max_turns == 5
      assert agent.tools == %{}
    end

    test "raises when prompt is missing" do
      assert_raise ArgumentError, "prompt is required", fn ->
        SubAgent.new(tools: %{})
      end

      assert_raise ArgumentError, "prompt is required", fn ->
        SubAgent.new([])
      end

      assert_raise ArgumentError, "prompt is required", fn ->
        SubAgent.new(max_turns: 10)
      end
    end

    test "raises when prompt is not a string" do
      assert_raise ArgumentError, "prompt must be a string", fn ->
        SubAgent.new(prompt: 123)
      end

      assert_raise ArgumentError, "prompt must be a string", fn ->
        SubAgent.new(prompt: :atom)
      end

      assert_raise ArgumentError, "prompt must be a string", fn ->
        SubAgent.new(prompt: nil)
      end

      assert_raise ArgumentError, "prompt must be a string", fn ->
        SubAgent.new(prompt: %{})
      end
    end

    test "raises when tools is not a map" do
      assert_raise ArgumentError, "tools must be a map", fn ->
        SubAgent.new(prompt: "Test", tools: [])
      end

      assert_raise ArgumentError, "tools must be a map", fn ->
        SubAgent.new(prompt: "Test", tools: "invalid")
      end

      assert_raise ArgumentError, "tools must be a map", fn ->
        SubAgent.new(prompt: "Test", tools: 123)
      end
    end

    test "raises when max_turns is zero" do
      assert_raise ArgumentError, "max_turns must be a positive integer", fn ->
        SubAgent.new(prompt: "Test", max_turns: 0)
      end
    end

    test "raises when max_turns is negative" do
      assert_raise ArgumentError, "max_turns must be a positive integer", fn ->
        SubAgent.new(prompt: "Test", max_turns: -1)
      end
    end

    test "raises when max_turns is not an integer" do
      assert_raise ArgumentError, "max_turns must be a positive integer", fn ->
        SubAgent.new(prompt: "Test", max_turns: 5.5)
      end

      assert_raise ArgumentError, "max_turns must be a positive integer", fn ->
        SubAgent.new(prompt: "Test", max_turns: "5")
      end
    end

    test "allows llm as atom" do
      agent = SubAgent.new(prompt: "Test", llm: :haiku)
      assert agent.llm == :haiku
    end

    test "allows llm as function" do
      llm_fn = fn _input -> {:ok, "response"} end
      agent = SubAgent.new(prompt: "Test", llm: llm_fn)
      assert agent.llm == llm_fn
    end

    test "allows system_prompt as map" do
      opts = %{prefix: "Custom prefix", suffix: "Custom suffix"}
      agent = SubAgent.new(prompt: "Test", system_prompt: opts)
      assert agent.system_prompt == opts
    end

    test "allows system_prompt as function" do
      fn_opt = fn prompt -> "Modified: #{prompt}" end
      agent = SubAgent.new(prompt: "Test", system_prompt: fn_opt)
      assert agent.system_prompt == fn_opt
    end

    test "allows system_prompt as string" do
      agent = SubAgent.new(prompt: "Test", system_prompt: "Custom system prompt")
      assert agent.system_prompt == "Custom system prompt"
    end

    test "ignores unknown options (lenient per Elixir convention)" do
      agent = SubAgent.new(prompt: "Test", unknown_field: "ignored", another: 123)

      assert agent.prompt == "Test"
      # Unknown fields are simply not set in the struct
      refute Map.has_key?(agent, :unknown_field)
    end

    test "raises when mission_timeout is negative" do
      assert_raise ArgumentError, "mission_timeout must be a positive integer or nil", fn ->
        SubAgent.new(prompt: "Test", mission_timeout: -1)
      end
    end

    test "raises when mission_timeout is zero" do
      assert_raise ArgumentError, "mission_timeout must be a positive integer or nil", fn ->
        SubAgent.new(prompt: "Test", mission_timeout: 0)
      end
    end

    test "raises when mission_timeout is not an integer" do
      assert_raise ArgumentError, "mission_timeout must be a positive integer or nil", fn ->
        SubAgent.new(prompt: "Test", mission_timeout: "invalid")
      end

      assert_raise ArgumentError, "mission_timeout must be a positive integer or nil", fn ->
        SubAgent.new(prompt: "Test", mission_timeout: 5.5)
      end
    end

    test "raises when signature is not a string" do
      assert_raise ArgumentError, "signature must be a string", fn ->
        SubAgent.new(prompt: "Test", signature: 123)
      end

      assert_raise ArgumentError, "signature must be a string", fn ->
        SubAgent.new(prompt: "Test", signature: :atom)
      end

      assert_raise ArgumentError, "signature must be a string", fn ->
        SubAgent.new(prompt: "Test", signature: %{})
      end
    end

    test "raises when llm_retry is not a map" do
      assert_raise ArgumentError, "llm_retry must be a map", fn ->
        SubAgent.new(prompt: "Test", llm_retry: [])
      end

      assert_raise ArgumentError, "llm_retry must be a map", fn ->
        SubAgent.new(prompt: "Test", llm_retry: "invalid")
      end

      assert_raise ArgumentError, "llm_retry must be a map", fn ->
        SubAgent.new(prompt: "Test", llm_retry: 123)
      end
    end

    test "raises when tool_catalog is not a map" do
      assert_raise ArgumentError, "tool_catalog must be a map", fn ->
        SubAgent.new(prompt: "Test", tool_catalog: [])
      end

      assert_raise ArgumentError, "tool_catalog must be a map", fn ->
        SubAgent.new(prompt: "Test", tool_catalog: "not a map")
      end

      assert_raise ArgumentError, "tool_catalog must be a map", fn ->
        SubAgent.new(prompt: "Test", tool_catalog: :atom)
      end
    end

    test "raises when prompt_limit is not a map" do
      assert_raise ArgumentError, "prompt_limit must be a map", fn ->
        SubAgent.new(prompt: "Test", prompt_limit: [])
      end

      assert_raise ArgumentError, "prompt_limit must be a map", fn ->
        SubAgent.new(prompt: "Test", prompt_limit: :atom)
      end

      assert_raise ArgumentError, "prompt_limit must be a map", fn ->
        SubAgent.new(prompt: "Test", prompt_limit: "invalid")
      end
    end

    test "accepts description as string" do
      agent = SubAgent.new(prompt: "Test", description: "A helpful agent")
      assert agent.description == "A helpful agent"
    end

    test "accepts description as nil" do
      agent = SubAgent.new(prompt: "Test", description: nil)
      assert agent.description == nil
    end

    test "description defaults to nil" do
      agent = SubAgent.new(prompt: "Test")
      assert agent.description == nil
    end

    test "raises when description is empty string" do
      assert_raise ArgumentError, "description must be a non-empty string or nil", fn ->
        SubAgent.new(prompt: "Test", description: "")
      end
    end

    test "raises when description is not a string" do
      assert_raise ArgumentError, "description must be a string", fn ->
        SubAgent.new(prompt: "Test", description: 123)
      end

      assert_raise ArgumentError, "description must be a string", fn ->
        SubAgent.new(prompt: "Test", description: :atom)
      end

      assert_raise ArgumentError, "description must be a string", fn ->
        SubAgent.new(prompt: "Test", description: %{})
      end
    end

    test "accepts field_descriptions as map" do
      fd = %{count: "Number of items", name: "Item name"}
      agent = SubAgent.new(prompt: "Test", field_descriptions: fd)
      assert agent.field_descriptions == fd
    end

    test "accepts field_descriptions as nil" do
      agent = SubAgent.new(prompt: "Test", field_descriptions: nil)
      assert agent.field_descriptions == nil
    end

    test "field_descriptions defaults to nil" do
      agent = SubAgent.new(prompt: "Test")
      assert agent.field_descriptions == nil
    end

    test "raises when field_descriptions is not a map" do
      assert_raise ArgumentError, "field_descriptions must be a map", fn ->
        SubAgent.new(prompt: "Test", field_descriptions: [])
      end

      assert_raise ArgumentError, "field_descriptions must be a map", fn ->
        SubAgent.new(prompt: "Test", field_descriptions: "invalid")
      end

      assert_raise ArgumentError, "field_descriptions must be a map", fn ->
        SubAgent.new(prompt: "Test", field_descriptions: 123)
      end
    end

    test "accepts format_options as keyword list" do
      agent = SubAgent.new(prompt: "Test", format_options: [feedback_limit: 10])
      assert agent.format_options[:feedback_limit] == 10
    end

    test "format_options uses default values" do
      agent = SubAgent.new(prompt: "Test")
      assert agent.format_options == SubAgent.default_format_options()
      assert agent.format_options[:feedback_limit] == 10
      assert agent.format_options[:feedback_max_chars] == 512
      assert agent.format_options[:history_max_bytes] == 512
      assert agent.format_options[:result_limit] == 50
      assert agent.format_options[:result_max_chars] == 500
    end

    test "format_options merges with defaults" do
      agent = SubAgent.new(prompt: "Test", format_options: [feedback_limit: 5, result_limit: 100])
      # User overrides
      assert agent.format_options[:feedback_limit] == 5
      assert agent.format_options[:result_limit] == 100
      # Defaults preserved
      assert agent.format_options[:feedback_max_chars] == 512
      assert agent.format_options[:history_max_bytes] == 512
      assert agent.format_options[:result_max_chars] == 500
    end

    test "raises when format_options is not a keyword list" do
      assert_raise ArgumentError, "format_options must be a keyword list", fn ->
        SubAgent.new(prompt: "Test", format_options: %{feedback_limit: 10})
      end

      assert_raise ArgumentError, "format_options must be a keyword list", fn ->
        SubAgent.new(prompt: "Test", format_options: "invalid")
      end

      assert_raise ArgumentError, "format_options must be a keyword list", fn ->
        SubAgent.new(prompt: "Test", format_options: 123)
      end
    end
  end
end
