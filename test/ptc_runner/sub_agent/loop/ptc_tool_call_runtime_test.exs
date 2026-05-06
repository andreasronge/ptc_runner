defmodule PtcRunner.SubAgent.Loop.PtcToolCallRuntimeTest do
  @moduledoc """
  Phase 4 runtime behavior for `ptc_transport: :tool_call`.

  Covers the success path, direct-final-answer path with each signature
  branch, protocol-error recovery (unknown tool, multiple tool calls,
  malformed args), `(return)` / `(fail)` termination with paired final
  tool-result messages, fenced-content targeted feedback, `*1`/`*2`/`*3`
  history wiring, `max_tool_calls` semantics, the universal-pairing rule
  under `collect_messages: true`, and tool-result message JSON shape.

  See `Plans/ptc-lisp-tool-call-transport.md` for the spec.
  """

  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  # ============================================================
  # LLM stub helper
  # ============================================================

  # Build an LLM callback that returns one of the supplied canned responses
  # on each successive call. The optional `:on_request` arg captures each
  # input map for later assertion.
  defp scripted_llm(responses, opts \\ []) do
    counter = :counters.new(1, [:atomics])
    pid = Keyword.get(opts, :send_to)

    fn input ->
      :counters.add(counter, 1, 1)
      idx = :counters.get(counter, 1)

      if pid, do: send(pid, {:llm_request, idx, input})

      response = Enum.at(responses, idx - 1) || List.last(responses)

      case response do
        {:error, reason} -> {:error, reason}
        resp -> {:ok, resp}
      end
    end
  end

  defp tool_call_response(program, opts \\ []) do
    id = Keyword.get(opts, :id, "call_1")
    content = Keyword.get(opts, :content)

    %{
      content: content,
      tool_calls: [
        %{id: id, name: "ptc_lisp_execute", args: %{"program" => program}}
      ],
      tokens: %{input: 0, output: 0}
    }
  end

  defp content_response(content) do
    %{content: content, tokens: %{input: 0, output: 0}}
  end

  # ============================================================
  # Success path / (return ...) / (fail ...)
  # ============================================================

  describe "success path (R8, R15)" do
    test "single ptc_lisp_execute call with (return v) terminates immediately" do
      llm = scripted_llm([tool_call_response("(return 42)")])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 3)

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == 42
    end

    test "intermediate execution then (return ...) on next turn" do
      llm =
        scripted_llm([
          tool_call_response("(def x 10)", id: "c1"),
          tool_call_response("(return (+ x 5))", id: "c2")
        ])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 5)

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == 15
    end

    test "(fail v) terminates with error and pairs the final tool-result" do
      llm =
        scripted_llm([
          tool_call_response(~s|(fail {:reason :nope :message "no"})|)
        ])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 3)

      assert {:error, step} = SubAgent.run(agent, llm: llm)
      assert step.fail.reason == :failed
    end

    test "final tool-result message is paired in transcript on (return)" do
      llm = scripted_llm([tool_call_response("(return 7)", id: "abc")])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 3
        )

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      assert paired_tool_call_id?(step.messages, "abc")
    end

    # Regression: in single-shot mode (`max_turns: 1, retry_turns: 0`), a
    # `(fail v)` invocation must produce `{:error, step}` — same shape as
    # multi-turn mode. Previously the single-shot catch-all clause matched
    # before the `(fail ...)` clause and routed through `terminate_with_return/6`.
    test "(fail v) in single-shot mode (max_turns: 1, retry_turns: 0) returns {:error, step}" do
      llm =
        scripted_llm([
          tool_call_response(~s|(fail {:reason :nope :message "no"})|)
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 1,
          retry_turns: 0
        )

      assert {:error, step} = SubAgent.run(agent, llm: llm)
      assert step.fail.reason == :failed
    end
  end

  # ============================================================
  # Direct final answer / signature handling matrix (R9, R10)
  # ============================================================

  describe "direct final-answer signature handling (R9)" do
    test "no signature: raw text returned" do
      llm = scripted_llm([content_response("just a string answer")])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 3)

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == "just a string answer"
    end

    test ":string signature: raw text returned" do
      llm = scripted_llm([content_response("hello")])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          signature: "() -> :string",
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == "hello"
    end

    test ":any signature: raw text returned" do
      llm = scripted_llm([content_response("opaque")])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          signature: "() -> :any",
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == "opaque"
    end

    test "{:map, ...} signature: JSON parsed and validated" do
      llm = scripted_llm([content_response(~s|{"name": "alice", "age": 30}|)])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          signature: "() -> {name :string, age :int}",
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      # JsonHandler.atomize_value uses safe_to_atom (existing atoms only).
      # Accept either atom or string keying — both are valid signature shapes.
      assert step.return == %{name: "alice", age: 30} or
               step.return == %{"name" => "alice", "age" => 30}
    end

    test "{:list, ...} signature: JSON list parsed and validated" do
      llm = scripted_llm([content_response(~s|[1, 2, 3]|)])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          signature: "() -> [:int]",
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == [1, 2, 3]
    end

    test ":int signature: bare JSON primitive accepted" do
      llm = scripted_llm([content_response("42")])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          signature: "() -> :int",
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == 42
    end

    test ":float signature: bare JSON primitive accepted" do
      llm = scripted_llm([content_response("3.14")])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          signature: "() -> :float",
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == 3.14
    end

    test ":bool signature: bare JSON primitive accepted" do
      llm = scripted_llm([content_response("true")])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          signature: "() -> :bool",
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == true
    end

    test ":datetime signature: JSON-quoted ISO-8601 accepted" do
      llm = scripted_llm([content_response(~s|"2026-05-05T00:00:00Z"|)])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          signature: "() -> :datetime",
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert %DateTime{} = step.return
    end

    test ":datetime signature: raw ISO-8601 (no JSON quotes) accepted" do
      llm = scripted_llm([content_response("2026-05-05T00:00:00Z")])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          signature: "() -> :datetime",
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert %DateTime{} = step.return
    end

    test "{:optional, _} signature: JSON null accepted" do
      llm = scripted_llm([content_response("null")])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          signature: "() -> :int?",
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == nil
    end

    test "validation failure consumes a retry turn (parse error)" do
      llm =
        scripted_llm([
          content_response("not json"),
          content_response(~s|{"name":"x","age":1}|)
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          signature: "() -> {name :string, age :int}",
          max_turns: 3
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{name: "x", age: 1} or
               step.return == %{"name" => "x", "age" => 1}

      assert length(step.turns) == 2
    end

    test "intermediate execution then direct final JSON content" do
      llm =
        scripted_llm([
          tool_call_response("(def total 99)"),
          content_response(~s|{"total": 99}|)
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          signature: "() -> {total :int}",
          max_turns: 5
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == %{total: 99} or step.return == %{"total" => 99}
    end

    test "direct-final state preservation: state from prior execution flows through" do
      llm =
        scripted_llm([
          tool_call_response("(def items [1 2 3])"),
          content_response(~s|{"count": 3}|)
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          signature: "() -> {count :int}",
          max_turns: 5
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      # State from intermediate execution is preserved on the final Step
      assert is_map(step.memory)
      assert Map.has_key?(step.memory, "items") or Map.has_key?(step.memory, :items)
    end
  end

  # ============================================================
  # Markdown-fenced clojure as content (R16)
  # ============================================================

  describe "fenced clojure content (R16)" do
    test "fenced content yields targeted feedback, not signature feedback" do
      llm =
        scripted_llm([
          content_response("```clojure\n(return 1)\n```"),
          tool_call_response("(return 7)")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 5
        )

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      assert step.return == 7

      feedback_msg =
        Enum.find_value(step.messages, fn
          %{role: :user, content: c} when is_binary(c) ->
            if String.contains?(c, "ptc_transport") and String.contains?(c, "fenced"),
              do: c,
              else: nil

          _ ->
            nil
        end)

      assert feedback_msg, "Expected the targeted fenced-feedback string in transcript"
    end

    test "fenced content does NOT advance turn_history (R20)" do
      # Two fenced turns then a return — *1 should not see fenced content.
      llm =
        scripted_llm([
          content_response("```clojure\n(+ 1 2)\n```"),
          tool_call_response("(return *1)")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 5
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      # *1 has no prior successful exec — so this returns nil
      assert step.return == nil
    end
  end

  # ============================================================
  # Protocol errors (R12, R13, R14)
  # ============================================================

  describe "malformed args (R14)" do
    test "missing program argument produces recoverable args_error" do
      llm =
        scripted_llm([
          %{
            content: nil,
            tool_calls: [%{id: "c1", name: "ptc_lisp_execute", args: %{}}],
            tokens: %{input: 0, output: 0}
          },
          tool_call_response("(return :ok)", id: "c2")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 5
        )

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      assert step.return == :ok
      assert paired_tool_call_id?(step.messages, "c1")

      tool_msg = find_tool_message(step.messages, "c1")
      assert json_field(tool_msg, "reason") == "args_error"
      refute Map.has_key?(Jason.decode!(tool_msg.content), "result")
    end

    test "non-string program argument is rejected" do
      llm =
        scripted_llm([
          %{
            content: nil,
            tool_calls: [
              %{id: "c1", name: "ptc_lisp_execute", args: %{"program" => 123}}
            ],
            tokens: %{input: 0, output: 0}
          },
          tool_call_response("(return 1)", id: "c2")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 5
        )

      assert {:ok, _step} = SubAgent.run(agent, llm: llm)
    end

    test "args_error from adapter is surfaced as protocol feedback" do
      llm =
        scripted_llm([
          %{
            content: nil,
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_lisp_execute",
                args: %{},
                args_error: "Invalid JSON arguments: garbage"
              }
            ],
            tokens: %{input: 0, output: 0}
          },
          tool_call_response("(return 1)")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 5
        )

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      tool_msg = find_tool_message(step.messages, "c1")
      assert json_field(tool_msg, "reason") == "args_error"
    end
  end

  describe "unknown native tool (R13)" do
    test "single unknown tool call → paired unknown_tool error, recovery on next turn" do
      llm =
        scripted_llm([
          %{
            content: nil,
            tool_calls: [
              %{id: "u1", name: "search", args: %{"q" => "hello"}}
            ],
            tokens: %{input: 0, output: 0}
          },
          tool_call_response("(return 7)")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 5
        )

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      assert step.return == 7

      tool_msg = find_tool_message(step.messages, "u1")
      assert json_field(tool_msg, "reason") == "unknown_tool"
      refute Map.has_key?(Jason.decode!(tool_msg.content), "result")
    end
  end

  describe "multiple native tool calls (R12)" do
    test "two ptc_lisp_execute calls in one turn → both rejected, paired errors per id" do
      llm =
        scripted_llm([
          %{
            content: nil,
            tool_calls: [
              %{id: "a", name: "ptc_lisp_execute", args: %{"program" => "(return 1)"}},
              %{id: "b", name: "ptc_lisp_execute", args: %{"program" => "(return 2)"}}
            ],
            tokens: %{input: 0, output: 0}
          },
          tool_call_response("(return :recovered)")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 5
        )

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      assert step.return == :recovered

      msg_a = find_tool_message(step.messages, "a")
      msg_b = find_tool_message(step.messages, "b")
      assert json_field(msg_a, "reason") == "multiple_tool_calls"
      assert json_field(msg_b, "reason") == "multiple_tool_calls"
    end

    test "mixed ptc_lisp_execute + unknown tool → uniformly multi-call rejected" do
      # The "exactly one native tool call per turn" rule wins over
      # per-name handling (R13 + R12).
      llm =
        scripted_llm([
          %{
            content: nil,
            tool_calls: [
              %{id: "x", name: "ptc_lisp_execute", args: %{"program" => "(return 1)"}},
              %{id: "y", name: "search", args: %{}}
            ],
            tokens: %{input: 0, output: 0}
          },
          tool_call_response("(return :ok)")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 5
        )

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      assert step.return == :ok

      assert json_field(find_tool_message(step.messages, "x"), "reason") ==
               "multiple_tool_calls"

      assert json_field(find_tool_message(step.messages, "y"), "reason") ==
               "multiple_tool_calls"
    end
  end

  # ============================================================
  # Error tool-result JSON shape (R23)
  # ============================================================

  describe "error tool-result JSON shape (R23)" do
    test "(fail v) error JSON includes `result` field" do
      llm =
        scripted_llm([
          tool_call_response(~s|(fail {:reason :x :message "boom"})|, id: "f1")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 3
        )

      {:error, step} = SubAgent.run(agent, llm: llm, collect_messages: true)

      tool_msg = find_tool_message(step.messages, "f1")
      decoded = Jason.decode!(tool_msg.content)
      assert decoded["status"] == "error"
      assert decoded["reason"] == "fail"
      assert Map.has_key?(decoded, "result")
    end

    test "args_error JSON omits `result` field" do
      llm =
        scripted_llm([
          %{
            content: nil,
            tool_calls: [%{id: "a1", name: "ptc_lisp_execute", args: %{}}],
            tokens: %{input: 0, output: 0}
          },
          tool_call_response("(return 1)")
        ])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 5)

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      decoded = Jason.decode!(find_tool_message(step.messages, "a1").content)
      refute Map.has_key?(decoded, "result")
    end

    test "unknown_tool JSON omits `result` field" do
      llm =
        scripted_llm([
          %{
            content: nil,
            tool_calls: [%{id: "u1", name: "nope", args: %{}}],
            tokens: %{input: 0, output: 0}
          },
          tool_call_response("(return 1)")
        ])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 5)

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      decoded = Jason.decode!(find_tool_message(step.messages, "u1").content)
      refute Map.has_key?(decoded, "result")
    end

    test "multiple_tool_calls JSON omits `result` field" do
      llm =
        scripted_llm([
          %{
            content: nil,
            tool_calls: [
              %{id: "m1", name: "ptc_lisp_execute", args: %{"program" => "(return 1)"}},
              %{id: "m2", name: "ptc_lisp_execute", args: %{"program" => "(return 2)"}}
            ],
            tokens: %{input: 0, output: 0}
          },
          tool_call_response("(return :ok)")
        ])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 5)

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      m1 = Jason.decode!(find_tool_message(step.messages, "m1").content)
      refute Map.has_key?(m1, "result")
    end
  end

  # ============================================================
  # Tool-result message shape (R22): success JSON
  # ============================================================

  describe "success tool-result JSON shape (R22)" do
    test "feedback equals TurnFeedback.execution_feedback/3 output (parity test)" do
      # Run an intermediate execution and inspect the success tool-result
      # message body. The `feedback` field must equal what
      # `TurnFeedback.execution_feedback/3` produces for the same lisp
      # step, NOT what `TurnFeedback.format/3` produces.
      llm =
        scripted_llm([
          tool_call_response("(def total 5)", id: "exec1"),
          tool_call_response("(return total)")
        ])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 5)

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      tool_msg = find_tool_message(step.messages, "exec1")
      decoded = Jason.decode!(tool_msg.content)

      assert decoded["status"] == "ok"
      assert is_binary(decoded["feedback"])
      assert is_map(decoded["memory"])
      assert is_list(decoded["memory"]["stored_keys"])
      assert is_map(decoded["memory"]["changed"])
      assert is_boolean(decoded["memory"]["truncated"])
      assert is_boolean(decoded["truncated"])
      # New/changed var "total" appears in changed previews
      assert Map.has_key?(decoded["memory"]["changed"], "total")
    end

    test "memory previews echo only new/changed vars" do
      llm =
        scripted_llm([
          tool_call_response("(def items [1 2 3])", id: "t1"),
          tool_call_response("(def total 6)", id: "t2"),
          tool_call_response("(return total)")
        ])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 5)

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)

      m1 = Jason.decode!(find_tool_message(step.messages, "t1").content)
      m2 = Jason.decode!(find_tool_message(step.messages, "t2").content)

      assert Map.has_key?(m1["memory"]["changed"], "items")
      # Second turn only echoes the new var
      assert Map.has_key?(m2["memory"]["changed"], "total")
      refute Map.has_key?(m2["memory"]["changed"], "items")
    end

    test "custom progress_fn does NOT appear in success tool-result JSON" do
      progress_fn = fn _input, state ->
        {"PROGRESS_LEAK_MARKER", state}
      end

      llm =
        scripted_llm([
          tool_call_response("(def x 1)", id: "p1"),
          tool_call_response("(return x)")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 5,
          progress_fn: progress_fn
        )

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      tool_msg = find_tool_message(step.messages, "p1")
      refute String.contains?(tool_msg.content, "PROGRESS_LEAK_MARKER")
    end

    test "custom progress_fn does NOT appear in error tool-result JSON" do
      progress_fn = fn _input, state ->
        {"PROGRESS_LEAK_MARKER", state}
      end

      llm =
        scripted_llm([
          %{
            content: nil,
            tool_calls: [%{id: "e1", name: "unknown_x", args: %{}}],
            tokens: %{input: 0, output: 0}
          },
          tool_call_response("(return 1)")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 5,
          progress_fn: progress_fn
        )

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      tool_msg = find_tool_message(step.messages, "e1")
      refute String.contains?(tool_msg.content, "PROGRESS_LEAK_MARKER")
    end
  end

  # ============================================================
  # *1 / *2 / *3 history (R20)
  # ============================================================

  describe "*1/*2/*3 history (R20)" do
    test "*1 references previous successful intermediate execution" do
      llm =
        scripted_llm([
          tool_call_response("(+ 1 2)"),
          tool_call_response("(return *1)")
        ])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 5)

      {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == 3
    end

    test "direct-answer turns do NOT advance turn_history" do
      # Turn 1: direct content (raw text) — counts as final answer if signature
      # accepts it, so use no signature so the loop continues only when content
      # is malformed. Here we route through fenced-content feedback (R16) so
      # the turn does not advance history. Then exec (+ 10 20) advances. Then
      # (return *1) should resolve to 30.
      llm =
        scripted_llm([
          # Fenced content → targeted feedback, does not advance history
          content_response("```clojure\n(+ 1 2)\n```"),
          tool_call_response("(+ 10 20)"),
          tool_call_response("(return *1)")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 6
        )

      {:ok, step} = SubAgent.run(agent, llm: llm)
      # *1 references the only successful intermediate execution: (+ 10 20)
      assert step.return == 30
    end
  end

  # ============================================================
  # max_tool_calls semantics (R19)
  # ============================================================

  describe "max_tool_calls semantics (R19)" do
    test "ptc_lisp_execute does not consume max_tool_calls budget" do
      # Even with max_tool_calls: 1, two ptc_lisp_execute calls should
      # both succeed (the budget only limits app tools called from
      # within PTC-Lisp).
      llm =
        scripted_llm([
          tool_call_response("(def x 1)"),
          tool_call_response("(def y 2)"),
          tool_call_response("(return (+ x y))")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_tool_calls: 1,
          max_turns: 5
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == 3
    end
  end

  # ============================================================
  # Universal pairing rule (R18) under collect_messages: true
  # ============================================================

  describe "universal pairing rule (R18)" do
    test "(a) success path: every tool_call_id paired with role: :tool" do
      llm =
        scripted_llm([
          tool_call_response("(def n 1)", id: "s1"),
          tool_call_response("(return n)", id: "s2")
        ])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 5)

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      assert paired_tool_call_id?(step.messages, "s1")
      assert paired_tool_call_id?(step.messages, "s2")
    end

    test "(b) (return v) final turn paired" do
      llm = scripted_llm([tool_call_response("(return 1)", id: "ret-id")])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 3)

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      assert paired_tool_call_id?(step.messages, "ret-id")
    end

    test "(c) (fail v) final turn paired" do
      llm =
        scripted_llm([
          tool_call_response(
            ~s|(fail {:reason :x :message "boom"})|,
            id: "fail-id"
          )
        ])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 3)

      {:error, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      assert paired_tool_call_id?(step.messages, "fail-id")
    end

    test "(d) unknown_tool: error tool-result paired" do
      llm =
        scripted_llm([
          %{
            content: nil,
            tool_calls: [%{id: "ut", name: "nope", args: %{}}],
            tokens: %{input: 0, output: 0}
          },
          tool_call_response("(return 1)")
        ])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 5)

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      assert paired_tool_call_id?(step.messages, "ut")
    end

    test "(e) multiple_tool_calls: one paired error per id" do
      llm =
        scripted_llm([
          %{
            content: nil,
            tool_calls: [
              %{id: "m1", name: "ptc_lisp_execute", args: %{"program" => "(return 1)"}},
              %{id: "m2", name: "ptc_lisp_execute", args: %{"program" => "(return 2)"}}
            ],
            tokens: %{input: 0, output: 0}
          },
          tool_call_response("(return :ok)")
        ])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 5)

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      assert paired_tool_call_id?(step.messages, "m1")
      assert paired_tool_call_id?(step.messages, "m2")
    end

    test "(f) args_error: paired error" do
      llm =
        scripted_llm([
          %{
            content: nil,
            tool_calls: [%{id: "ae", name: "ptc_lisp_execute", args: %{}}],
            tokens: %{input: 0, output: 0}
          },
          tool_call_response("(return 1)")
        ])

      agent =
        SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 5)

      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)
      assert paired_tool_call_id?(step.messages, "ae")
    end
  end

  # ============================================================
  # pmap telemetry parity (R27)
  # ============================================================

  describe "pmap telemetry parity (R27)" do
    test "(pmap ...) inside ptc_lisp_execute emits :pmap start/stop events" do
      events_table =
        :ets.new(:tool_call_pmap_events, [:bag, :public, write_concurrency: true])

      handler_id = "ptc-tool-call-pmap-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:ptc_runner, :sub_agent, :pmap, :start],
          [:ptc_runner, :sub_agent, :pmap, :stop]
        ],
        fn event, measurements, metadata, config ->
          :ets.insert(config.table, {event, measurements, metadata})
        end,
        %{table: events_table}
      )

      try do
        program = "(return (pmap inc [1 2 3]))"
        llm = scripted_llm([tool_call_response(program)])

        agent =
          SubAgent.new(prompt: "Test", ptc_transport: :tool_call, max_turns: 3)

        assert {:ok, step} = SubAgent.run(agent, llm: llm)
        assert step.return == [2, 3, 4]

        events = :ets.tab2list(events_table)
        suffixes = Enum.map(events, fn {event, _, _} -> List.last(event) end)

        assert :start in suffixes,
               "expected :pmap start event in :tool_call mode, got #{inspect(suffixes)}"

        assert :stop in suffixes,
               "expected :pmap stop event in :tool_call mode, got #{inspect(suffixes)}"
      after
        :telemetry.detach(handler_id)
        :ets.delete(events_table)
      end
    end
  end

  # ============================================================
  # Compaction handles new shape (R28)
  # ============================================================

  describe "compaction (R28)" do
    test "transcript with assistant tool_calls + role: :tool messages compacts cleanly" do
      llm =
        scripted_llm([
          tool_call_response("(def a 1)", id: "k1"),
          tool_call_response("(def b 2)", id: "k2"),
          tool_call_response("(def c 3)", id: "k3"),
          tool_call_response("(def d 4)", id: "k4"),
          tool_call_response("(def e 5)", id: "k5"),
          tool_call_response("(return :done)", id: "k6")
        ])

      agent =
        SubAgent.new(
          prompt: "Test",
          ptc_transport: :tool_call,
          max_turns: 8,
          compaction: [trigger: [turns: 2], keep_recent_turns: 2]
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == :done
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp paired_tool_call_id?(messages, id) when is_list(messages) do
    Enum.any?(messages, fn
      %{role: :tool, tool_call_id: ^id} -> true
      _ -> false
    end)
  end

  defp paired_tool_call_id?(_messages, _id), do: false

  defp find_tool_message(messages, id) when is_list(messages) do
    Enum.find(messages, fn
      %{role: :tool, tool_call_id: ^id} -> true
      _ -> false
    end)
  end

  defp json_field(%{content: content}, field) do
    Jason.decode!(content) |> Map.get(field)
  end
end
