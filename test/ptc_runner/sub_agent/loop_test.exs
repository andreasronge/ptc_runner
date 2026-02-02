defmodule PtcRunner.SubAgent.LoopTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  import PtcRunner.TestSupport.SubAgentTestHelpers

  doctest Loop
  doctest Loop.LLMRetry
  doctest Loop.ResponseHandler

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
(return {:result (+ data/x data/y)})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{x: 5, y: 3})

      assert step.return == %{"result" => 8}
      assert step.fail == nil
      assert length(step.turns) == 1
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
(return {:result 42})
```|}
          _ -> {:ok, "```clojure\n99\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      assert length(step.turns) == 2
      assert step.usage.turns == 2
    end

    test "expands template placeholders with data references in prompt" do
      agent =
        SubAgent.new(
          prompt: "Process {{name}} with {{value}}",
          tools: %{},
          max_turns: 3
        )

      llm = fn %{messages: messages} ->
        first_message = hd(messages)
        assert first_message.role == :user
        # Template placeholders become ~{data/...} references
        assert first_message.content =~ "Process ~{data/name} with ~{data/value}"
        # Actual values are in the data inventory, not duplicated in mission
        assert first_message.content =~ "data/name"
        assert first_message.content =~ "data/value"
        {:ok, ~S|```clojure
(return {:value 100})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{name: "alice", value: 42})

      assert step.return == %{"value" => 100}
    end
  end

  describe "run/2 with max_turns exceeded" do
    test "returns error when max_turns exceeded" do
      agent = test_agent()

      # LLM that causes errors, forcing retries
      llm = fn %{turn: _} ->
        {:ok, "```clojure\n(int Double/POSITIVE_INFINITY)\n```"}
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
(return {:value 42})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.turns |> hd() |> Map.get(:program) == ~S|(return {:value 42})|
    end

    test "extracts code from lisp code block" do
      agent = test_agent()

      llm = fn _ ->
        {:ok, ~S|```lisp
(return {:value 42})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.turns |> hd() |> Map.get(:program) == ~S|(return {:value 42})|
    end

    test "falls back to raw s-expression" do
      agent = test_agent()

      llm = fn _ -> {:ok, ~S|(return {:value 42})|} end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.turns |> hd() |> Map.get(:program) == ~S|(return {:value 42})|
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
            {:ok, "```clojure\n(int Double/POSITIVE_INFINITY)\n```"}

          2 ->
            # Verify error was fed back
            last_message = List.last(messages)
            assert last_message.role == :user
            assert last_message.content =~ "Error:"

            {:ok, ~S|```clojure
(return {:value 42})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"value" => 42}
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
(return {:value 100})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"value" => 100}
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
(tool/get-value {:key "x"})
```|}
          2 -> {:ok, ~S|```clojure
(return {:result {:value 42}})
```|}
          _ -> {:ok, "Should not reach here"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => %{"value" => 42}}
      assert :counters.get(turn_counter, 1) == 2
    end
  end

  describe "run/2 with context and memory" do
    test "provides context via data/ namespace" do
      agent =
        SubAgent.new(
          prompt: "Use context",
          tools: %{},
          max_turns: 2
        )

      llm = fn _ ->
        {:ok, ~S|```clojure
(return {:value (get data/data "key")})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{data: %{"key" => "value"}})

      assert step.return == %{"value" => "value"}
    end

    test "makes previous turn error available as data/fail" do
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
            {:ok, "```clojure\n(int Double/POSITIVE_INFINITY)\n```"}

          2 ->
            # On turn 2, data/fail should be available
            {:ok, ~S|```clojure
(return {:fail data/fail})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      # The second turn should successfully access data/fail
      assert is_map(step.return)
      assert Map.has_key?(step.return, "fail")
      assert is_map(step.return["fail"])
      assert Map.has_key?(step.return["fail"], "reason")
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
            {:ok, "```clojure\n(int Double/POSITIVE_INFINITY)\n```"}

          2 ->
            # Turn 2 should have: user, assistant, user (error feedback)
            assert length(messages) == 3
            {:ok, ~S|```clojure
(return {:value 42})
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
(return {:value 42})
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
(return {:value 42})
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
(return {:value 42})
```|}
      end

      {:ok, _step} = Loop.run(agent, llm: llm, context: %{})
    end
  end

  describe "last expression fallback on budget exhaustion" do
    test "accepts valid expression result when budget exhausted" do
      # LLM computes correct result but doesn't use (return ...)
      agent = test_agent(max_turns: 2, signature: "{count :int}")

      llm = fn %{turn: turn} ->
        case turn do
          # Turn 1: Compute result without return
          1 -> {:ok, "```clojure\n{:count 42}\n```"}
          # Turn 2: Still doesn't use return
          2 -> {:ok, "```clojure\n{:count 42}\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"count" => 42}
      assert step.usage.fallback_used == true
    end

    test "fallback normalizes hyphenated keys to underscored" do
      # Use max_turns: 2 to actually trigger the fallback path
      # (max_turns: 1 with no retry_turns skips validation and uses normal path)
      agent = test_agent(max_turns: 2, signature: "{growth_rate :float}")

      llm = fn _ ->
        # LLM uses Clojure-style hyphenated keys
        {:ok, "```clojure\n{:growth-rate 3.14}\n```"}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      # Keys should be normalized to underscored
      assert step.return == %{"growth_rate" => 3.14}
      assert step.usage.fallback_used == true
    end

    test "fallback skips nil results (println returns nil)" do
      agent = test_agent(max_turns: 2, signature: "{value :int}")

      llm = fn %{turn: turn} ->
        case turn do
          # Turn 1: Compute valid result
          1 -> {:ok, "```clojure\n{:value 100}\n```"}
          # Turn 2: println returns nil
          2 -> {:ok, ~S|```clojure
(println "Done")
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      # Should fall back to turn 1's result (not nil from turn 2)
      assert step.return == %{"value" => 100}
      assert step.usage.fallback_used == true
    end

    test "fallback fails when result doesn't match signature" do
      # Use max_turns: 2 so we actually exhaust budget and try fallback
      # (max_turns: 1 with no retry_turns skips validation entirely)
      agent = test_agent(max_turns: 2, signature: "{name :string}")

      llm = fn _ ->
        # Result doesn't match expected signature
        {:ok, "```clojure\n{:count 42}\n```"}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :max_turns_exceeded
      assert step.usage[:fallback_used] != true
    end

    test "fallback fails when no successful turns exist" do
      agent = test_agent(max_turns: 2, signature: "{value :int}")

      llm = fn _ ->
        # All turns produce errors
        {:ok, "```clojure\n(/ 1 0)\n```"}
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :max_turns_exceeded
    end

    test "fallback uses turn.memory from successful turn" do
      agent = test_agent(max_turns: 2, signature: "{result :int}")

      llm = fn %{turn: turn} ->
        case turn do
          # Turn 1: Set memory and compute result
          1 -> {:ok, "```clojure\n(let [x 42] {:result x})\n```"}
          # Turn 2: produces an error (so turn 1's memory should be preserved)
          2 -> {:ok, "```clojure\n(int Double/POSITIVE_INFINITY)\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => 42}
      assert step.usage.fallback_used == true
    end

    test "fallback works with retry_turns > 0 (budget_exhausted)" do
      agent = test_agent(max_turns: 1, retry_turns: 1, signature: "{value :int}")

      llm = fn %{turn: turn} ->
        case turn do
          # Turn 1 (work turn): Compute result
          1 -> {:ok, "```clojure\n{:value 99}\n```"}
          # Turn 2 (retry turn): Still no return
          2 -> {:ok, "```clojure\n{:value 99}\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"value" => 99}
      assert step.usage.fallback_used == true
    end

    test "explicit return still works normally (no fallback)" do
      agent = test_agent(max_turns: 2, signature: "{value :int}")

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, "```clojure\n(return {:value 42})\n```"}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"value" => 42}
      # fallback_used should not be present when return was explicit
      assert step.usage[:fallback_used] != true
    end
  end
end
