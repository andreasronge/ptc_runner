defmodule PtcRunner.SubAgent.Loop.TextModeStatePreservationTest do
  @moduledoc """
  Tier 2a regression: pin state-preservation invariants for pure
  `output: :text` runs (no `ptc_transport: :tool_call`, no combined mode).

  These invariants exist so that future tiers (combined mode, native preview
  cache wiring, `ptc_lisp_execute` dispatch) cannot silently regress the
  byte-identical pure-text contract laid out in
  `Plans/text-mode-ptc-compute-tool.md`:

  - Tier 2a: "pure `output: :text` runs are byte-identical before and after."
  - Addendum #15: "`tool_cache` initialization site is in TextMode
    combined-mode entry path, NOT `Loop.State` defaults — pure text MUST
    leave `tool_cache: nil`."

  The assertions use `===` on the loop state's `tool_cache` so a future
  combined-mode change that accidentally seeds `tool_cache: %{}` for pure
  text runs will fail loudly here. Step-side fields are pinned to their
  current observable shape (Step struct defaults / TextMode hardcodes).
  """
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop
  alias PtcRunner.SubAgent.Loop.State

  import PtcRunner.TestSupport.SubAgentTestHelpers, only: [tool_calling_llm: 1]

  describe "pure text mode (no tools, :string return)" do
    test "leaves Loop.State defaults untouched on the resulting step" do
      agent =
        SubAgent.new(
          prompt: "Say hi",
          output: :text,
          max_turns: 1
        )

      llm = fn _input -> {:ok, "hello"} end

      {:ok, step} = Loop.run(agent, llm: llm)

      # --- Behavioral pinning (byte-identical pure-text contract) ---
      assert step.return == "hello"
      assert step.fail == nil

      # `step.memory` is hardcoded to `%{}` in TextMode's text-only branch
      # even though `state.memory` is `nil` by State default. Pin the
      # observed value so a future "propagate state.memory" change cannot
      # silently break the existing public contract.
      assert step.memory === %{}

      # `state.journal`, `state.tool_cache`, `state.summaries`,
      # `state.child_steps` are never touched by pure text mode, so the
      # Step ends up with the `%Step{}` struct defaults.
      assert step.journal === nil
      assert step.tool_cache === %{}
      assert step.summaries === %{}

      # Pure text-only success path uses a `%Step{...}` literal that does
      # not set `:child_steps`, so the struct default (nil) is observed.
      # If a future change moves text mode to `Step.ok/2` or starts
      # threading `state.child_steps`, this assertion will need updating
      # alongside a careful review of downstream consumers.
      assert step.child_steps === nil

      # `turn_history` does not appear on the public Step struct — it's
      # loop-internal. We assert that here so a future leak of internal
      # state into the public surface is caught.
      refute Map.has_key?(step, :turn_history)
    end

    test "Loop.State default for tool_cache remains nil for pure text runs" do
      # Addendum #15: pure `output: :text` MUST NOT touch `tool_cache`.
      # We can't directly read the post-run `Loop.State` (it's not
      # returned), but we can pin the State default itself with `===`.
      # Combined-mode wiring (future tier) will explicitly initialize
      # `tool_cache: %{}` in TextMode's combined-mode branch — that branch
      # MUST NOT affect this default.
      assert %State{
               llm: fn _ -> :ok end,
               context: %{},
               turn: 1,
               messages: [],
               start_time: 0,
               work_turns_remaining: 0
             }.tool_cache === nil
    end
  end

  describe "pure text mode JSON variant (no tools, complex signature)" do
    test "leaves state-derived step fields at their defaults" do
      agent =
        SubAgent.new(
          prompt: "Compute",
          output: :text,
          signature: "() -> {answer :string}",
          max_turns: 1
        )

      llm = fn _input -> {:ok, ~S|{"answer": "ok"}|} end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == %{"answer" => "ok"}
      assert step.fail == nil

      assert step.memory === %{}
      assert step.journal === nil
      assert step.tool_cache === %{}
      assert step.summaries === %{}
      # JSON-only success path also uses a `%Step{...}` literal with no
      # `:child_steps`, so the struct default is observed.
      assert step.child_steps === nil
    end
  end

  describe "pure text mode tool variant (with tools)" do
    @describetag :tool_calling

    test "preserves state defaults across native tool call + final answer" do
      tools = %{
        "search" =>
          {fn args -> "result for #{args["q"]}" end,
           signature: "(q :string) -> :string", description: "Search"}
      }

      llm =
        tool_calling_llm([
          # Turn 1: model calls native app tool
          %{
            tool_calls: [%{id: "c1", name: "search", args: %{"q" => "x"}}],
            content: nil,
            tokens: %{input: 10, output: 5}
          },
          # Turn 2: model returns final JSON answer
          %{content: ~S|{"answer": "done"}|, tokens: %{input: 10, output: 5}}
        ])

      agent =
        SubAgent.new(
          prompt: "Find it",
          output: :text,
          signature: "() -> {answer :string}",
          tools: tools,
          max_turns: 5
        )

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == %{"answer" => "done"}
      assert step.fail == nil

      # The presence of a tool call must not perturb pure-text state-shape
      # invariants. Pin the same defaults Tier 2b will assert "remains
      # untouched" against combined-mode behavior.
      assert step.memory === %{}
      assert step.journal === nil
      assert step.tool_cache === %{}
      assert step.summaries === %{}

      # Native tool call traces appear in step.tool_calls (different
      # field), not in tool_cache. Sanity-check that tool dispatch did
      # happen so we're actually exercising the multi-turn tool path.
      assert is_list(step.tool_calls)
      assert length(step.tool_calls) == 1
    end

    test "preserves state defaults on text-return tool variant" do
      tools = %{
        "echo" =>
          {fn args -> args["msg"] end, signature: "(msg :string) -> :string", description: "Echo"}
      }

      llm =
        tool_calling_llm([
          %{
            tool_calls: [%{id: "c1", name: "echo", args: %{"msg" => "hi"}}],
            content: nil,
            tokens: %{input: 10, output: 5}
          },
          %{content: "final: hi", tokens: %{input: 10, output: 5}}
        ])

      agent =
        SubAgent.new(
          prompt: "Echo it",
          output: :text,
          # No signature / :string return → text return path
          tools: tools,
          max_turns: 5
        )

      {:ok, step} = SubAgent.run(agent, llm: llm)

      assert step.return == "final: hi"
      assert step.memory === %{}
      assert step.journal === nil
      assert step.tool_cache === %{}
      assert step.summaries === %{}
    end
  end
end
