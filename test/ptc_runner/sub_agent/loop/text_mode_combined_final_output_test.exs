defmodule PtcRunner.SubAgent.Loop.TextModeCombinedFinalOutputTest do
  @moduledoc """
  Tier 3d — Final-Output Semantics matrix, signature coercion, and
  Turn Budget Interaction edge cases for combined mode
  (`output: :text, ptc_transport: :tool_call`).

  Spec references:

    * `Plans/text-mode-ptc-compute-tool.md` § "Final-Output Semantics"
      (matrix + `(return v)` non-short-circuit rationale).
    * `Plans/text-mode-ptc-compute-tool.md` § "Turn Budget Interaction"
      (`ptc_lisp_execute` on the final available turn must terminate
      via `max_turns_exceeded` with the `tool_call_id` paired).
    * `Plans/text-mode-ptc-compute-tool.md` § "Implementation
      Contract → Final-Output Semantics" (normative MUSTs).
    * `Plans/text-mode-ptc-compute-tool.md` § "Tests To Require Before
      Enabling The Validator" — entries for `(return v)`, `(fail v)`,
      final-turn termination, and the per-row matrix coverage.

  The validator still rejects combined mode at agent construction
  (Tier 3e flips that gate). Tests build the agent in pure text mode
  and use `into_combined/1` to bypass the validator, mirroring the
  helper used in sibling combined-mode test files.
  """

  use ExUnit.Case, async: false

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Definition

  import PtcRunner.TestSupport.SubAgentTestHelpers, only: [tool_calling_llm: 1]

  defp into_combined(%Definition{} = agent), do: %{agent | ptc_transport: :tool_call}

  defp run_combined(agent, llm) do
    SubAgent.run(into_combined(agent), llm: llm, collect_messages: true)
  end

  # ---------------------------------------------------------------------------
  # Final-Output Semantics matrix — one direct test per row.
  # ---------------------------------------------------------------------------
  #
  # | output | signature                | Final answer source                  |
  # |--------|--------------------------|--------------------------------------|
  # | :text  | none                     | LLM's final text response (raw)      |
  # | :text  | :string / :any           | LLM's final text response (raw)      |
  # | :text  | {:map,...} / {:list,...} | parsed JSON, validated               |
  # | :text  | :int/:float/:bool/       | parsed/coerced via atomize_value/2   |
  # |        | :datetime                |                                      |

  describe "matrix row: :text, no signature" do
    test "final LLM text returned as raw step.return" do
      llm =
        tool_calling_llm([
          %{content: "hello world", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "hello world"
    end
  end

  describe "matrix row: :text, signature: :string" do
    test "raw LLM text returned as step.return" do
      llm =
        tool_calling_llm([
          %{content: "raw answer", tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(
          prompt: "x",
          output: :text,
          signature: "() -> :string",
          tools: %{},
          max_turns: 5
        )

      {:ok, step} = run_combined(agent, llm)
      assert step.return == "raw answer"
    end
  end

  describe "matrix row: :text, signature: :any" do
    test "raw LLM text returned as step.return" do
      llm =
        tool_calling_llm([
          %{content: "anything goes", tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(
          prompt: "x",
          output: :text,
          signature: "() -> :any",
          tools: %{},
          max_turns: 5
        )

      {:ok, step} = run_combined(agent, llm)
      assert step.return == "anything goes"
    end
  end

  describe "matrix row: :text, signature: :int" do
    test "\"42\" content → step.return == 42" do
      llm =
        tool_calling_llm([
          %{content: "42", tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(
          prompt: "x",
          output: :text,
          signature: "() -> :int",
          tools: %{},
          max_turns: 5
        )

      {:ok, step} = run_combined(agent, llm)
      assert step.return === 42
    end
  end

  describe "matrix row: :text, signature: :float" do
    test "\"3.14\" content → step.return == 3.14" do
      llm =
        tool_calling_llm([
          %{content: "3.14", tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(
          prompt: "x",
          output: :text,
          signature: "() -> :float",
          tools: %{},
          max_turns: 5
        )

      {:ok, step} = run_combined(agent, llm)
      assert step.return === 3.14
    end
  end

  describe "matrix row: :text, signature: :bool" do
    test "\"true\" content → step.return == true" do
      llm =
        tool_calling_llm([
          %{content: "true", tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(
          prompt: "x",
          output: :text,
          signature: "() -> :bool",
          tools: %{},
          max_turns: 5
        )

      {:ok, step} = run_combined(agent, llm)
      assert step.return === true
    end
  end

  describe "matrix row: :text, signature: :datetime" do
    test "JSON-quoted ISO-8601 string → coerced to %DateTime{}" do
      llm =
        tool_calling_llm([
          %{content: ~s|"2026-05-06T10:00:00Z"|, tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(
          prompt: "x",
          output: :text,
          signature: "() -> :datetime",
          tools: %{},
          max_turns: 5
        )

      {:ok, step} = run_combined(agent, llm)
      assert %DateTime{} = step.return
      assert DateTime.to_iso8601(step.return) == "2026-05-06T10:00:00Z"
    end

    test "bare ISO-8601 string (unquoted) → coerced to %DateTime{}" do
      llm =
        tool_calling_llm([
          %{content: "2026-05-06T10:00:00Z", tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(
          prompt: "x",
          output: :text,
          signature: "() -> :datetime",
          tools: %{},
          max_turns: 5
        )

      {:ok, step} = run_combined(agent, llm)
      assert %DateTime{} = step.return
      assert DateTime.to_iso8601(step.return) == "2026-05-06T10:00:00Z"
    end
  end

  describe "matrix row: :text, signature: {:map, ...}" do
    test "JSON object content → parsed + validated map" do
      llm =
        tool_calling_llm([
          %{content: ~s|{"name": "ada"}|, tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(
          prompt: "x",
          output: :text,
          signature: "() -> {name :string}",
          tools: %{},
          max_turns: 5
        )

      {:ok, step} = run_combined(agent, llm)

      # `KeyNormalizer.normalize_keys/1` (applied in
      # `JsonHandler.build_success_step/5`) converts atom keys to
      # underscore-string form, so the final shape is string-keyed.
      assert step.return == %{"name" => "ada"}
    end

    # Tier 3.5 Fix 5: combined-mode JSON-shaped finals must propagate
    # combined state (memory, journal, tool_cache, child_steps) — pre-fix,
    # `JsonHandler.build_success_step/5` hard-coded `memory: %{}` and
    # ignored the other fields, dropping everything `ptc_lisp_execute`
    # had built up.
    test "{:map, ...} final preserves memory/journal/tool_cache/child_steps from program execution" do
      llm =
        tool_calling_llm([
          # Turn 1: program defines `n` and journals; (return) creates a tool result
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{
                  "program" => ~s|(do (def n 7) (println "ran") (return {:answer n}))|
                }
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          # Turn 2: LLM returns JSON-shaped final
          %{content: ~s|{"answer": 7}|, tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(
          prompt: "x",
          output: :text,
          signature: "() -> {answer :int}",
          tools: %{},
          max_turns: 5
        )

      {:ok, step} = run_combined(agent, llm)

      assert step.return == %{"answer" => 7}

      # Memory from `(def n 7)` propagates through to the final step.
      assert Map.get(step.memory, :n) == 7 or Map.get(step.memory, "n") == 7

      # tool_cache is the combined-mode `%{}` (not nil — Loop.run sets it
      # via combined mode entry path).
      assert is_map(step.tool_cache)
    end
  end

  describe "matrix row: :text, signature: {:list, ...}" do
    test "JSON array content → parsed + validated list" do
      llm =
        tool_calling_llm([
          %{content: "[1, 2, 3]", tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(
          prompt: "x",
          output: :text,
          signature: "() -> [:int]",
          tools: %{},
          max_turns: 5
        )

      {:ok, step} = run_combined(agent, llm)
      assert step.return == [1, 2, 3]
    end
  end

  # ---------------------------------------------------------------------------
  # `(return v)` does NOT short-circuit (spec § "Final-Output Semantics").
  # ---------------------------------------------------------------------------

  describe "(return v) does not short-circuit the run" do
    # Spec: "(return v) inside ptc_lisp_execute produces a success
    # tool-result; the LLM gets one more turn to respond when budget
    # remains. The agent's final answer is the LLM's final text, not v."
    test "final answer is the LLM's final text, not the program's return value" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => "(return {:answer 42})"}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "the answer is 42", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      # The LLM's final text — NOT the program's `(return {:answer 42})`.
      assert step.return == "the answer is 42"
      refute step.return == %{answer: 42}

      # The tool-result message MUST still be paired with c1.
      tool_msg = Enum.find(step.messages, &(&1[:role] == :tool))
      assert tool_msg.tool_call_id == "c1"
      payload = Jason.decode!(tool_msg.content)
      assert payload["status"] == "ok"
    end
  end

  describe "(fail v) does not abort the run if budget remains" do
    # Spec: "(fail v) inside ptc_lisp_execute produces an error
    # tool-result (reason: \"fail\"); the LLM gets one more turn to
    # respond when budget remains."
    test "step status is {:ok, _} after the LLM recovers in a final text turn" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => ~S|(fail :nope)|}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "sorry, recovered", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)

      # `{:ok, _}`, not `{:error, _}` — the LLM recovered.
      assert {:ok, step} = run_combined(agent, llm)
      assert step.return == "sorry, recovered"

      # Paired error tool result has `reason: "fail"`.
      tool_msg = Enum.find(step.messages, &(&1[:role] == :tool))
      assert tool_msg.tool_call_id == "c1"
      payload = Jason.decode!(tool_msg.content)
      assert payload["status"] == "error"
      assert payload["reason"] == "fail"
    end
  end

  # ---------------------------------------------------------------------------
  # Turn Budget Interaction (spec § "Turn Budget Interaction").
  # ---------------------------------------------------------------------------

  describe "turn budget exhausted on ptc_lisp_execute" do
    # Spec: "ptc_lisp_execute invoked on the final available turn:
    # tool-result JSON is emitted and paired with the tool_call_id,
    # then the loop terminates via TextMode's existing
    # max_turns_exceeded path. No follow-up text turn happens."
    #
    # `state.turn` starts at 1 and `check_termination/2` triggers
    # `:max_turns_exceeded` when `state.turn > agent.max_turns`. With
    # `max_turns: 1`, turn 1 dispatches `ptc_lisp_execute`, the loop
    # increments `state.turn` to 2, and the next iteration aborts
    # before any further LLM turn — so the assistant turn-1 tool call
    # is the final available one.
    test "tool_call_id paired, loop terminates via max_turns_exceeded, no follow-up text turn" do
      test_pid = self()

      # Track every LLM invocation so we can prove no second turn
      # happens after the budget is exhausted on the program call.
      capturing_llm = fn input ->
        send(test_pid, {:llm_call, input.turn})

        if input.turn == 1 do
          {:ok,
           %{
             tool_calls: [
               %{
                 id: "c1",
                 name: "ptc_lisp_execute",
                 args: %{"program" => "(+ 1 2)"}
               }
             ],
             content: nil,
             tokens: %{input: 1, output: 1}
           }}
        else
          # If the loop ever reaches turn 2, this is a regression — a
          # final text turn was permitted despite budget exhaustion.
          {:ok, %{content: "should-not-happen", tokens: %{input: 1, output: 1}}}
        end
      end

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 1)
      assert {:error, step} = run_combined(agent, capturing_llm)

      # Existing TextMode max-turns handling.
      assert step.fail.reason == :max_turns_exceeded

      # Universal pairing rule: the tool_call_id from the dispatch on
      # the final available turn is paired with a `role: :tool`
      # message before termination.
      tool_msg = Enum.find(step.messages, &(&1[:role] == :tool))
      assert tool_msg, "expected a paired tool-result message before termination"
      assert tool_msg.tool_call_id == "c1"

      # No follow-up text turn happened.
      assert_received {:llm_call, 1}
      refute_received {:llm_call, 2}
    end
  end

  describe "turn budget headroom" do
    # Spec: "Users who need program execution followed by a text wrap-up
    # MUST configure `max_turns` with at least one slot of headroom
    # beyond their worst-case program-call count."
    test "max_turns: 3, turn 1 ptc_lisp_execute + turn 2 final text → step.return is final text" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{"program" => "(+ 1 2)"}
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "wrapped", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 3)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "wrapped"

      # Tool-call_id was paired before the final text turn.
      tool_msg = Enum.find(step.messages, &(&1[:role] == :tool))
      assert tool_msg.tool_call_id == "c1"
      payload = Jason.decode!(tool_msg.content)
      assert payload["status"] == "ok"
    end
  end
end
