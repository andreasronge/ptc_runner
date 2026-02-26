defmodule PtcRunner.SubAgent.InheritedNsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "implicit closure inheritance via :self" do
    test "child can call parent's defn" do
      call_count = :counters.new(1, [:atomics])

      llm = fn %{messages: _} ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)

        code =
          case n do
            # Turn 1: define closure (result stored in memory for next turn)
            1 -> "(defn twice [x] (+ x x))"
            # Turn 2: call tool/sub — state.memory now has twice from turn 1
            2 -> "(return (tool/sub {:value 21}))"
            # Child turn: twice is inherited, call it
            _ -> "(return (twice data/value))"
          end

        {:ok, "```clojure\n#{code}\n```"}
      end

      agent =
        SubAgent.new(
          prompt: "Process {{value}}",
          signature: "(value :int) -> :int",
          tools: %{"sub" => :self},
          max_turns: 5,
          max_depth: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm, context: %{value: 0})
      assert step.return == 42
    end

    test "only closures are inherited, not plain values" do
      call_count = :counters.new(1, [:atomics])

      llm = fn %{messages: messages} ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)

        case n do
          # Turn 1: define a value and a closure
          1 ->
            {:ok, "```clojure\n(def counter 99)\n(defn id [x] x)\n```"}

          # Turn 2: call tool/sub — memory now has both counter and id
          2 ->
            {:ok, "```clojure\n(return (tool/sub {:v 1}))\n```"}

          # Child turn: id should work, counter should NOT be accessible
          3 ->
            user_msg = Enum.find(messages, &(&1.role == :user))
            assert user_msg.content =~ "(id [x])"
            refute user_msg.content =~ "counter"
            {:ok, "```clojure\n(return (id data/v))\n```"}
        end
      end

      agent =
        SubAgent.new(
          prompt: "Process",
          signature: "(v :int) -> :int",
          tools: %{"sub" => :self},
          max_turns: 5,
          max_depth: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm, context: %{v: 0})
      assert step.return == 1
    end

    test "non-self SubAgentTool does not inherit" do
      child_agent =
        SubAgent.new(
          prompt: "Return {{n}} doubled",
          signature: "(n :int) -> :int",
          max_turns: 1
        )

      child_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, &(&1.role == :user))
        # Verify: no inherited section
        refute user_msg.content =~ "inherited"
        refute user_msg.content =~ "helper"
        {:ok, "```clojure\n(+ data/n data/n)\n```"}
      end

      parent_call_count = :counters.new(1, [:atomics])

      parent_llm = fn %{messages: _} ->
        pn = :counters.get(parent_call_count, 1) + 1
        :counters.put(parent_call_count, 1, pn)

        case pn do
          1 -> {:ok, "```clojure\n(defn helper [x] x)\n```"}
          2 -> {:ok, "```clojure\n(return (tool/child {:n 5}))\n```"}
        end
      end

      parent =
        SubAgent.new(
          prompt: "Use child",
          signature: "(n :int) -> :int",
          tools: %{
            "child" => SubAgent.as_tool(child_agent, llm: child_llm, description: "Child agent")
          },
          max_turns: 5
        )

      assert {:ok, step} = SubAgent.run(parent, llm: parent_llm, context: %{n: 0})
      assert step.return == 10
    end

    test "docstrings appear in inherited section" do
      call_count = :counters.new(1, [:atomics])

      llm = fn %{messages: messages} ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)

        case n do
          1 ->
            {:ok, "```clojure\n(defn parse-line \"Extracts fields from a log line\" [s] s)\n```"}

          2 ->
            {:ok, "```clojure\n(return (tool/sub {:data \"test\"}))\n```"}

          3 ->
            user_msg = Enum.find(messages, &(&1.role == :user))
            assert user_msg.content =~ "inherited"
            assert user_msg.content =~ "parse-line"
            assert user_msg.content =~ "Extracts fields from a log line"
            {:ok, "```clojure\n(return (parse-line data/data))\n```"}
        end
      end

      agent =
        SubAgent.new(
          prompt: "Process",
          signature: "(data :string) -> :string",
          tools: %{"sub" => :self},
          max_turns: 5,
          max_depth: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm, context: %{data: "x"})
      assert step.return == "test"
    end

    test "child inherits defn defined in same turn as tool call" do
      # Reproduces the real-world pattern where the LLM defines helpers and calls
      # tool/sub in the SAME program (same turn). The child should still inherit
      # the closures defined earlier in that program.
      #
      # This is the common pattern seen in recursive agents: the LLM writes
      # (defn parse-profile ...) then calls (tool/search {:corpus subset}) in
      # a single code block.
      child_saw_inherited = :atomics.new(1, [])
      call_count = :counters.new(1, [:atomics])

      llm = fn %{messages: messages} ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)

        case n do
          1 ->
            # Parent turn 1: define closure AND call tool/sub in same program
            {:ok, "```clojure\n(defn twice [x] (+ x x))\n(return (tool/sub {:value 21}))\n```"}

          2 ->
            # Child turn: check whether inherited section is present
            user_msg = Enum.find(messages, &(&1.role == :user))

            if user_msg.content =~ "inherited" and user_msg.content =~ "twice" do
              :atomics.put(child_saw_inherited, 1, 1)
            end

            {:ok, "```clojure\n(return (twice data/value))\n```"}
        end
      end

      agent =
        SubAgent.new(
          prompt: "Process {{value}}",
          signature: "(value :int) -> :int",
          tools: %{"sub" => :self},
          max_turns: 5,
          max_depth: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm, context: %{value: 0})
      assert step.return == 42

      assert :atomics.get(child_saw_inherited, 1) == 1,
             "child prompt should contain inherited section with 'twice'"
    end

    test "internal keys are not inherited" do
      call_count = :counters.new(1, [:atomics])

      llm = fn %{messages: messages} ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)

        case n do
          1 ->
            {:ok, "```clojure\n(defn _private [x] x)\n(defn public [x] x)\n```"}

          2 ->
            {:ok, "```clojure\n(return (tool/sub {:v 1}))\n```"}

          3 ->
            user_msg = Enum.find(messages, &(&1.role == :user))
            assert user_msg.content =~ "public"
            refute user_msg.content =~ "_private"
            {:ok, "```clojure\n(return (public data/v))\n```"}
        end
      end

      agent =
        SubAgent.new(
          prompt: "Process",
          signature: "(v :int) -> :int",
          tools: %{"sub" => :self},
          max_turns: 5,
          max_depth: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm, context: %{v: 0})
      assert step.return == 1
    end
  end
end
