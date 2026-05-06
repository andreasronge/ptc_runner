defmodule PtcRunner.SubAgent.Loop.TextModeCombinedMultiCallTest do
  @moduledoc """
  Tier 3c — Multi-Call Rule + protocol-error rendering tests.

  Pins the six-row precedence table from
  `Plans/text-mode-ptc-compute-tool.md` "Multi-Call Rule":

    Row 1  Multiple `ptc_lisp_execute` calls (any other calls present
           or not) → reject all (`multiple_tool_calls`).
    Row 2  Exactly one `ptc_lisp_execute` + any other native call
           (valid or unknown) → reject all
           (`mixed_with_ptc_lisp_execute`).
    Row 3  Exactly one `ptc_lisp_execute` alone → execute the program.
    Row 4  Native app-tool calls only — all valid → execute all.
    Row 5  Native app-tool calls only — mix of valid + unknown →
           execute valid; pair `unknown_tool` per unknown id.
    Row 6  Native app-tool calls only — all unknown → pair
           `unknown_tool` per id.

  Universal pairing rule: every `tool_call_id` returned by the LLM in
  a turn MUST be paired with exactly one `role: :tool` message before
  the loop continues or terminates.

  Combined mode = `output: :text, ptc_transport: :tool_call`. The
  validator still rejects this combo at agent construction (Tier 3e
  flips the gate); tests build via `SubAgent.new/1` in pure text mode
  and `into_combined/1` it before invoking `SubAgent.run/2`, mirroring
  the helper used in `text_mode_combined_test.exs`.
  """

  use ExUnit.Case, async: false

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Definition

  import PtcRunner.TestSupport.SubAgentTestHelpers, only: [tool_calling_llm: 1]

  defp into_combined(%Definition{} = agent), do: %{agent | ptc_transport: :tool_call}

  defp run_combined(agent, llm) do
    SubAgent.run(into_combined(agent), llm: llm, collect_messages: true)
  end

  defp tool_messages(step), do: Enum.filter(step.messages, &(&1[:role] == :tool))

  defp assistant_messages(step), do: Enum.filter(step.messages, &(&1[:role] == :assistant))

  # Universal pairing helper: count tool_call_ids in assistant messages
  # vs paired :tool messages.
  defp universal_pairing_ok?(step) do
    assistant_ids =
      step
      |> assistant_messages()
      |> Enum.flat_map(fn m -> Map.get(m, :tool_calls, []) || [] end)
      |> Enum.map(& &1.id)
      |> Enum.sort()

    tool_ids =
      step
      |> tool_messages()
      |> Enum.map(& &1.tool_call_id)
      |> Enum.sort()

    assistant_ids == tool_ids
  end

  # ---------------------------------------------------------------------------
  # Row 1 — multiple `ptc_lisp_execute` calls
  # ---------------------------------------------------------------------------

  describe "Row 1: multiple ptc_lisp_execute calls" do
    test "two ptc_lisp_execute calls reject all with multiple_tool_calls" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "ptc_lisp_execute", args: %{"program" => "(+ 1 2)"}},
              %{id: "c2", name: "ptc_lisp_execute", args: %{"program" => "(+ 3 4)"}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "recovered", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      tool_msgs = tool_messages(step)
      assert length(tool_msgs) == 2

      Enum.each(tool_msgs, fn m ->
        payload = Jason.decode!(m.content)
        assert payload["status"] == "error"
        assert payload["reason"] == "multiple_tool_calls"
        assert is_binary(payload["message"])
        # No `feedback` field on protocol errors (Tier 3c spec).
        refute Map.has_key?(payload, "feedback")
        # Exact key shape pin.
        assert Map.keys(payload) |> Enum.sort() == ["message", "reason", "status"]
      end)

      assert Enum.map(tool_msgs, & &1.tool_call_id) |> Enum.sort() == ["c1", "c2"]
      assert universal_pairing_ok?(step)
      assert step.return == "recovered"
    end

    test "ptc_lisp_execute + ptc_lisp_execute + native_tool — Row 1 wins, native NOT invoked" do
      counter = :atomics.new(1, [])

      tools = %{
        "search" =>
          {fn _ ->
             :atomics.add(counter, 1, 1)
             [%{"id" => 1}]
           end, signature: "(q :string) -> [:any]", expose: :native}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "ptc_lisp_execute", args: %{"program" => "(+ 1 2)"}},
              %{id: "c2", name: "ptc_lisp_execute", args: %{"program" => "(+ 3 4)"}},
              %{id: "c3", name: "search", args: %{"q" => "x"}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "ok", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      tool_msgs = tool_messages(step)
      assert length(tool_msgs) == 3

      Enum.each(tool_msgs, fn m ->
        payload = Jason.decode!(m.content)
        assert payload["reason"] == "multiple_tool_calls"
      end)

      # Native tool function MUST NOT be invoked when Row 1 fires.
      assert :atomics.get(counter, 1) == 0
      assert universal_pairing_ok?(step)
    end
  end

  # ---------------------------------------------------------------------------
  # Row 2 — one ptc_lisp_execute + other native call
  # ---------------------------------------------------------------------------

  describe "Row 2: ptc_lisp_execute + other native call" do
    test "ptc_lisp_execute + valid native — both paired with mixed_with_ptc_lisp_execute" do
      counter = :atomics.new(1, [])

      tools = %{
        "search" =>
          {fn _ ->
             :atomics.add(counter, 1, 1)
             [%{"id" => 1}]
           end, signature: "(q :string) -> [:any]", expose: :native}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "ptc_lisp_execute", args: %{"program" => "(+ 1 2)"}},
              %{id: "c2", name: "search", args: %{"q" => "x"}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "recovered", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      tool_msgs = tool_messages(step)
      assert length(tool_msgs) == 2

      Enum.each(tool_msgs, fn m ->
        payload = Jason.decode!(m.content)
        assert payload["status"] == "error"
        assert payload["reason"] == "mixed_with_ptc_lisp_execute"
        refute Map.has_key?(payload, "feedback")
      end)

      # Native tool function MUST NOT be invoked when Row 2 fires.
      assert :atomics.get(counter, 1) == 0
      assert universal_pairing_ok?(step)
      assert step.return == "recovered"
    end

    test "ptc_lisp_execute + unknown native — both paired with mixed_with_ptc_lisp_execute (precedence wins over unknown_tool)" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "ptc_lisp_execute", args: %{"program" => "(+ 1 2)"}},
              %{id: "c2", name: "no_such_tool", args: %{"q" => "x"}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "recovered", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      tool_msgs = tool_messages(step)
      assert length(tool_msgs) == 2

      Enum.each(tool_msgs, fn m ->
        payload = Jason.decode!(m.content)
        assert payload["reason"] == "mixed_with_ptc_lisp_execute"
        refute payload["reason"] == "unknown_tool"
      end)

      assert universal_pairing_ok?(step)
    end
  end

  # ---------------------------------------------------------------------------
  # Row 3 — single ptc_lisp_execute alone (regression pin for Tier 3a path)
  # ---------------------------------------------------------------------------

  describe "Row 3: single ptc_lisp_execute alone" do
    test "executes program; tool result rendered via PtcToolProtocol.render_success/2" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "ptc_lisp_execute", args: %{"program" => "(+ 1 2)"}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "done"

      tool_msgs = tool_messages(step)
      assert length(tool_msgs) == 1

      payload = Jason.decode!(hd(tool_msgs).content)
      # Render-success path: status: ok (Tier 3a regression pin).
      assert payload["status"] == "ok"

      assert universal_pairing_ok?(step)
    end
  end

  # ---------------------------------------------------------------------------
  # Row 4 — multiple valid native calls (regression pin)
  # ---------------------------------------------------------------------------

  describe "Row 4: multiple valid native calls only" do
    test "both execute; both paired with their tool results (combined-mode)" do
      counter_a = :atomics.new(1, [])
      counter_b = :atomics.new(1, [])

      tools = %{
        "alpha" =>
          {fn _ ->
             :atomics.add(counter_a, 1, 1)
             %{"ok" => true}
           end, signature: "(q :string) -> :map", expose: :native},
        "beta" =>
          {fn _ ->
             :atomics.add(counter_b, 1, 1)
             %{"ok" => true}
           end, signature: "(q :string) -> :map", expose: :native}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "alpha", args: %{"q" => "x"}},
              %{id: "c2", name: "beta", args: %{"q" => "y"}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "done"
      assert :atomics.get(counter_a, 1) == 1
      assert :atomics.get(counter_b, 1) == 1

      tool_msgs = tool_messages(step)
      assert length(tool_msgs) == 2
      assert universal_pairing_ok?(step)
    end
  end

  # ---------------------------------------------------------------------------
  # Row 5 — valid + unknown
  # ---------------------------------------------------------------------------

  describe "Row 5: valid native + unknown native (combined mode)" do
    test "valid executes; unknown gets unknown_tool paired error; loop continues" do
      counter = :atomics.new(1, [])

      tools = %{
        "alpha" =>
          {fn _ ->
             :atomics.add(counter, 1, 1)
             %{"ok" => true}
           end, signature: "(q :string) -> :map", expose: :native}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "alpha", args: %{"q" => "x"}},
              %{id: "c2", name: "no_such_tool", args: %{"q" => "y"}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "done"
      assert :atomics.get(counter, 1) == 1

      tool_msgs = tool_messages(step)
      assert length(tool_msgs) == 2

      paired = Map.new(tool_msgs, fn m -> {m.tool_call_id, Jason.decode!(m.content)} end)

      # c1 succeeded — its payload is NOT a protocol error.
      refute paired["c1"]["reason"] == "unknown_tool"

      # c2 paired with unknown_tool protocol error.
      assert paired["c2"]["status"] == "error"
      assert paired["c2"]["reason"] == "unknown_tool"
      assert is_binary(paired["c2"]["message"])
      refute Map.has_key?(paired["c2"], "feedback")
      assert Map.keys(paired["c2"]) |> Enum.sort() == ["message", "reason", "status"]

      assert universal_pairing_ok?(step)
    end
  end

  # ---------------------------------------------------------------------------
  # Row 6 — all unknown
  # ---------------------------------------------------------------------------

  describe "Row 6: all unknown native calls (combined mode)" do
    test "both paired with unknown_tool; loop continues" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "ghost_a", args: %{}},
              %{id: "c2", name: "ghost_b", args: %{}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "done"

      tool_msgs = tool_messages(step)
      assert length(tool_msgs) == 2

      Enum.each(tool_msgs, fn m ->
        payload = Jason.decode!(m.content)
        assert payload["status"] == "error"
        assert payload["reason"] == "unknown_tool"
        refute Map.has_key?(payload, "feedback")
      end)

      assert universal_pairing_ok?(step)
    end
  end

  # ---------------------------------------------------------------------------
  # Addendum #9 — :ptc_lisp-only tool called natively → unknown_tool
  # ---------------------------------------------------------------------------

  describe "Addendum #9: :ptc_lisp-only tool called natively in combined mode" do
    test "returns unknown_tool (per Multi-Call Rule Row 6 / Row 5)" do
      counter = :atomics.new(1, [])

      tools = %{
        "ptc_only" =>
          {fn _ ->
             :atomics.add(counter, 1, 1)
             %{"ok" => true}
           end, signature: "(v :int) -> :any", expose: :ptc_lisp}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "ptc_only", args: %{"v" => 7}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "done"

      # Tool function MUST NOT be invoked when called natively against
      # a :ptc_lisp-only target.
      assert :atomics.get(counter, 1) == 0

      tool_msgs = tool_messages(step)
      assert length(tool_msgs) == 1

      payload = Jason.decode!(hd(tool_msgs).content)
      assert payload["status"] == "error"
      assert payload["reason"] == "unknown_tool"
      refute Map.has_key?(payload, "feedback")

      assert universal_pairing_ok?(step)
    end
  end

  # ---------------------------------------------------------------------------
  # Tier 3.5 Fix 4 — unknown_tool wins over args_error in combined mode
  # ---------------------------------------------------------------------------

  describe "Tier 3.5 Fix 4: unknown_tool precedence over args_error (combined mode)" do
    # If the LLM calls an unregistered (or `:ptc_lisp`-only) native tool
    # AND the args fail to parse, the legacy `:args_error` branch fired
    # first and produced the legacy `%{"error" => ...}` envelope. The
    # Multi-Call Rule mandates `unknown_tool` protocol-error JSON
    # regardless of args-parsing state — the right error class for the
    # actual problem (the tool isn't callable) wins over the wrong one.
    test "unknown native tool with args_error → unknown_tool protocol error" do
      # Construct a tool call with both `name: "ghost"` (unregistered)
      # and `args_error` set, simulating a malformed-JSON args response
      # from the LLM adapter. Two turns: first the unknown-tool call,
      # second the LLM gives up.
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ghost",
                args: %{},
                args_error: "Invalid JSON: Unexpected character"
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert step.return == "done"

      tool_msgs = tool_messages(step)
      assert length(tool_msgs) == 1

      payload = Jason.decode!(hd(tool_msgs).content)
      assert payload["status"] == "error"
      assert payload["reason"] == "unknown_tool"
      # Tier 3c protocol-error JSON shape: status, reason, message, no feedback.
      refute Map.has_key?(payload, "feedback")

      assert universal_pairing_ok?(step)
    end

    test ":ptc_lisp-only tool with args_error → unknown_tool (precedence over args_error)" do
      tools = %{
        "ptc_only" =>
          {fn _ -> %{"ok" => true} end, signature: "(v :int) -> :any", expose: :ptc_lisp}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "ptc_only",
                args: %{},
                args_error: "Invalid JSON"
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      tool_msgs = tool_messages(step)
      payload = Jason.decode!(hd(tool_msgs).content)
      assert payload["reason"] == "unknown_tool"
      refute Map.has_key?(payload, "feedback")
    end

    test "KNOWN tool with args_error in combined mode → still legacy args_error envelope" do
      # The flip is only for unknown tools. Known tools with malformed
      # args keep the existing args-error feedback path so the LLM gets
      # a useful "fix your JSON" message.
      tools = %{
        "search" =>
          {fn _ -> [] end, signature: "(q :string) -> [:any]", expose: :both, cache: false}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{
                id: "c1",
                name: "search",
                args: %{},
                args_error: "Invalid JSON: missing q"
              }
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      tool_msgs = tool_messages(step)
      payload = Jason.decode!(hd(tool_msgs).content)
      # Legacy args_error path uses `%{"error" => msg}` envelope.
      assert Map.has_key?(payload, "error")
      assert payload["error"] =~ "Invalid JSON"
    end

    test "pure text mode unknown tool with args_error keeps legacy 'error' envelope" do
      # Pure text mode short-circuits at `combined_mode_active?/1` and
      # keeps legacy behavior — args_error wins (or "Tool not found" if
      # args parse cleanly).
      tools = %{
        "alpha" => {fn _ -> %{"ok" => true} end, signature: "(q :string) -> :map"}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "ghost", args: %{}, args_error: "Invalid JSON"}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      # NOT into_combined — pure text mode.
      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)

      tool_msgs = tool_messages(step)
      assert length(tool_msgs) == 1
      payload = Jason.decode!(hd(tool_msgs).content)
      # Legacy envelope, NOT protocol-error JSON.
      assert Map.has_key?(payload, "error")
      refute Map.has_key?(payload, "reason")
    end
  end

  # ---------------------------------------------------------------------------
  # Pure text mode unaffected
  # ---------------------------------------------------------------------------

  describe "pure text mode (no combined) — existing multi-tool behavior preserved" do
    test "[valid_native_a, valid_native_b] in pure text → both execute" do
      counter_a = :atomics.new(1, [])
      counter_b = :atomics.new(1, [])

      tools = %{
        "alpha" =>
          {fn _ ->
             :atomics.add(counter_a, 1, 1)
             %{"ok" => true}
           end, signature: "(q :string) -> :map"},
        "beta" =>
          {fn _ ->
             :atomics.add(counter_b, 1, 1)
             %{"ok" => true}
           end, signature: "(q :string) -> :map"}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "alpha", args: %{"q" => "x"}},
              %{id: "c2", name: "beta", args: %{"q" => "y"}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      # No `into_combined/1` — pure text mode (validator-accepted).
      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)

      assert step.return == "done"
      assert :atomics.get(counter_a, 1) == 1
      assert :atomics.get(counter_b, 1) == 1

      assert universal_pairing_ok?(step)
    end

    test "unknown tool in pure text mode keeps legacy 'Tool not found' envelope (no protocol-error JSON)" do
      tools = %{
        "alpha" => {fn _ -> %{"ok" => true} end, signature: "(q :string) -> :map"}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "ghost", args: %{}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = SubAgent.run(agent, llm: llm, collect_messages: true)

      tool_msgs = tool_messages(step)
      assert length(tool_msgs) == 1
      payload = Jason.decode!(hd(tool_msgs).content)

      # Pure text mode: legacy `%{"error" => ...}` envelope, NOT the
      # combined-mode protocol-error shape.
      assert Map.has_key?(payload, "error")
      refute payload["status"] == "error"
      refute payload["reason"] == "unknown_tool"
    end
  end

  # ---------------------------------------------------------------------------
  # Universal pairing rule — explicit cross-row coverage
  # ---------------------------------------------------------------------------

  describe "universal pairing rule" do
    test "every tool_call_id is paired with exactly one :tool message — Row 1" do
      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "ptc_lisp_execute", args: %{"program" => "(+ 1 2)"}},
              %{id: "c2", name: "ptc_lisp_execute", args: %{"program" => "(+ 3 4)"}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "ok", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: %{}, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert universal_pairing_ok?(step)
    end

    test "every tool_call_id is paired with exactly one :tool message — Row 5 mixed" do
      tools = %{
        "alpha" =>
          {fn _ -> %{"ok" => true} end, signature: "(q :string) -> :map", expose: :native}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [
              %{id: "c1", name: "alpha", args: %{"q" => "x"}},
              %{id: "c2", name: "ghost_b", args: %{}},
              %{id: "c3", name: "ghost_c", args: %{}}
            ],
            content: nil,
            tokens: %{input: 1, output: 1}
          },
          %{content: "done", tokens: %{input: 1, output: 1}}
        ])

      agent = SubAgent.new(prompt: "x", output: :text, tools: tools, max_turns: 5)
      {:ok, step} = run_combined(agent, llm)

      assert universal_pairing_ok?(step)
    end
  end
end
