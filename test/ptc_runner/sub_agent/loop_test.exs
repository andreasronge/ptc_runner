defmodule PtcRunner.SubAgent.LoopTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  import PtcRunner.TestSupport.SubAgentTestHelpers

  doctest Loop

  describe "run/2 with successful execution" do
    test "single turn with explicit return" do
      agent =
        SubAgent.new(
          prompt: "Calculate {{x}} + {{y}}",
          tools: %{},
          max_turns: 5
        )

      llm = fn %{messages: _} ->
        {:ok, ~S|```clojure
(call "return" {:result (+ ctx/x ctx/y)})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{x: 5, y: 3})

      assert step.return == %{result: 8}
      assert step.fail == nil
      assert length(step.trace) == 1
      assert step.usage.turns == 1
    end

    test "multi-turn loop accumulates trace" do
      turn_counter = :counters.new(1, [:atomics])

      agent =
        SubAgent.new(
          prompt: "Do calculation",
          tools: %{},
          max_turns: 5
        )

      llm = fn %{turn: turn} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, ~S|```clojure
(call "return" {:result 42})
```|}
          _ -> {:ok, "```clojure\n99\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{result: 42}
      assert length(step.trace) == 2
      assert step.usage.turns == 2
    end

    test "expands template placeholders in prompt" do
      agent =
        SubAgent.new(
          prompt: "Process {{name}} with {{value}}",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{messages: messages} ->
        first_message = hd(messages)
        assert first_message.role == :user
        assert first_message.content =~ "Process alice with 42"
        {:ok, ~S|```clojure
(call "return" {:value 100})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{name: "alice", value: 42})

      assert step.return == %{value: 100}
    end
  end

  describe "run/2 with max_turns exceeded" do
    test "returns error when max_turns exceeded" do
      agent = test_agent()

      # LLM that causes errors, forcing retries
      llm = fn %{turn: _} ->
        {:ok, "```clojure\n(/ 1 0)\n```"}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :max_turns_exceeded
      assert step.fail.message =~ "Exceeded max_turns limit of 2"
      assert step.return == nil
      assert step.usage.turns == 2
    end
  end

  describe "run/2 with LLM errors" do
    test "returns error when LLM call fails" do
      agent = test_agent(max_turns: 3)

      llm = fn _ ->
        {:error, :network_timeout}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :llm_error
      assert step.fail.message =~ "LLM call failed"
      assert step.fail.message =~ ":network_timeout"
    end
  end

  describe "response parsing" do
    test "extracts code from clojure code block" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|Here is the code:
```clojure
(call "return" {:value 42})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.trace |> hd() |> Map.get(:program) == ~S|(call "return" {:value 42})|
    end

    test "extracts code from lisp code block" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```lisp
(call "return" {:value 42})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.trace |> hd() |> Map.get(:program) == ~S|(call "return" {:value 42})|
    end

    test "falls back to raw s-expression" do
      agent = test_agent()

      llm = fn _ -> {:ok, ~S|(call "return" {:value 42})|} end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.trace |> hd() |> Map.get(:program) == ~S|(call "return" {:value 42})|
    end
  end

  describe "run/2 with execution errors" do
    test "feeds error back to LLM on Lisp execution failure" do
      turn_counter = :counters.new(1, [:atomics])

      agent =
        SubAgent.new(
          prompt: "Do calculation",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: turn, messages: messages} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 ->
            {:ok, "```clojure\n(/ 1 0)\n```"}

          2 ->
            # Verify error was fed back
            last_message = List.last(messages)
            assert last_message.role == :user
            assert last_message.content =~ "Error:"

            {:ok, ~S|```clojure
(call "return" {:value 42})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{value: 42}
      assert :counters.get(turn_counter, 1) == 2
    end

    test "feeds no-code error back to LLM" do
      turn_counter = :counters.new(1, [:atomics])

      agent =
        SubAgent.new(
          prompt: "Do calculation",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: turn, messages: messages} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 ->
            {:ok, "I cannot do that."}

          2 ->
            # Verify error was fed back
            last_message = List.last(messages)
            assert last_message.role == :user
            assert last_message.content =~ "No valid PTC-Lisp code found"

            {:ok, ~S|```clojure
(call "return" {:value 100})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{value: 100}
      assert :counters.get(turn_counter, 1) == 2
    end
  end

  describe "run/2 with tools" do
    test "multi-turn with tool execution" do
      turn_counter = :counters.new(1, [:atomics])

      tools = %{
        "get-value" => fn %{key: _k} -> %{value: 42} end
      }

      agent =
        SubAgent.new(
          prompt: "Get the value and return it",
          tools: tools,
          max_turns: 5
        )

      llm = fn %{turn: turn} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 -> {:ok, ~S|```clojure
(call "get-value" {:key "x"})
```|}
          2 -> {:ok, ~S|```clojure
(call "return" {:result {:value 42}})
```|}
          _ -> {:ok, "Should not reach here"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{result: %{value: 42}}
      assert :counters.get(turn_counter, 1) == 2
    end
  end

  describe "run/2 with context and memory" do
    test "provides context via ctx/ namespace" do
      agent =
        SubAgent.new(
          prompt: "Use context",
          tools: %{},
          max_turns: 2
        )

      llm = fn _ ->
        {:ok, ~S|```clojure
(call "return" {:value (get ctx/data "key")})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{data: %{"key" => "value"}})

      assert step.return == %{value: "value"}
    end

    test "makes previous turn error available as ctx/fail" do
      turn_counter = :counters.new(1, [:atomics])

      agent =
        SubAgent.new(
          prompt: "Handle error",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{turn: turn} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 ->
            {:ok, "```clojure\n(/ 1 0)\n```"}

          2 ->
            # On turn 2, ctx/fail should be available
            {:ok, ~S|```clojure
(call "return" {:fail ctx/fail})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      # The second turn should successfully access ctx/fail
      assert is_map(step.return)
      assert Map.has_key?(step.return, :fail)
      assert is_map(step.return.fail)
      assert Map.has_key?(step.return.fail, :reason)
      assert :counters.get(turn_counter, 1) == 2
    end
  end

  describe "run/2 message history" do
    test "builds message history across turns" do
      messages_log = Agent.start_link(fn -> [] end) |> elem(1)

      agent =
        SubAgent.new(
          prompt: "Initial prompt",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{messages: messages, turn: turn} ->
        Agent.update(messages_log, fn log -> [{turn, messages} | log] end)

        case turn do
          1 ->
            # Turn 1 should have just the user message
            assert length(messages) == 1
            assert hd(messages).role == :user
            {:ok, "```clojure\n(/ 1 0)\n```"}

          2 ->
            # Turn 2 should have: user, assistant, user (error feedback)
            assert length(messages) == 3
            {:ok, ~S|```clojure
(call "return" {:value 42})
```|}
        end
      end

      {:ok, _step} = Loop.run(agent, llm: llm, context: %{})

      log = Agent.get(messages_log, & &1) |> Enum.reverse()
      assert length(log) == 2

      # Verify turn 1 messages
      {1, turn1_messages} = Enum.at(log, 0)
      assert length(turn1_messages) == 1

      # Verify turn 2 messages
      {2, turn2_messages} = Enum.at(log, 1)
      assert length(turn2_messages) == 3
      assert Enum.at(turn2_messages, 1).role == :assistant
      assert Enum.at(turn2_messages, 2).role == :user
    end
  end

  describe "run/2 trace entries" do
    test "builds trace entries correctly" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```clojure
(call "return" {:value (+ 1 2)})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert length(step.trace) == 1

      trace_entry = hd(step.trace)
      assert trace_entry.turn == 1
      assert trace_entry.program == ~S|(call "return" {:value (+ 1 2)})|
      assert trace_entry.result == %{value: 3}
      assert trace_entry.tool_calls == []
    end
  end

  describe "run/2 usage metrics" do
    test "includes duration_ms in usage" do
      agent = test_agent()
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert is_integer(step.usage.duration_ms)
      assert step.usage.duration_ms >= 0
    end

    test "includes turn count in usage" do
      agent = test_agent(max_turns: 3)
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.usage.turns == 1
    end
  end

  describe "run/2 with llm_input structure" do
    test "provides system prompt in llm_input" do
      agent = test_agent()

      llm = fn %{system: system} ->
        assert is_binary(system)
        assert system =~ "PTC-Lisp"
        {:ok, ~S|```clojure
(call "return" {:value 42})
```|}
      end

      {:ok, _step} = Loop.run(agent, llm: llm, context: %{})
    end

    test "provides turn number in llm_input" do
      agent = test_agent(max_turns: 3)

      llm = fn %{turn: turn} ->
        assert is_integer(turn)
        assert turn >= 1
        {:ok, ~S|```clojure
(call "return" {:value 42})
```|}
      end

      {:ok, _step} = Loop.run(agent, llm: llm, context: %{})
    end

    test "provides tool_names in llm_input" do
      tools = %{
        "get-value" => fn _ -> 42 end,
        "set-value" => fn _ -> :ok end
      }

      agent = test_agent(tools: tools)

      llm = fn %{tool_names: tool_names} ->
        assert is_list(tool_names)
        assert "get-value" in tool_names
        assert "set-value" in tool_names
        {:ok, ~S|```clojure
(call "return" {:value 42})
```|}
      end

      {:ok, _step} = Loop.run(agent, llm: llm, context: %{})
    end
  end

  describe "memory limit configuration" do
    test "memory_limit field can be set" do
      agent = test_agent(memory_limit: 1000)

      assert agent.memory_limit == 1000
    end

    test "memory_limit defaults to 1MB" do
      agent = test_agent()

      assert agent.memory_limit == 1_048_576
    end

    test "memory_limit can be nil" do
      agent = test_agent(memory_limit: nil)

      assert agent.memory_limit == nil
    end

    test "memory_limit is enforced during execution" do
      turn_counter = :counters.new(1, [:atomics])

      tools = %{
        "store-large" => fn %{} ->
          # Return a large map that will exceed 200 bytes when serialized
          %{
            data:
              "this is a very long string designed to exceed the memory limit when stored in memory along with the erlang encoding overhead so we can test that the memory limit enforcement is working correctly"
          }
        end
      }

      agent =
        SubAgent.new(
          prompt: "Store large data",
          tools: tools,
          memory_limit: 200,
          max_turns: 3
        )

      llm = fn %{turn: turn} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 ->
            # Call tool that returns large data
            # The returned map will be merged into context/memory, exceeding the limit
            {:ok, ~S|```clojure
(call "store-large" {})
```|}

          _ ->
            {:ok, "Should not reach here"}
        end
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :memory_limit_exceeded
      assert step.fail.message =~ "Memory limit exceeded"
      assert step.usage.turns == 1
    end
  end

  describe "llm_registry support" do
    test "atom LLM resolves via registry" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      registry = %{
        test_llm: fn %{messages: _} ->
          {:ok, ~S|```clojure
(call "return" {:result "from_registry"})
```|}
        end
      }

      {:ok, step} = Loop.run(agent, llm: :test_llm, llm_registry: registry, context: %{})

      assert step.return == %{result: "from_registry"}
    end

    test "function LLM works without registry" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      llm = fn %{messages: _} ->
        {:ok, ~S|```clojure
(call "return" {:result "direct"})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{result: "direct"}
    end

    test "atom LLM not in registry returns error" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      registry = %{haiku: fn _ -> {:ok, ""} end}

      {:error, step} = Loop.run(agent, llm: :sonnet, llm_registry: registry, context: %{})

      assert step.fail.reason == :llm_error
      assert step.fail.message =~ "LLM :sonnet not found in registry"
      assert step.fail.message =~ "Available: [:haiku]"
    end

    test "atom LLM without registry returns error" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      {:error, step} = Loop.run(agent, llm: :haiku, context: %{})

      assert step.fail.reason == :llm_error
      assert step.fail.message =~ "llm_registry"
      assert step.fail.message =~ ":haiku"
    end

    test "invalid registry value (not a function) returns error" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      registry = %{haiku: "not a function"}

      {:error, step} = Loop.run(agent, llm: :haiku, llm_registry: registry, context: %{})

      assert step.fail.reason == :llm_error
      assert step.fail.message =~ "Registry value for :haiku is not a function/1"
    end

    @tag :skip
    test "registry is inherited by child agents" do
      # Child agent uses atom LLM
      child = SubAgent.new(prompt: "Child", max_turns: 1)

      # Parent agent calls child
      parent =
        SubAgent.new(
          prompt: "Parent",
          tools: %{"child" => SubAgent.as_tool(child)},
          max_turns: 1
        )

      registry = %{
        child_llm: fn %{messages: _} ->
          {:ok, ~S|```clojure
(call "return" {:from "child"})
```|}
        end
      }

      llm = fn %{messages: _} ->
        {:ok, ~S|```clojure
(call "return" (call "child" {}))
```|}
      end

      {:ok, step} =
        SubAgent.run(parent, llm: llm, llm_registry: registry, context: %{})

      # Child should execute successfully using registry
      assert step.return == %{from: "child"}
    end

    @tag :skip
    test "child agent with bound LLM atom uses parent's registry" do
      # Child with bound atom LLM
      child = SubAgent.new(prompt: "Child", max_turns: 1)
      child_tool = SubAgent.as_tool(child, llm: :haiku)

      parent =
        SubAgent.new(
          prompt: "Parent",
          tools: %{"child" => child_tool},
          max_turns: 1
        )

      registry = %{
        haiku: fn %{messages: _} ->
          {:ok, ~S|```clojure
(call "return" {:model "haiku"})
```|}
        end,
        sonnet: fn %{messages: _} ->
          {:ok, ~S|```clojure
(call "return" (call "child" {}))
```|}
        end
      }

      {:ok, step} =
        SubAgent.run(parent, llm: :sonnet, llm_registry: registry, context: %{})

      assert step.return == %{model: "haiku"}
    end
  end

  describe "tool_catalog enforcement" do
    test "calling a catalog-only tool returns error to LLM" do
      turn_counter = :counters.new(1, [:atomics])

      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{"real_tool" => fn _args -> %{result: "ok"} end},
          tool_catalog: %{"catalog_tool" => %{description: "For planning only"}},
          max_turns: 3
        )

      llm = fn %{messages: messages, turn: turn} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 ->
            {:ok, ~S|```clojure
(call "catalog_tool" {})
```|}

          2 ->
            # Check that error was fed back
            assert Enum.any?(messages, fn msg ->
                     msg.role == :user and
                       msg.content =~
                         "Tool 'catalog_tool' is for planning only and cannot be called"
                   end)

            {:ok, ~S|```clojure
(call "return" {:corrected true})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{corrected: true}
      assert :counters.get(turn_counter, 1) == 2
    end

    @tag :skip
    test "catalog tool with same name as real tool uses real tool" do
      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{"shared" => fn _args -> %{source: "real"} end},
          tool_catalog: %{"shared" => %{description: "Catalog version"}},
          max_turns: 1
        )

      llm = fn %{messages: _} ->
        {:ok, ~S|```clojure
(call "return" (call "shared" {}))
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      # Real tool should execute, not catalog
      assert step.return == %{source: "real"}
    end
  end

  describe "tool return value handling" do
    @tag :skip
    test "tool returning {:ok, value} unwraps value" do
      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{"ok_tool" => fn _args -> {:ok, %{data: 42}} end},
          max_turns: 3
        )

      llm = fn %{messages: _, turn: turn} ->
        case turn do
          1 ->
            {:ok, ~S|```clojure
(call "ok_tool" {})
```|}

          2 ->
            {:ok, ~S|```clojure
(call "return" mem/data)
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      # Tool returned {:ok, %{data: 42}}, which should be unwrapped to %{data: 42}
      assert step.return == 42
    end

    @tag :skip
    test "tool returning raw value passes through" do
      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{"raw_tool" => fn _args -> %{raw: true} end},
          max_turns: 3
        )

      llm = fn %{messages: _, turn: turn} ->
        case turn do
          1 ->
            {:ok, ~S|```clojure
(call "raw_tool" {})
```|}

          2 ->
            {:ok, ~S|```clojure
(call "return" mem/raw)
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == true
    end

    test "tool returning {:error, reason} raises and feeds back to LLM" do
      turn_counter = :counters.new(1, [:atomics])

      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{"error_tool" => fn _args -> {:error, "something failed"} end},
          max_turns: 3
        )

      llm = fn %{messages: messages, turn: turn} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 ->
            {:ok, ~S|```clojure
(call "error_tool" {})
```|}

          2 ->
            # Error should be fed back (wrapped in execution_error)
            assert Enum.any?(messages, fn msg ->
                     msg.role == :user and msg.content =~ "Tool error:" and
                       msg.content =~ "something failed"
                   end)

            {:ok, ~S|```clojure
(call "return" {:recovered true})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{recovered: true}
      assert :counters.get(turn_counter, 1) == 2
    end

    test "tool raising exception is caught and fed back to LLM" do
      turn_counter = :counters.new(1, [:atomics])

      agent =
        SubAgent.new(
          prompt: "Test",
          tools: %{
            "crash_tool" => fn _args -> raise RuntimeError, "tool crashed" end
          },
          max_turns: 3
        )

      llm = fn %{messages: messages, turn: turn} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 ->
            {:ok, ~S|```clojure
(call "crash_tool" {})
```|}

          2 ->
            # Exception should be fed back (wrapped in execution_error)
            assert Enum.any?(messages, fn msg ->
                     msg.role == :user and msg.content =~ "tool crashed"
                   end)

            {:ok, ~S|```clojure
(call "return" {:handled true})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{handled: true}
      assert :counters.get(turn_counter, 1) == 2
    end
  end

  describe "3-level LLM inheritance with registry" do
    @tag :skip
    test "grandchild uses bound LLM, parent and child inherit" do
      # Track which models were used
      {:ok, calls} = Agent.start_link(fn -> [] end)

      registry = %{
        haiku: fn input ->
          Agent.update(calls, &[{:haiku, input.turn} | &1])
          {:ok, ~S|(call "return" {:from "haiku"})|}
        end,
        sonnet: fn input ->
          Agent.update(calls, &[{:sonnet, input.turn} | &1])

          # Sonnet calls child on first turn
          if input.turn == 1 do
            {:ok, ~S|(call "child_tool" {})|}
          else
            {:ok, ~S|(call "return" {:from "sonnet"})|}
          end
        end
      }

      # Level 3: uses haiku (bound at as_tool)
      grandchild = SubAgent.new(prompt: "Grandchild", max_turns: 1)
      grandchild_tool = SubAgent.as_tool(grandchild, llm: :haiku)

      # Level 2: inherits from parent (will be sonnet)
      child =
        SubAgent.new(
          prompt: "Child",
          tools: %{"grandchild_tool" => grandchild_tool},
          max_turns: 1
        )

      child_tool = SubAgent.as_tool(child)

      # Level 1: uses sonnet explicitly
      parent =
        SubAgent.new(
          prompt: "Parent",
          tools: %{"child_tool" => child_tool},
          max_turns: 2
        )

      {:ok, step} = SubAgent.run(parent, llm: :sonnet, llm_registry: registry)

      call_log = Agent.get(calls, & &1) |> Enum.reverse()

      # Verify sonnet was called (parent)
      assert Enum.any?(call_log, &match?({:sonnet, _}, &1))

      # Verify haiku was called (grandchild)
      assert Enum.any?(call_log, &match?({:haiku, _}, &1))

      # The return should come from the grandchild via parent's execution
      assert step.return == %{from: "haiku"}
    end
  end
end
