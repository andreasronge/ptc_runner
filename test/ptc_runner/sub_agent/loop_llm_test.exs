defmodule PtcRunner.SubAgent.LoopLlmTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  describe "llm_registry support" do
    test "atom LLM resolves via registry" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      registry = %{
        test_llm: fn %{messages: _} ->
          {:ok, ~S|```clojure
(return {:result "from_registry"})
```|}
        end
      }

      {:ok, step} = Loop.run(agent, llm: :test_llm, llm_registry: registry, context: %{})

      assert step.return == %{"result" => "from_registry"}
    end

    test "function LLM works without registry" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      llm = fn %{messages: _} ->
        {:ok, ~S|```clojure
(return {:result "direct"})
```|}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"result" => "direct"}
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
  end

  describe "tool return value handling" do
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
(tool/error_tool {})
```|}

          2 ->
            # Error should be fed back (with tool_error reason)
            assert Enum.any?(messages, fn msg ->
                     msg.role == :user and msg.content =~ "Error:" and
                       msg.content =~ "something failed"
                   end)

            {:ok, ~S|```clojure
(return {:recovered true})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"recovered" => true}
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
(tool/crash_tool {})
```|}

          2 ->
            # Exception should be fed back (wrapped in execution_error)
            assert Enum.any?(messages, fn msg ->
                     msg.role == :user and msg.content =~ "tool crashed"
                   end)

            {:ok, ~S|```clojure
(return {:handled true})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{"handled" => true}
      assert :counters.get(turn_counter, 1) == 2
    end
  end

  describe "llm_retry configuration" do
    test "default behavior: no retries when llm_retry not specified" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      llm = fn _input ->
        {:error, {:http_error, 500, "Server error"}}
      end

      {:error, step} = Loop.run(agent, llm: llm)

      assert step.fail.reason == :llm_error
      assert step.fail.message =~ "LLM call failed"
    end

    test "retries on rate limit error (429) and succeeds" do
      attempt_counter = :counters.new(1, [:atomics])

      llm = fn _input ->
        :counters.add(attempt_counter, 1, 1)
        count = :counters.get(attempt_counter, 1)

        if count < 3 do
          {:error, {:http_error, 429, "Rate limited"}}
        else
          {:ok, ~S|```clojure
(return {:done true})
```|}
        end
      end

      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      {:ok, step} =
        Loop.run(agent,
          llm: llm,
          llm_retry: %{max_attempts: 5, backoff: :constant, base_delay: 1}
        )

      assert step.return["done"] == true
      assert :counters.get(attempt_counter, 1) == 3
    end

    test "retries on timeout error and succeeds" do
      attempt_counter = :counters.new(1, [:atomics])

      llm = fn _input ->
        :counters.add(attempt_counter, 1, 1)
        count = :counters.get(attempt_counter, 1)

        if count < 2 do
          {:error, :timeout}
        else
          {:ok, ~S|```clojure
(return {:success true})
```|}
        end
      end

      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      {:ok, step} =
        Loop.run(agent,
          llm: llm,
          llm_retry: %{max_attempts: 3, backoff: :constant, base_delay: 1}
        )

      assert step.return["success"] == true
      assert :counters.get(attempt_counter, 1) == 2
    end

    test "retries on server error (5xx) and succeeds" do
      attempt_counter = :counters.new(1, [:atomics])

      llm = fn _input ->
        :counters.add(attempt_counter, 1, 1)
        count = :counters.get(attempt_counter, 1)

        if count == 1 do
          {:error, {:http_error, 503, "Service unavailable"}}
        else
          {:ok, ~S|```clojure
(return {:ok true})
```|}
        end
      end

      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      {:ok, step} =
        Loop.run(agent,
          llm: llm,
          llm_retry: %{max_attempts: 3, backoff: :constant, base_delay: 1}
        )

      assert step.return["ok"] == true
      assert :counters.get(attempt_counter, 1) == 2
    end

    test "does NOT retry on client error (4xx except 429)" do
      attempt_counter = :counters.new(1, [:atomics])

      llm = fn _input ->
        :counters.add(attempt_counter, 1, 1)
        {:error, {:http_error, 400, "Bad request"}}
      end

      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      {:error, step} =
        Loop.run(agent,
          llm: llm,
          llm_retry: %{max_attempts: 3, backoff: :constant, base_delay: 1}
        )

      assert step.fail.reason == :llm_error
      # Should only attempt once, not retry
      assert :counters.get(attempt_counter, 1) == 1
    end

    test "does NOT retry on registry errors (llm_not_found)" do
      attempt_counter = :counters.new(1, [:atomics])

      llm = fn _input ->
        :counters.add(attempt_counter, 1, 1)
        {:error, {:llm_not_found, :unknown_model}}
      end

      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      {:error, step} =
        Loop.run(agent,
          llm: llm,
          llm_retry: %{max_attempts: 3, backoff: :constant, base_delay: 1}
        )

      assert step.fail.reason == :llm_error
      # Should only attempt once, not retry
      assert :counters.get(attempt_counter, 1) == 1
    end

    test "exhausts retries and fails" do
      attempt_counter = :counters.new(1, [:atomics])

      llm = fn _input ->
        :counters.add(attempt_counter, 1, 1)
        {:error, {:http_error, 500, "Server error"}}
      end

      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      {:error, step} =
        Loop.run(agent,
          llm: llm,
          llm_retry: %{max_attempts: 3, backoff: :constant, base_delay: 1}
        )

      assert step.fail.reason == :llm_error
      # Should attempt 3 times total
      assert :counters.get(attempt_counter, 1) == 3
    end

    test "exponential backoff delays correctly" do
      attempt_counter = :counters.new(1, [:atomics])
      timestamps = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn _input ->
        :counters.add(attempt_counter, 1, 1)
        Agent.update(timestamps, &[System.monotonic_time(:millisecond) | &1])
        count = :counters.get(attempt_counter, 1)

        if count < 4 do
          {:error, {:http_error, 503, "Unavailable"}}
        else
          {:ok, ~S|```clojure
(return {:done true})
```|}
        end
      end

      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      {:ok, _step} =
        Loop.run(agent,
          llm: llm,
          llm_retry: %{max_attempts: 5, backoff: :exponential, base_delay: 10}
        )

      times = Agent.get(timestamps, & &1) |> Enum.reverse()

      # Verify exponential backoff: 0ms, 10ms, 20ms, 40ms
      # Allow some tolerance for timing
      assert Enum.at(times, 1) - Enum.at(times, 0) >= 8
      assert Enum.at(times, 2) - Enum.at(times, 1) >= 18
      assert Enum.at(times, 3) - Enum.at(times, 2) >= 35

      Agent.stop(timestamps)
    end

    test "linear backoff delays correctly" do
      attempt_counter = :counters.new(1, [:atomics])
      timestamps = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn _input ->
        :counters.add(attempt_counter, 1, 1)
        Agent.update(timestamps, &[System.monotonic_time(:millisecond) | &1])
        count = :counters.get(attempt_counter, 1)

        if count < 4 do
          {:error, {:http_error, 503, "Unavailable"}}
        else
          {:ok, ~S|```clojure
(return {:done true})
```|}
        end
      end

      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      {:ok, _step} =
        Loop.run(agent,
          llm: llm,
          llm_retry: %{max_attempts: 5, backoff: :linear, base_delay: 10}
        )

      times = Agent.get(timestamps, & &1) |> Enum.reverse()

      # Verify linear backoff: 0ms, 10ms, 20ms, 30ms
      # Allow some tolerance for timing
      assert Enum.at(times, 1) - Enum.at(times, 0) >= 8
      assert Enum.at(times, 2) - Enum.at(times, 1) >= 18
      assert Enum.at(times, 3) - Enum.at(times, 2) >= 28

      Agent.stop(timestamps)
    end

    test "constant backoff delays correctly" do
      attempt_counter = :counters.new(1, [:atomics])
      timestamps = Agent.start_link(fn -> [] end) |> elem(1)

      llm = fn _input ->
        :counters.add(attempt_counter, 1, 1)
        Agent.update(timestamps, &[System.monotonic_time(:millisecond) | &1])
        count = :counters.get(attempt_counter, 1)

        if count < 3 do
          {:error, {:http_error, 503, "Unavailable"}}
        else
          {:ok, ~S|```clojure
(return {:done true})
```|}
        end
      end

      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      {:ok, _step} =
        Loop.run(agent,
          llm: llm,
          llm_retry: %{max_attempts: 5, backoff: :constant, base_delay: 15}
        )

      times = Agent.get(timestamps, & &1) |> Enum.reverse()

      # Verify constant backoff: 0ms, 15ms, 15ms
      assert Enum.at(times, 1) - Enum.at(times, 0) >= 13
      assert Enum.at(times, 2) - Enum.at(times, 1) >= 13

      Agent.stop(timestamps)
    end

    test "custom retryable_errors list respected" do
      attempt_counter = :counters.new(1, [:atomics])

      llm = fn _input ->
        :counters.add(attempt_counter, 1, 1)
        count = :counters.get(attempt_counter, 1)

        if count == 1 do
          # This would normally be retried, but not in custom list
          {:error, :timeout}
        else
          {:ok, ~S|```clojure
(return {:done true})
```|}
        end
      end

      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      {:error, step} =
        Loop.run(agent,
          llm: llm,
          llm_retry: %{
            max_attempts: 3,
            backoff: :constant,
            base_delay: 1,
            retryable_errors: [:rate_limit]
          }
        )

      assert step.fail.reason == :llm_error
      # Should only attempt once since timeout not in custom list
      assert :counters.get(attempt_counter, 1) == 1
    end

    test "max_attempts: 1 means no retries" do
      attempt_counter = :counters.new(1, [:atomics])

      llm = fn _input ->
        :counters.add(attempt_counter, 1, 1)
        {:error, {:http_error, 429, "Rate limited"}}
      end

      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      {:error, step} =
        Loop.run(agent,
          llm: llm,
          llm_retry: %{max_attempts: 1, backoff: :constant, base_delay: 1}
        )

      assert step.fail.reason == :llm_error
      # Should only attempt once, no retry
      assert :counters.get(attempt_counter, 1) == 1
    end

    test "retries do NOT consume turn budget" do
      attempt_counter = :counters.new(1, [:atomics])

      llm = fn %{turn: turn} ->
        :counters.add(attempt_counter, 1, 1)
        count = :counters.get(attempt_counter, 1)

        # First turn: retry twice then succeed
        # Second turn: return
        if turn == 1 && count < 3 do
          {:error, {:http_error, 503, "Unavailable"}}
        else
          case turn do
            1 ->
              {:ok, "```clojure\n(+ 1 1)\n```"}

            2 ->
              {:ok, ~S|```clojure
(return {:result 2})
```|}
          end
        end
      end

      agent = SubAgent.new(prompt: "Test", max_turns: 5)

      {:ok, step} =
        Loop.run(agent,
          llm: llm,
          llm_retry: %{max_attempts: 5, backoff: :constant, base_delay: 1}
        )

      assert step.return["result"] == 2
      # Turn budget should only count actual turns, not retries
      assert step.usage.turns == 2
      # But LLM was called 4 times total (2 retries on turn 1, then turn 1, then turn 2)
      assert :counters.get(attempt_counter, 1) == 4
    end
  end
end
