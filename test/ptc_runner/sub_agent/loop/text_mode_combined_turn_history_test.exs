defmodule PtcRunner.SubAgent.Loop.TextModeCombinedTurnHistoryTest do
  @moduledoc """
  Tier 3b — `turn_history` semantics in combined mode.

  Combined mode = `output: :text, ptc_transport: :tool_call`. The
  validator still rejects the combo at agent construction (Tier 3e
  flips that gate), so these tests build pure text-mode agents and
  switch them via `into_combined/1`.

  The contract pinned here is the bullet list under "`turn_history`
  Semantics In Combined Mode" in `Plans/text-mode-ptc-compute-tool.md`:

    * Successful intermediate `ptc_lisp_execute` results advance
      `turn_history` (the program's final expression value is pushed,
      capped at the most recent three entries, truncated via
      `ResponseHandler.truncate_for_history/1`).
    * `(return v)` does not advance.
    * `(fail v)` does not advance.
    * Native app-tool calls do not advance.
    * Direct LLM text turns do not advance.
    * Parse, runtime, and memory-rollback errors do not advance.

  Because state is internal to `Loop`, the assertions here drive the
  invariant through observable behaviour: subsequent programs can
  reach prior values via `*1`/`*2`/`*3`, and the rendered tool-result
  JSON's `"result"` field reflects the value of those reads. The
  rendered `"result"` is the `(println ...)`-style preview produced
  by `TurnFeedback.execution_feedback/3` — a string of the form
  `"user=> <inspected value>"`.
  """

  use ExUnit.Case, async: false

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Definition

  import PtcRunner.TestSupport.SubAgentTestHelpers, only: [tool_calling_llm: 1]

  defp into_combined(%Definition{} = agent), do: %{agent | ptc_transport: :tool_call}

  defp run_combined(agent, llm) do
    SubAgent.run(into_combined(agent), llm: llm, collect_messages: true)
  end

  defp ptc_lisp_call(id, program) do
    %{
      tool_calls: [
        %{id: id, name: "ptc_lisp_execute", args: %{"program" => program}}
      ],
      content: nil,
      tokens: %{input: 1, output: 1}
    }
  end

  defp tool_messages(step), do: Enum.filter(step.messages, &(&1[:role] == :tool))

  defp tool_payloads(step), do: Enum.map(tool_messages(step), &Jason.decode!(&1.content))

  # ---------------------------------------------------------------------------
  # Successful intermediate result advances turn_history
  # ---------------------------------------------------------------------------

  describe "successful intermediate result advances turn_history" do
    test "value pushed on intermediate; reachable from next program via *1" do
      llm =
        tool_calling_llm([
          ptc_lisp_call("c1", "(+ 1 2)"),
          ptc_lisp_call("c2", "*1"),
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "done"

      [p1, p2] = tool_payloads(step)
      assert p1["status"] == "ok"
      assert p1["result"] == "user=> 3"

      # Second program returns *1, which must equal program-1's final value (3).
      assert p2["status"] == "ok"
      assert p2["result"] == "user=> 3"
    end
  end

  # ---------------------------------------------------------------------------
  # (return v) is non-advancing
  # ---------------------------------------------------------------------------

  describe "(return v) does NOT advance turn_history" do
    test "follow-up program sees nil for *1" do
      llm =
        tool_calling_llm([
          ptc_lisp_call("c1", "(return {:value 42})"),
          ptc_lisp_call("c2", "*1"),
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "done"

      [_p1, p2] = tool_payloads(step)
      assert p2["status"] == "ok"
      # No prior advance means *1 evaluates to nil; result is omitted.
      refute Map.has_key?(p2, "result")
    end

    test "(return v) following a successful intermediate keeps prior *1 in place" do
      llm =
        tool_calling_llm([
          ptc_lisp_call("c1", "(+ 4 5)"),
          ptc_lisp_call("c2", "(return {:answer 100})"),
          ptc_lisp_call("c3", "*1"),
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 6)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "done"

      [_p1, _p2, p3] = tool_payloads(step)
      # Program 2's (return ...) did not push 100. Program 1's 9 is still
      # the most recent entry, so *1 in program 3 reads 9.
      assert p3["result"] == "user=> 9"
    end
  end

  # ---------------------------------------------------------------------------
  # (fail v) is non-advancing
  # ---------------------------------------------------------------------------

  describe "(fail v) does NOT advance turn_history" do
    test "follow-up program sees nil for *1" do
      llm =
        tool_calling_llm([
          ptc_lisp_call("c1", ~S|(fail "boom")|),
          ptc_lisp_call("c2", "*1"),
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      [_p1, p2] = tool_payloads(step)
      assert p2["status"] == "ok"
      refute Map.has_key?(p2, "result")
    end

    test "(fail v) following an intermediate keeps prior *1 in place" do
      llm =
        tool_calling_llm([
          ptc_lisp_call("c1", "(+ 10 20)"),
          ptc_lisp_call("c2", ~S|(fail "boom")|),
          ptc_lisp_call("c3", "*1"),
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 6)
      {:ok, step} = run_combined(agent, llm)

      [_p1, _p2, p3] = tool_payloads(step)
      assert p3["result"] == "user=> 30"
    end
  end

  # ---------------------------------------------------------------------------
  # Native app-tool calls do NOT advance
  # ---------------------------------------------------------------------------

  describe "native app-tool dispatch does NOT advance turn_history" do
    test "native call between programs leaves *1 pinned to last program value" do
      tools = %{
        "search" => {fn _ -> [%{"id" => 7}] end, signature: "(q :string) -> [:any]"}
      }

      llm =
        tool_calling_llm([
          ptc_lisp_call("c1", "(+ 1 2)"),
          %{
            tool_calls: [%{id: "n1", name: "search", args: %{"q" => "x"}}],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          ptc_lisp_call("c2", "*1"),
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 6)
      {:ok, step} = run_combined(agent, llm)

      [p1, _native, p3] = tool_payloads(step)
      assert p1["result"] == "user=> 3"
      # *1 still reads program 1's value (3); native call did not push.
      assert p3["result"] == "user=> 3"
    end
  end

  # ---------------------------------------------------------------------------
  # Direct LLM text turn does NOT advance
  # ---------------------------------------------------------------------------

  describe "direct LLM text turn does NOT advance turn_history" do
    test "content-only assistant turn terminates without producing a tool entry" do
      # When the LLM emits a content-only response (no tool calls), the
      # combined-mode loop terminates with that content as the final
      # answer. The invariant we care about: no tool message was
      # produced (so no path through `ptc_lisp_execute` could have
      # pushed a turn-history entry from this turn).
      llm =
        tool_calling_llm([
          %{content: "thinking out loud", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 6)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "thinking out loud"
      assert tool_messages(step) == []
    end

    test "assistant text BEFORE first program leaves *1 nil in that program" do
      # The combined-mode loop terminates on a content-only turn. To
      # verify a text turn does not somehow pre-seed turn_history, we
      # observe that a fresh agent with no prior programs sees `*1`
      # evaluate to nil (omitted from rendered "result").
      llm =
        tool_calling_llm([
          ptc_lisp_call("c1", "*1"),
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      [p1] = tool_payloads(step)
      assert p1["status"] == "ok"
      refute Map.has_key?(p1, "result")
    end
  end

  # ---------------------------------------------------------------------------
  # Error paths do NOT advance
  # ---------------------------------------------------------------------------

  describe "parse error does NOT advance turn_history" do
    test "follow-up program reads nil from *1" do
      llm =
        tool_calling_llm([
          ptc_lisp_call("c1", "((((not balanced"),
          ptc_lisp_call("c2", "*1"),
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      [p1, p2] = tool_payloads(step)
      assert p1["status"] == "error"
      assert p1["reason"] == "parse_error"

      assert p2["status"] == "ok"
      refute Map.has_key?(p2, "result")
    end

    test "parse error after a successful intermediate keeps prior *1 intact" do
      llm =
        tool_calling_llm([
          ptc_lisp_call("c1", "(+ 1 2)"),
          ptc_lisp_call("c2", "((((nope"),
          ptc_lisp_call("c3", "*1"),
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 6)
      {:ok, step} = run_combined(agent, llm)

      [_p1, p2, p3] = tool_payloads(step)
      assert p2["status"] == "error"
      assert p2["reason"] == "parse_error"

      # turn_history still pinned to 3 from program 1.
      assert p3["result"] == "user=> 3"
    end
  end

  describe "runtime error does NOT advance turn_history" do
    test "follow-up program reads nil from *1" do
      llm =
        tool_calling_llm([
          ptc_lisp_call("c1", "(undefined-fn 1 2)"),
          ptc_lisp_call("c2", "*1"),
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      [p1, p2] = tool_payloads(step)
      assert p1["status"] == "error"
      assert p1["reason"] in ["runtime_error", "parse_error"]

      assert p2["status"] == "ok"
      refute Map.has_key?(p2, "result")
    end
  end

  describe "memory-limit rollback does NOT advance turn_history" do
    test "rollback continues, but *1 stays at last successful intermediate" do
      llm =
        tool_calling_llm([
          ptc_lisp_call("c1", "(+ 7 8)"),
          ptc_lisp_call("c2", "(def big (str (range 0 1000)))"),
          ptc_lisp_call("c3", "*1"),
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent =
        SubAgent.new(
          prompt: "x",
          output: :text,
          tools: %{},
          max_turns: 6,
          memory_limit: 100,
          memory_strategy: :rollback
        )

      {:ok, step} = run_combined(agent, llm)

      [_p1, p2, p3] = tool_payloads(step)
      assert p2["status"] == "error"
      assert p2["reason"] == "memory_limit"

      # turn_history still pinned to program 1's value (15); rollback
      # did not push a new entry.
      assert p3["result"] == "user=> 15"
    end
  end

  # ---------------------------------------------------------------------------
  # Cap at last 3
  # ---------------------------------------------------------------------------

  describe "turn_history cap at last 3" do
    test "five intermediate calls; *1/*2/*3 reflect only the last three" do
      llm =
        tool_calling_llm([
          ptc_lisp_call("c1", "100"),
          ptc_lisp_call("c2", "200"),
          ptc_lisp_call("c3", "300"),
          ptc_lisp_call("c4", "400"),
          ptc_lisp_call("c5", "500"),
          ptc_lisp_call("c6", "[*1 *2 *3]"),
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 8)
      {:ok, step} = run_combined(agent, llm)

      payloads = tool_payloads(step)
      assert length(payloads) == 6

      last = List.last(payloads)
      assert last["status"] == "ok"
      # *1 is most recent (500), *2 is 400, *3 is 300. Earlier
      # intermediates (100, 200) have aged out.
      assert last["result"] == "user=> [500 400 300]"
    end
  end

  # ---------------------------------------------------------------------------
  # Truncation parity with v1 :tool_call
  # ---------------------------------------------------------------------------

  describe "ResponseHandler.truncate_for_history/1 applied to advanced entries" do
    test "very large string is truncated when read back via *1" do
      # 5_000 chars >> the 1024-byte default cap in
      # ResponseHandler.truncate_for_history/1; the entry written into
      # turn_history must be truncated, so the next program reading *1
      # observes a shorter string. The exact post-truncation length
      # is implementation-defined (binary external_size accounting),
      # but it must be much smaller than 5_000.
      big_program = ~s|(apply str (repeat 5000 "x"))|

      llm =
        tool_calling_llm([
          ptc_lisp_call("c1", big_program),
          ptc_lisp_call("c2", "(count *1)"),
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      [_p1, p2] = tool_payloads(step)
      assert p2["status"] == "ok"

      # The rendered "result" is `"user=> <integer>"`. Parse it back to
      # confirm truncation happened (count well under 5_000 and within
      # the truncation budget).
      "user=> " <> count_str = p2["result"]
      count = String.to_integer(count_str)
      assert count < 5_000
      assert count <= 1_024
    end
  end
end
