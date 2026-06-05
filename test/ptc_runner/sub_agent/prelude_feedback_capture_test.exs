defmodule PtcRunner.SubAgent.PreludeFeedbackCaptureTest do
  @moduledoc """
  Capture test: what does the LLM actually SEE when a capability prelude is
  attached?

  The `runtime_prelude_test.exs` end-to-end tests prove the *plumbing* (a program
  that calls an export resolves and returns), but their mock ignores its input
  (`fn _ -> hardcoded end`), so they assert nothing about the LLM-facing surface.
  This test drives `SubAgent.run/2` with a recording, turn-branching mock (the
  `journal_test.exs` / `loop_llm_test.exs` house style) that asserts on:

    1. the **turn-1 system prompt** — the prelude inventory the model is shown
       (including the `[read]`-shown / `[unknown]`-omitted effect rendering); and
    2. the **turn-2 messages** — the execution feedback the model gets back after
       calling an export, for both a pure value and a recoverable tool failure.
  """
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.SubAgentTestHelpers, only: [test_agent: 1]

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.SubAgent

  # Two namespaces: a pure helper (effect :unknown -> hint omitted) and a
  # tool-backed export wrapping `(tool/call ...)` (effect :read -> hint shown).
  @prelude_source """
  (ns geo "Pure geometry helpers." {:visibility :prompt})

  (defn rect-area
    "Area of a w by h rectangle."
    [w h]
    (* w h))

  (ns crm "CRM helpers." {:visibility :prompt})

  (defn get-user
    "Return a CRM user by id."
    [id]
    (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
  """

  setup do
    {:ok, prelude} = Compiler.compile(@prelude_source)
    %{prelude: prelude}
  end

  describe "turn-1 system prompt shows the prelude inventory" do
    test "the model is shown curated exports, with [read] but not [unknown]", %{prelude: prelude} do
      agent =
        test_agent(
          prompt: "Compute the area of a 7 by 6 rectangle.",
          signature: "() -> {area :int}",
          runtime_prelude: prelude,
          max_turns: 1
        )

      llm = fn %{messages: messages, turn: 1} ->
        # The inventory is DYNAMIC context: SystemPrompt.generate_context/2
        # delivers it in the user message, not the static system prompt.
        shown = Enum.map_join(messages, "\n", & &1.content)

        # The inventory block reaches the model...
        assert shown =~ "prelude capabilities"
        assert shown =~ "crm/get-user"
        assert shown =~ "geo/rect-area"
        # ...the inferred tool-backed effect is shown...
        assert shown =~ "[read]"
        # ...but the pure export's :unknown effect is omitted (the change we made
        # to PromptInventory): no misleading hint, no wasted context.
        refute shown =~ "[unknown]"

        {:ok, ~S|```clojure
(return {:area (geo/rect-area 7 6)})
```|}
      end

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return["area"] == 42
    end
  end

  describe "turn-2 feedback carries the export result" do
    test "a pure export's value is fed back to the model on turn 2", %{prelude: prelude} do
      agent =
        test_agent(
          prompt: "Use the geometry helpers.",
          runtime_prelude: prelude,
          max_turns: 2
        )

      llm = fn %{messages: messages, turn: turn} ->
        case turn do
          1 ->
            # No (return ...) -> the loop evaluates and feeds the result back.
            {:ok, ~S|```clojure
(geo/rect-area 7 6)
```|}

          2 ->
            assert Enum.any?(messages, fn msg ->
                     msg.role == :user and msg.content =~ "42"
                   end),
                   "expected the export result (42) in the turn-2 feedback"

            {:ok, ~S|```clojure
(return {:done true})
```|}
        end
      end

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return["done"] == true
    end

    test "a recoverable tool failure reaches the model as a branchable map", %{prelude: prelude} do
      # Stub the upstream "call" tool to return the recoverable failure shape
      # `(tool/call ...)` yields, so user code could branch on (res :ok)/(res :reason).
      failing_call = fn _args -> %{ok: false, value: nil, reason: "not_found"} end

      agent =
        test_agent(
          prompt: "Look up the requested user.",
          runtime_prelude: prelude,
          tools: %{"call" => failing_call},
          max_turns: 2
        )

      llm = fn %{messages: messages, turn: turn} ->
        case turn do
          1 ->
            {:ok, ~S|```clojure
(crm/get-user "u_404")
```|}

          2 ->
            # The :reason surfaces in the feedback, so a real model could branch.
            assert Enum.any?(messages, fn msg ->
                     msg.role == :user and msg.content =~ "not_found"
                   end),
                   "expected the recoverable :reason in the turn-2 feedback"

            {:ok, ~S|```clojure
(return {:done true})
```|}
        end
      end

      assert {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return["done"] == true
    end
  end
end
