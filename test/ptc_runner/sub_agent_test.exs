defmodule PtcRunner.SubAgentTest do
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
  end

  describe "new/1 - placeholder validation" do
    test "accepts when placeholders match signature parameters" do
      agent =
        SubAgent.new(
          prompt: "Find {{user}} emails with {{limit}}",
          signature: "(user :string, limit :int) -> {count :int}"
        )

      assert agent.prompt == "Find {{user}} emails with {{limit}}"
      assert agent.signature == "(user :string, limit :int) -> {count :int}"
    end

    test "accepts when no signature is provided (skip validation)" do
      agent = SubAgent.new(prompt: "Find {{user}} emails")
      assert agent.prompt == "Find {{user}} emails"
      assert agent.signature == nil
    end

    test "accepts when no placeholders in prompt" do
      agent =
        SubAgent.new(
          prompt: "Find all emails",
          signature: "(user :string) -> {count :int}"
        )

      assert agent.prompt == "Find all emails"
    end

    test "raises when placeholder not in signature" do
      assert_raise ArgumentError, "placeholders {{user}} not found in signature", fn ->
        SubAgent.new(
          prompt: "Find {{user}} emails",
          signature: "(person :string) -> {count :int}"
        )
      end
    end

    test "raises when multiple placeholders missing" do
      error_message = "placeholders {{user}}, {{sender}} not found in signature"

      assert_raise ArgumentError, error_message, fn ->
        SubAgent.new(
          prompt: "Find {{user}} emails from {{sender}}",
          signature: "(query :string) -> {count :int}"
        )
      end
    end

    test "handles placeholders with whitespace" do
      agent =
        SubAgent.new(
          prompt: "Find {{ user }} emails",
          signature: "(user :string) -> {count :int}"
        )

      assert agent.prompt == "Find {{ user }} emails"
    end

    test "ignores duplicate placeholders" do
      agent =
        SubAgent.new(
          prompt: "Find {{user}} emails for {{user}}",
          signature: "(user :string) -> {count :int}"
        )

      assert agent.prompt == "Find {{user}} emails for {{user}}"
    end

    test "validates nested placeholders like {{data.name}}" do
      # The placeholder extraction treats "data.name" as the placeholder name
      # This should fail because signature has "data", not "data.name"
      assert_raise ArgumentError, "placeholders {{data.name}} not found in signature", fn ->
        SubAgent.new(
          prompt: "Process {{data.name}}",
          signature: "(data :map) -> :string"
        )
      end
    end
  end

  describe "run/2 - error cases" do
    test "returns error when llm is missing" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      {:error, step} = SubAgent.run(agent)

      assert step.fail.reason == :llm_required
      assert step.fail.message == "llm option is required"
      assert step.return == nil
      assert is_map(step.usage)
      assert step.usage.duration_ms >= 0
    end

    test "returns error when llm is missing (with context)" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      {:error, step} = SubAgent.run(agent, context: %{x: 1})

      assert step.fail.reason == :llm_required
    end

    test "returns error when LLM call fails" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      llm = fn _input -> {:error, :network_timeout} end

      {:error, step} = SubAgent.run(agent, llm: llm)

      assert step.fail.reason == :llm_error
      assert step.fail.message =~ "LLM call failed"
      assert step.fail.message =~ "network_timeout"
    end

    test "returns error when no code found in LLM response" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      llm = fn _input -> {:ok, "Just plain text, no code"} end

      {:error, step} = SubAgent.run(agent, llm: llm)

      assert step.fail.reason == :no_code_found
      assert step.fail.message == "No PTC-Lisp code found in LLM response"
    end

    test "executes loop mode with max_turns > 1" do
      agent = SubAgent.new(prompt: "Test", max_turns: 5)
      llm = fn _input -> {:ok, ~S|```clojure
(call "return" {:value 42})
```|} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{value: 42}
      assert step.fail == nil
      assert step.usage.turns == 1
    end

    test "executes loop mode with tools" do
      agent = SubAgent.new(prompt: "Test", tools: %{"test" => fn _ -> :ok end})
      llm = fn _input -> {:ok, ~S|```clojure
(call "return" {:value 42})
```|} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{value: 42}
      assert step.fail == nil
    end
  end

  describe "run/2 - single-shot mode" do
    test "executes simple calculation" do
      agent = SubAgent.new(prompt: "Calculate 2 + 3", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(+ 2 3)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == 5
      assert step.fail == nil
      assert is_map(step.usage)
      assert step.usage.duration_ms >= 0
    end

    test "executes with template expansion" do
      agent = SubAgent.new(prompt: "Calculate {{x}} + {{y}}", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(+ ctx/x ctx/y)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{x: 10, y: 5})

      assert step.return == 15
    end

    test "executes with string keys in context" do
      agent = SubAgent.new(prompt: "Calculate {{x}} + {{y}}", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(+ ctx/x ctx/y)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{"x" => 7, "y" => 3})

      assert step.return == 10
    end

    test "handles code without markdown blocks" do
      agent = SubAgent.new(prompt: "Return 42", max_turns: 1)
      llm = fn _input -> {:ok, "(+ 40 2)"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == 42
    end

    test "handles lisp code blocks" do
      agent = SubAgent.new(prompt: "Return 42", max_turns: 1)
      llm = fn _input -> {:ok, "```lisp\n(+ 40 2)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == 42
    end

    test "propagates errors from Lisp execution" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n(/ 1 0)\n```"} end

      {:error, step} = SubAgent.run(agent, llm: llm)

      assert step.fail.reason == :execution_error
      assert step.return == nil
    end

    test "uses llm from agent struct if not in opts" do
      llm = fn _input -> {:ok, "```clojure\n99\n```"} end
      agent = SubAgent.new(prompt: "Test", llm: llm, max_turns: 1)

      {:ok, step} = SubAgent.run(agent)

      assert step.return == 99
    end

    test "opts llm overrides agent struct llm" do
      agent_llm = fn _input -> {:ok, "```clojure\n1\n```"} end
      opts_llm = fn _input -> {:ok, "```clojure\n2\n```"} end

      agent = SubAgent.new(prompt: "Test", llm: agent_llm, max_turns: 1)

      {:ok, step} = SubAgent.run(agent, llm: opts_llm)

      assert step.return == 2
    end

    test "LLM receives expanded prompt in user message" do
      agent = SubAgent.new(prompt: "Find {{item}}", max_turns: 1)

      # Capture what the LLM receives
      received_input = :erlang.make_ref()

      llm = fn input ->
        send(self(), {:llm_input, received_input, input})
        {:ok, "```clojure\n42\n```"}
      end

      SubAgent.run(agent, llm: llm, context: %{item: "treasure"})

      assert_received {:llm_input, ^received_input, input}
      assert input.system =~ "PTC-Lisp"
      assert [%{role: :user, content: "Find treasure"}] = input.messages
    end

    test "empty context uses empty map" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n42\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == 42
    end

    test "missing context key keeps placeholder unchanged" do
      agent = SubAgent.new(prompt: "Find {{missing}}", max_turns: 1)

      llm = fn %{messages: [%{content: content}]} ->
        # The missing key should remain as {{missing}}
        assert content == "Find {{missing}}"
        {:ok, "```clojure\n42\n```"}
      end

      SubAgent.run(agent, llm: llm, context: %{other: "value"})
    end
  end

  describe "run/2 - string convenience form" do
    test "creates agent from string prompt" do
      llm = fn _input -> {:ok, "```clojure\n42\n```"} end

      {:ok, step} = SubAgent.run("Return 42", max_turns: 1, llm: llm)

      assert step.return == 42
    end

    test "accepts signature in opts for string form" do
      llm = fn _input -> {:ok, "```clojure\n{:count 5}\n```"} end

      {:ok, step} =
        SubAgent.run("Count items", signature: "() -> {count :int}", max_turns: 1, llm: llm)

      assert step.return == %{count: 5}
    end

    test "accepts tools in opts for string form (triggers loop mode)" do
      tools = %{"test" => fn _ -> :ok end}
      llm = fn _input -> {:ok, ~S|```clojure
(call "return" {:value 42})
```|} end

      # This triggers loop mode
      {:ok, step} = SubAgent.run("Test", tools: tools, llm: llm)

      assert step.return == %{value: 42}
    end

    test "accepts max_turns in opts for string form" do
      llm = fn _input -> {:ok, ~S|```clojure
(call "return" {:value 42})
```|} end

      # max_turns: 2 triggers loop mode
      {:ok, step} = SubAgent.run("Test", max_turns: 2, llm: llm)

      assert step.return == %{value: 42}
    end

    test "string form with context" do
      llm = fn _input -> {:ok, "```clojure\n(+ ctx/a ctx/b)\n```"} end

      {:ok, step} =
        SubAgent.run("Add {{a}} and {{b}}", max_turns: 1, llm: llm, context: %{a: 3, b: 4})

      assert step.return == 7
    end
  end
end
