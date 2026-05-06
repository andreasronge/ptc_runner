defmodule PtcRunner.SubAgent.PtcTransportE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Phase 5 integration tests for `ptc_transport: :tool_call`.

  Run with: `mix test test/ptc_runner/sub_agent/ptc_transport_e2e_test.exs --include e2e`

  Requires `OPENROUTER_API_KEY`. Skipped cleanly without it (the test_helper
  excludes `:e2e` by default).

  Covers Scenarios 1-3 from `Plans/ptc-lisp-tool-call-transport.md` lines
  425-430. Scenario 4 (parallel-tool-call rejection + recovery) is intentionally
  not duplicated here: it is exhaustively covered by the deterministic unit test
  suite at `test/ptc_runner/sub_agent/loop/ptc_tool_call_runtime_test.exs`
  (sections "multiple native tool calls (R12)", "unknown native tool (R13)",
  and "universal pairing rule (R18)" cases (d), (e), (f)). The plan explicitly
  notes that the deterministic coverage is the scripted/mock test, and that
  real-provider coverage of "model spontaneously emits parallel tool calls" is
  flaky-by-design.

  Model: uses `haiku` (Claude Haiku 4.5 via OpenRouter) for reliable native
  tool-calling, matching the existing `text_mode_tool_calling_e2e_test.exs`
  pattern.
  """

  @moduletag :e2e

  alias PtcRunner.SubAgent

  @model "haiku"

  defp get_llm, do: PtcRunner.LLM.callback(@model)

  # Different adapters / providers emit tool-call entries in slightly
  # different shapes:
  #   - Internal canonical: %{name: "ptc_lisp_execute", args: %{...}}
  #   - OpenAI/Anthropic-via-ReqLLM: %{function: %{name: "ptc_lisp_execute"}}
  # Treat both as a `ptc_lisp_execute` invocation for assertion purposes.
  defp ptc_lisp_execute_calls(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(fn
      %{role: :assistant, tool_calls: calls} when is_list(calls) -> calls
      _ -> []
    end)
    |> Enum.filter(&ptc_lisp_execute_call?/1)
  end

  defp ptc_lisp_execute_calls(_), do: []

  defp ptc_lisp_execute_call?(%{name: "ptc_lisp_execute"}), do: true
  defp ptc_lisp_execute_call?(%{function: %{name: "ptc_lisp_execute"}}), do: true
  defp ptc_lisp_execute_call?(_), do: false

  describe "Scenario 1: single tool-call to filter/aggregate, validated structured final answer" do
    test "LLM calls ptc_lisp_execute to compute aggregates over a small dataset" do
      # Domain-blind: opaque numeric records. No prompt hints about expected
      # values or shape beyond what the signature already declares.
      records = [
        %{"id" => 1, "value" => 10, "active" => true},
        %{"id" => 2, "value" => 20, "active" => false},
        %{"id" => 3, "value" => 30, "active" => true},
        %{"id" => 4, "value" => 40, "active" => true},
        %{"id" => 5, "value" => 50, "active" => false}
      ]

      agent =
        SubAgent.new(
          prompt: """
          Operate on the actual list bound to data/records (do not redeclare or
          invent values). Compute, using the ptc_lisp_execute tool:
            - active_count: the number of records where :active is true
            - active_sum:   the sum of :value across those active records
          Then return {:active_count active_count :active_sum active_sum}.
          """,
          ptc_transport: :tool_call,
          signature:
            "(records [{id :int, value :int, active :bool}]) -> {active_count :int, active_sum :int}",
          max_turns: 5
        )

      {:ok, step} =
        SubAgent.run(agent,
          llm: get_llm(),
          context: %{"records" => records},
          collect_messages: true
        )

      # At least one ptc_lisp_execute call observed in transcript.
      calls = ptc_lisp_execute_calls(step.messages)

      assert calls != [],
             "Expected >=1 ptc_lisp_execute call; got #{length(calls)}. " <>
               "Messages: #{inspect(step.messages, limit: :infinity, printable_limit: :infinity)}"

      # Final answer matches the signature shape.
      ret = step.return
      assert is_map(ret), "Expected map return; got #{inspect(ret)}"

      active_count = ret[:active_count] || ret["active_count"]
      active_sum = ret[:active_sum] || ret["active_sum"]

      # Active records are 1, 3, 4 → count = 3, sum = 10 + 30 + 40 = 80.
      assert active_count == 3, "active_count: got #{inspect(active_count)}"
      assert active_sum == 80, "active_sum: got #{inspect(active_sum)}"
    end
  end

  describe "Scenario 2: direct answer without calling the execution tool" do
    test "simple factual prompt is answered directly with no ptc_lisp_execute call" do
      # The plan calls for "a simple prompt the LLM can answer directly". This
      # validates the direct-final-answer path (R9) through real provider
      # behavior. We instruct the model unambiguously to skip ptc_lisp_execute
      # since the question requires no computation or tool orchestration.
      agent =
        SubAgent.new(
          prompt: """
          What is the chemical symbol for water? Answer in one word.

          IMPORTANT: This question requires no computation or tool orchestration.
          Do NOT call the ptc_lisp_execute tool. Return the one-word answer
          directly as the assistant message content.
          """,
          ptc_transport: :tool_call,
          signature: "() -> :string",
          max_turns: 3
        )

      {:ok, step} =
        SubAgent.run(agent,
          llm: get_llm(),
          collect_messages: true
        )

      # Zero ptc_lisp_execute calls in history.
      calls = ptc_lisp_execute_calls(step.messages)

      assert calls == [],
             "Expected zero ptc_lisp_execute calls for a direct-answer prompt; got #{length(calls)}"

      # Final return is non-empty content.
      assert is_binary(step.return)
      assert String.length(String.trim(step.return)) > 0
      # Sanity: should mention H2O.
      assert step.return =~ ~r/h2o/i
    end
  end

  describe "Scenario 3: date/math workflow using tool-returned DateTime values" do
    test "app tool returns DateTime, program adds minutes, final answer carries computed datetime fields" do
      # App tool: takes an ISO-8601 base time and a minutes offset, returns the
      # shifted DateTime. The tool *returns* a real %DateTime{} — this is the
      # round-trip we want to exercise through the :tool_call transport boundary.
      shift_tool = {
        fn args ->
          base = args["base"]
          minutes = args["minutes"]
          {:ok, dt, _} = DateTime.from_iso8601(base)
          DateTime.add(dt, minutes * 60, :second)
        end,
        signature: "(base :string, minutes :int) -> :datetime",
        description:
          "Shift an ISO-8601 datetime forward by N minutes; returns the shifted datetime."
      }

      base_iso = "2026-05-06T12:00:00Z"

      agent =
        SubAgent.new(
          prompt: """
          You are given data/base (an ISO-8601 datetime string) and data/minutes (an integer).
          Use the shift app tool from inside a ptc_lisp_execute program to compute the
          shifted datetime, then return a map with keys :base and :shifted (both ISO-8601 strings).

          Inside the program, call the app tool as (tool/shift {:base data/base :minutes data/minutes}).
          Convert datetime values to strings with (str dt) before returning.
          """,
          ptc_transport: :tool_call,
          signature: "(base :string, minutes :int) -> {base :string, shifted :string}",
          tools: %{"shift" => shift_tool},
          max_turns: 5
        )

      {:ok, step} =
        SubAgent.run(agent,
          llm: get_llm(),
          context: %{"base" => base_iso, "minutes" => 30},
          collect_messages: true
        )

      # Round-trip worked: at least one ptc_lisp_execute call.
      calls = ptc_lisp_execute_calls(step.messages)
      assert calls != [], "Expected >=1 ptc_lisp_execute call; got 0"

      ret = step.return
      assert is_map(ret), "Expected map return; got #{inspect(ret)}"

      base_out = ret[:base] || ret["base"]
      shifted = ret[:shifted] || ret["shifted"]

      assert is_binary(base_out)
      assert is_binary(shifted)

      # The shifted value should be parseable as ISO-8601 and exactly 30 minutes
      # after the base. We don't constrain the exact string format the model
      # returns (Z vs +00:00 etc.), only the datetime semantics.
      {:ok, base_dt, _} = DateTime.from_iso8601(base_iso)
      {:ok, shifted_dt, _} = DateTime.from_iso8601(shifted)
      diff_seconds = DateTime.diff(shifted_dt, base_dt, :second)

      assert diff_seconds == 30 * 60,
             "Expected 30 minutes (1800s) between base and shifted; got #{diff_seconds}s. " <>
               "base=#{inspect(base_out)} shifted=#{inspect(shifted)}"
    end
  end

  describe "Scenario A: multi-step paginated workflow with 3+ intermediate executions" do
    test "agent pages a stateless tool until exhausted then aggregates" do
      # Stateless paginated app tool: 9 items split into 3 pages of 3.
      # Cursor is the start index. next: -1 means no more pages.
      # The agent must call this multiple times with progressing cursors and
      # then aggregate. This exercises memory threading, *1/*2/*3 history,
      # and journal/tool_cache/child_steps preservation across many real LLM
      # round-trips — none of which is exercised by Scenarios 1-3.
      items = for i <- 1..9, do: %{"id" => i, "value" => i * 10}

      page_tool = {
        fn args ->
          cursor = args["cursor"]

          if cursor >= length(items) do
            %{"items" => [], "next" => -1}
          else
            page = Enum.slice(items, cursor, 3)
            next_cursor = cursor + 3
            next = if next_cursor >= length(items), do: -1, else: next_cursor
            %{"items" => page, "next" => next}
          end
        end,
        signature: "(cursor :int) -> {items :any, next :int}",
        description:
          "Fetch a page of items starting at cursor; returns the page items and the next cursor (-1 means no more pages)."
      }

      agent =
        SubAgent.new(
          prompt: """
          You have a paginated tool (tool/page {:cursor int}) that returns
          {:items [{:id int :value int}], :next int}. The :next field is -1
          when there are no more pages.

          Fetch the pages one at a time, EACH IN A SEPARATE TURN, so you can
          confirm the next cursor before the next call. Across turns:

            Turn 1: call (tool/page {:cursor 0}) and (println ...) the result.
                    Bind the items to a memory var (e.g. (def items-1 ...)).
            Turn 2: call (tool/page {:cursor <next from turn 1>}) and println.
                    Bind to items-2.
            Turn 3: call (tool/page {:cursor <next from turn 2>}) and println.
                    Bind to items-3.
            Turn 4: now that :next is -1, concat items-1/items-2/items-3,
                    sum the :value field, and (return {:total <sum>}).

          STRICT RULES:
            - Exactly ONE (tool/page ...) call per program. Do NOT write a
              recursive helper or loop that calls tool/page multiple times in
              the same program. Each page must be its own turn so memory is
              threaded across turns.
            - Do NOT call (return ...) in the same turn as a tool call —
              you must see the returned :next value before deciding the
              next cursor.
            - Do NOT hardcode the total. Verify by paging.
          """,
          ptc_transport: :tool_call,
          signature: "() -> {total :int}",
          tools: %{"page" => page_tool},
          max_turns: 10
        )

      {:ok, step} =
        SubAgent.run(agent,
          llm: get_llm(),
          collect_messages: true
        )

      calls = ptc_lisp_execute_calls(step.messages)

      assert length(calls) >= 3,
             "expected ≥3 intermediate executions for paginated workflow; got #{length(calls)}. " <>
               "Messages: #{inspect(step.messages, limit: :infinity, printable_limit: :infinity)}"

      ret = step.return
      assert is_map(ret), "Expected map return; got #{inspect(ret)}"

      total = ret[:total] || ret["total"]
      assert total == 450, "Expected total=450 (sum 10+20+...+90); got #{inspect(total)}"
    end
  end

  describe "Scenario B: (fail v) terminates loop with error from inside a real program" do
    test "agent calls (fail ...) and returns {:error, step} with fail details" do
      # Confirms end-to-end:
      #   - The error tool-result JSON with reason: "fail" + result preview
      #     reaches the model (R23) — covered deterministically but never seen
      #     end-to-end with a real provider before this test.
      #   - The loop terminates with {:error, step} and step.fail.reason == :failed
      #     (per ptc_tool_call_runtime_test.exs lines 100-101 and 136-137).
      #   - step.fail.message is `inspect/1` of the fail value (per
      #     ptc_tool_call.ex:491: Step.error(:failed, inspect(fail_args), ...)).
      users = [
        %{"id" => 1, "name" => "Alice"},
        %{"id" => 2, "name" => "Bob"}
      ]

      agent =
        SubAgent.new(
          prompt: """
          Look up the user with :id equal to 999 in data/users. If a matching
          user is found, return {:name <name>}. If no matching user is found,
          call (fail {:reason :not_found :id 999}) to signal failure.
          """,
          ptc_transport: :tool_call,
          signature: "(users [{id :int, name :string}]) -> {name :string}",
          max_turns: 5
        )

      {:error, step} =
        SubAgent.run(agent,
          llm: get_llm(),
          context: %{"users" => users},
          collect_messages: true
        )

      # Loop terminated via (fail v) — reason atom is :failed for any
      # user-supplied fail value (see ptc_tool_call.ex Step.error(:failed, ...)).
      assert step.fail.reason == :failed,
             "Expected step.fail.reason == :failed; got #{inspect(step.fail)}"

      # The model used the execution tool rather than trying to fail directly.
      calls = ptc_lisp_execute_calls(step.messages)

      assert calls != [],
             "Expected ≥1 ptc_lisp_execute call (model must use the tool to call fail); got 0. " <>
               "Messages: #{inspect(step.messages, limit: :infinity, printable_limit: :infinity)}"

      # The fail value is inspect/1-rendered into step.fail.message. The map
      # carries `:reason :not_found`, so the inspected string must contain
      # "not_found" regardless of map ordering or string-vs-atom key form.
      assert is_binary(step.fail.message),
             "Expected step.fail.message to be a string; got #{inspect(step.fail.message)}"

      assert step.fail.message =~ "not_found",
             "Expected step.fail.message to contain 'not_found'; got #{inspect(step.fail.message)}"
    end
  end

  # Scenario 4: see @moduledoc — covered exhaustively by the Phase 4
  # deterministic unit test suite. Real-provider replication is flaky-by-design.
end
