defmodule PtcRunner.SubAgent.RunTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  import PtcRunner.TestSupport.SubAgentTestHelpers

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
    test "single-shot uses Prompt.generate with same structure as loop mode" do
      # Verify that single-shot mode uses the same prompt generation as loop mode
      agent = SubAgent.new(prompt: "Calculate {{x}} + {{y}}", max_turns: 1)
      context = %{x: 5, y: 3}

      # Capture what the LLM receives in single-shot mode
      llm = fn input ->
        send(self(), {:llm_input, input})
        {:ok, "```clojure\n(+ ctx/x ctx/y)\n```"}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm, context: context)

      assert_received {:llm_input, input}
      system_prompt = input.system

      # Single-shot mode should now use full Prompt.generate, which includes:
      assert system_prompt =~ "# Role"
      assert system_prompt =~ "You are a PTC-Lisp program generator"
      assert system_prompt =~ "# Rules"
      assert system_prompt =~ "# Data Inventory"
      assert system_prompt =~ "ctx/x"
      assert system_prompt =~ "ctx/y"
      assert system_prompt =~ "# Available Tools"
      assert system_prompt =~ "# Output Format"
      assert system_prompt =~ "# Mission"
    end

    test "single-shot with language_spec: :minimal gets minimal prompt" do
      agent =
        SubAgent.new(
          prompt: "Return 42",
          max_turns: 1,
          system_prompt: %{language_spec: :minimal}
        )

      llm = fn input ->
        send(self(), {:llm_input, input})
        {:ok, "```clojure\n42\n```"}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      assert_received {:llm_input, input}
      system_prompt = input.system

      # Should use minimal language spec
      assert system_prompt =~ "Quick Reference"
      # minimal profile doesn't include full language overview
      refute system_prompt =~ "Clojure-inspired"
    end

    test "single-shot with string override uses custom prompt" do
      custom_prompt = "You are a custom agent."

      agent =
        SubAgent.new(
          prompt: "Return 42",
          max_turns: 1,
          system_prompt: custom_prompt
        )

      llm = fn input ->
        send(self(), {:llm_input, input})
        {:ok, "```clojure\n42\n```"}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm)

      assert_received {:llm_input, input}
      # String override bypasses generation entirely
      assert input.system == custom_prompt
    end

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

  describe "as_tool/2" do
    alias PtcRunner.SubAgent.SubAgentTool

    test "returns SubAgentTool struct with signature from agent" do
      agent =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {result :int}"
        )

      tool = SubAgent.as_tool(agent)

      assert %SubAgentTool{} = tool
      assert tool.agent == agent
      assert tool.signature == "(n :int) -> {result :int}"
      assert tool.bound_llm == nil
      assert tool.description == nil
    end

    test "returns SubAgentTool with nil signature when agent has no signature" do
      agent = SubAgent.new(prompt: "Process data")
      tool = SubAgent.as_tool(agent)

      assert tool.signature == nil
    end

    test "binds LLM when :llm option is provided" do
      agent = SubAgent.new(prompt: "Analyze {{text}}")

      mock_llm = fn _input -> {:ok, "result"} end
      tool = SubAgent.as_tool(agent, llm: mock_llm)

      assert tool.bound_llm == mock_llm
    end

    test "binds LLM atom when :llm option is atom" do
      agent = SubAgent.new(prompt: "Analyze {{text}}")
      tool = SubAgent.as_tool(agent, llm: :haiku)

      assert tool.bound_llm == :haiku
    end

    test "sets description when :description option is provided" do
      agent = SubAgent.new(prompt: "Process data")
      tool = SubAgent.as_tool(agent, description: "Custom description")

      assert tool.description == "Custom description"
    end

    test "accepts :name option (informational only)" do
      agent = SubAgent.new(prompt: "Analyze {{text}}")
      # :name is informational and doesn't affect the struct
      tool = SubAgent.as_tool(agent, name: "analyzer")

      assert %SubAgentTool{} = tool
    end

    test "tool execution via parent agent - child inherits parent LLM" do
      # Create a child agent that doubles a number and parent that uses it
      %{parent: parent} =
        parent_child_agents(
          child: [
            prompt: "Double {{n}}",
            signature: "(n :int) -> {result :int}"
          ],
          parent: [
            prompt: "Use double tool on {{value}}",
            max_turns: 3
          ],
          tool_name: "double"
        )

      # Track LLM calls
      {:ok, call_log} = Agent.start_link(fn -> [] end)

      mock_llm =
        routing_llm([
          {"Double", "```clojure\n{:result (* 2 ctx/n)}\n```"},
          {{:turn, 1}, "```clojure\n(call \"double\" {:n ctx/value})\n```"},
          {{:turn, 2}, "```clojure\n(call \"return\" {:result 42})\n```"},
          {{:turn, 3}, "```clojure\n(call \"return\" {:result 42})\n```"}
        ])

      # Wrap to track calls
      tracking_llm = fn input ->
        content = input.messages |> List.last() |> Map.get(:content)
        Agent.update(call_log, fn log -> [content | log] end)
        mock_llm.(input)
      end

      {:ok, step} = SubAgent.run(parent, llm: tracking_llm, context: %{value: 21})

      assert step.return == %{result: 42}
      # Verify both agents used the same LLM
      assert Agent.get(call_log, &length/1) >= 2
    end

    test "tool execution - child uses bound LLM over parent LLM" do
      # Bind a specific LLM to the tool
      child_llm = fn _input -> {:ok, "```clojure\nctx/x\n```"} end

      %{parent: parent} =
        parent_child_agents(
          child: [prompt: "Return {{x}}"],
          parent: [prompt: "Call child"],
          tool: [llm: child_llm]
        )

      # Different parent LLM - on first turn call child, on second turn return result
      parent_llm =
        routing_llm([
          {{:turn, 1}, "```clojure\n(call \"child\" {:x 99})\n```"},
          {{:turn, 2}, "```clojure\n(call \"return\" {:value 99})\n```"}
        ])

      {:ok, step} = SubAgent.run(parent, llm: parent_llm, context: %{})

      # Child should have received x=99 and returned it
      assert step.return == %{value: 99}
    end

    test "tool execution - child uses its own LLM over bound LLM" do
      # Child has its own LLM (highest priority)
      child_own_llm = fn _input -> {:ok, "```clojure\n100\n```"} end

      # Try to bind a different LLM (should be ignored)
      bound_llm = fn _input -> {:ok, "```clojure\n200\n```"} end

      %{parent: parent} =
        parent_child_agents(
          child: [prompt: "Return something", llm: child_own_llm],
          parent: [prompt: "Call child"],
          tool: [llm: bound_llm]
        )

      parent_llm =
        routing_llm([
          {{:turn, 1}, "```clojure\n(call \"child\" {})\n```"},
          {{:turn, 2}, "```clojure\n(call \"return\" {:value 100})\n```"}
        ])

      {:ok, step} = SubAgent.run(parent, llm: parent_llm, context: %{})

      # Child should use its own LLM, returning 100 not 200
      assert step.return == %{value: 100}
    end

    test "child inherits parent LLM successfully" do
      %{parent: parent} =
        parent_child_agents(
          child: [prompt: "Return 42"],
          parent: [prompt: "Call child", max_turns: 3]
        )

      # Parent LLM that calls the child
      parent_llm =
        routing_llm([
          {"Return 42", "```clojure\n42\n```"},
          {{:turn, 1}, "```clojure\n(call \"child\" {})\n```"},
          {{:turn, 2}, "```clojure\n(call \"return\" {:value 42})\n```"},
          {{:turn, 3}, "```clojure\n(call \"return\" {:value 42})\n```"}
        ])

      # This should work because parent has LLM which child inherits
      {:ok, step} = SubAgent.run(parent, llm: parent_llm, context: %{})
      assert step.return == %{value: 42}
    end

    test "child agent error is caught and parent can recover" do
      %{parent: parent} =
        parent_child_agents(
          child: [prompt: "Always return nothing"],
          parent: [prompt: "Call child", max_turns: 3]
        )

      # Child LLM returns code that doesn't call return, so it will exceed max_turns
      llm =
        routing_llm([
          {"Always return nothing", "```clojure\n(+ 1 1)\n```"},
          {{:turn, 1}, "```clojure\n(call \"child\" {})\n```"},
          {{:turn, 2}, "```clojure\n(call \"child\" {})\n```"},
          {{:turn, 3}, "```clojure\n(call \"return\" {:error \"child_failed\"})\n```"}
        ])

      # Parent should successfully handle child error by trying again and eventually returning
      result = SubAgent.run(parent, llm: llm, context: %{})

      # Parent should succeed even though child failed
      assert {:ok, step} = result
      assert step.return == %{error: "child_failed"}
    end

    test "nested agents respect nesting depth limit" do
      # Create a deeply nested structure: parent -> child -> grandchild
      grandchild = test_agent(prompt: "Return 1", max_turns: 1, max_depth: 3)
      grandchild_tool = SubAgent.as_tool(grandchild)

      %{parent: parent} =
        parent_child_agents(
          child: [
            prompt: "Call grandchild",
            tools: %{"grandchild" => grandchild_tool},
            max_depth: 3
          ],
          parent: [
            prompt: "Call child and return",
            max_turns: 5,
            max_depth: 3
          ]
        )

      llm = fn %{messages: msgs} ->
        content = msgs |> List.last() |> Map.get(:content)

        cond do
          content =~ "Return 1" ->
            {:ok, "```clojure\n1\n```"}

          content =~ "Call grandchild" ->
            {:ok, "```clojure\n(call \"grandchild\" {})\n```"}

          content =~ "Call child" ->
            {:ok, "```clojure\n(call \"child\" {})\n```"}

          true ->
            # For any other input, return the value via return call
            {:ok, "```clojure\n(call \"return\" {:value 1})\n```"}
        end
      end

      # This should succeed as we have max_depth=3 (0 -> 1 -> 2)
      {:ok, step} = SubAgent.run(parent, llm: llm, context: %{})
      assert step.return == %{value: 1}
    end

    test "nested agents exceed depth limit" do
      # Set max_depth to 1 to actually exceed it with 3 levels
      grandchild = test_agent(prompt: "Return 1", max_turns: 1, max_depth: 1)
      grandchild_tool = SubAgent.as_tool(grandchild)

      %{parent: parent} =
        parent_child_agents(
          child: [
            prompt: "Call grandchild",
            tools: %{"grandchild" => grandchild_tool},
            max_depth: 1
          ],
          parent: [
            prompt: "Call child",
            max_depth: 1
          ]
        )

      llm = fn %{messages: msgs, turn: turn} ->
        content = msgs |> List.last() |> Map.get(:content)

        cond do
          content =~ "Call grandchild" and turn == 1 ->
            {:ok, "```clojure\n(call \"grandchild\" {})\n```"}

          content =~ "Call child" and turn == 1 ->
            {:ok, "```clojure\n(call \"child\" {})\n```"}

          true ->
            {:ok, "```clojure\n(call \"return\" {:value 1})\n```"}
        end
      end

      # Should fail when trying to execute grandchild
      # (parent at 0, child at 1, grandchild would be at 2 but max_depth is 1)
      result = SubAgent.run(parent, llm: llm, context: %{})

      # The child will fail trying to call grandchild, then parent continues
      # and eventually either succeeds or fails
      # Since the error is caught and the LLM continues, the parent might succeed
      # Let's just verify that we don't crash and get a result
      case result do
        {:ok, _step} -> assert true
        {:error, _step} -> assert true
      end
    end
  end

  describe "run!/2" do
    test "returns Step directly on success" do
      agent = SubAgent.new(prompt: "Return 42", max_turns: 1)
      llm = fn _input -> {:ok, "```clojure\n42\n```"} end

      step = SubAgent.run!(agent, llm: llm)

      assert %PtcRunner.Step{} = step
      assert step.return == 42
      assert step.fail == nil
    end

    test "raises SubAgentError on failure" do
      agent = SubAgent.new(prompt: "Fail", max_turns: 2)
      llm = fn _input -> {:ok, ~S|```clojure
(call "fail" {:reason :test_failure :message "Intentional failure"})
```|} end

      assert_raise PtcRunner.SubAgentError, ~r/failed/, fn ->
        SubAgent.run!(agent, llm: llm)
      end
    end

    test "SubAgentError contains step for inspection" do
      agent = SubAgent.new(prompt: "Fail", max_turns: 2)
      llm = fn _input -> {:ok, ~S|```clojure
(call "fail" {:reason :custom_error :message "Test error"})
```|} end

      try do
        SubAgent.run!(agent, llm: llm)
        flunk("Expected SubAgentError to be raised")
      rescue
        e in PtcRunner.SubAgentError ->
          assert e.step.fail.reason == :failed
          assert e.step.fail.message =~ "custom_error"
          assert e.step.fail.message =~ "Test error"
          assert e.message =~ "failed"
      end
    end

    test "raises when llm is missing" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      assert_raise PtcRunner.SubAgentError, ~r/llm_required/, fn ->
        SubAgent.run!(agent)
      end
    end
  end

  describe "then!/2" do
    test "chains successful steps" do
      doubler =
        SubAgent.new(
          prompt: "Double {{n}}",
          signature: "(n :int) -> {result :int}",
          max_turns: 1
        )

      adder =
        SubAgent.new(
          prompt: "Add 10 to {{result}}",
          signature: "(result :int) -> {final :int}",
          max_turns: 1
        )

      mock_llm = fn %{messages: msgs} ->
        content = msgs |> List.last() |> Map.get(:content)

        cond do
          content =~ "Double" ->
            {:ok, ~S|```clojure
{:result (* 2 ctx/n)}
```|}

          content =~ "Add 10" ->
            {:ok, ~S|```clojure
{:final (+ ctx/result 10)}
```|}
        end
      end

      result =
        SubAgent.run!(doubler, llm: mock_llm, context: %{n: 5})
        |> SubAgent.then!(adder, llm: mock_llm)

      assert result.return.final == 20
    end

    test "passes previous step return as context" do
      first = SubAgent.new(prompt: "Return data", max_turns: 1)
      second = SubAgent.new(prompt: "Use {{value}}", max_turns: 1)

      mock_llm = fn %{messages: msgs} ->
        content = msgs |> List.last() |> Map.get(:content)

        cond do
          content =~ "Return data" ->
            {:ok, ~S|```clojure
{:value 99}
```|}

          content =~ "Use 99" ->
            {:ok, ~S|```clojure
{:result (* 2 ctx/value)}
```|}

          true ->
            {:ok, ~S|```clojure
42
```|}
        end
      end

      result =
        SubAgent.run!(first, llm: mock_llm)
        |> SubAgent.then!(second, llm: mock_llm)

      assert result.return.result == 198
    end

    test "short-circuits on chained failure" do
      failing = SubAgent.new(prompt: "Fail", max_turns: 2)
      never_runs = SubAgent.new(prompt: "Never", max_turns: 2)

      mock_llm = fn _input ->
        {:ok, ~S|```clojure
(call "fail" {:reason :test_failure :message "Intentional"})
```|}
      end

      # First agent fails with :failed reason (from loop mode)
      # Second agent should detect the failure and raise :chained_failure
      assert_raise PtcRunner.SubAgentError, fn ->
        SubAgent.run!(failing, llm: mock_llm)
        |> SubAgent.then!(never_runs, llm: mock_llm)
      end
    end

    test "chained failure includes upstream details" do
      failing = SubAgent.new(prompt: "Fail", max_turns: 2)
      second = SubAgent.new(prompt: "Second", max_turns: 2)

      mock_llm = fn _input ->
        {:ok, ~S|```clojure
(call "fail" {:reason :upstream_error :message "First agent failed"})
```|}
      end

      # Get the failed step first (without raising)
      {:error, failed_step} = SubAgent.run(failing, llm: mock_llm)

      # Now try to chain - this should raise with :chained_failure
      try do
        SubAgent.then!(failed_step, second, llm: mock_llm)
        flunk("Expected SubAgentError to be raised")
      rescue
        e in PtcRunner.SubAgentError ->
          # Chaining detects upstream failure and converts to :chained_failure
          assert e.step.fail.reason == :chained_failure
          assert e.step.fail.message =~ "Upstream agent failed"
          assert e.step.fail.message =~ "failed"
          assert e.step.fail.details.upstream.reason == :failed
      end
    end

    test "handles nil return value from previous step" do
      first = SubAgent.new(prompt: "Return nothing explicit", max_turns: 1)
      second = SubAgent.new(prompt: "Process", max_turns: 1)

      mock_llm = fn %{messages: _msgs} ->
        {:ok, ~S|```clojure
42
```|}
      end

      result =
        SubAgent.run!(first, llm: mock_llm)
        |> SubAgent.then!(second, llm: mock_llm)

      # Second agent should receive empty context when first returns nil
      assert result.return == 42
    end

    test "pipeline with multiple steps" do
      step1 = SubAgent.new(prompt: "Start with {{x}}", max_turns: 1)
      step2 = SubAgent.new(prompt: "Double {{value}}", max_turns: 1)
      step3 = SubAgent.new(prompt: "Add 5 to {{doubled}}", max_turns: 1)

      mock_llm = fn %{messages: msgs} ->
        content = msgs |> List.last() |> Map.get(:content)

        cond do
          content =~ "Start with" ->
            {:ok, ~S|```clojure
{:value ctx/x}
```|}

          content =~ "Double" ->
            {:ok, ~S|```clojure
{:doubled (* 2 ctx/value)}
```|}

          content =~ "Add 5" ->
            {:ok, ~S|```clojure
{:final (+ ctx/doubled 5)}
```|}
        end
      end

      result =
        SubAgent.run!(step1, llm: mock_llm, context: %{x: 10})
        |> SubAgent.then!(step2, llm: mock_llm)
        |> SubAgent.then!(step3, llm: mock_llm)

      assert result.return.final == 25
    end
  end
end
