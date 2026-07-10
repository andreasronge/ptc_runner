defmodule PtcRunner.Kernel.PreludeSplitTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Bundle
  alias PtcRunner.Lisp.Prelude.Compiler

  @feedback_source """
  (ns agent.feedback
    "Feedback policy for the kernel loop."
    {:visibility :prompt})

  (defn eval-feedback
    "Render retry feedback for a non-returning program result."
    [result cfg]
    (json/generate-string
      {"type" "ptc_lisp_eval_feedback"
       "instruction" "retry with (return value)"
       "untrusted_eval_result" result
       "variant" (cfg "variant")}))
  """

  @core_source """
  (ns agent.core
    "Minimal compile proof for cross-namespace kernel policy calls."
    {:visibility :prompt})

  (defn run-once
    "Exercise kernel tools and delegate retry text to agent.feedback."
    [result cfg]
    (do
      (tool/log {"event" "compile-proof"})
      (tool/llm-complete {"system" "compile proof system" "messages" [] "turn" 0})
      (tool/eval-program {"program" "(return :ok)" "turn" 0})
      (agent.feedback/eval-feedback result cfg)))
  """

  test "2a: Bundle.compile_precompiled/2 compiles agent.core calling agent.feedback exports" do
    {:ok, feedback} = Compiler.compile(@feedback_source)

    {:ok, core} =
      Compiler.compile(@core_source,
        deps: [feedback],
        namespace_deps: %{"agent.core" => ["agent.feedback"]}
      )

    assert {:ok, prelude} =
             Bundle.compile_precompiled(
               [
                 %{id: "agent.feedback", source: @feedback_source, prelude: feedback},
                 %{id: "agent.core", source: @core_source, prelude: core}
               ],
               namespace_deps: %{"agent.core" => ["agent.feedback"]}
             )

    assert Prelude.namespaces(prelude) == ["agent.core", "agent.feedback"]
    assert {:ok, core_export} = Prelude.fetch_export(prelude, "agent.core/run-once")
    assert {:ok, feedback_export} = Prelude.fetch_export(prelude, "agent.feedback/eval-feedback")

    assert Enum.sort(core_export.tool_refs) == ["eval-program", "llm-complete", "log"]
    assert feedback_export.tool_refs == []

    assert {:ok, step} =
             Lisp.run(
               ~S|(agent.core/run-once {"status" "continue" "value" 3} {"variant" "2a"})|,
               prelude: prelude,
               tools: kernel_private_tools()
             )

    decoded = Jason.decode!(step.return)
    assert decoded["type"] == "ptc_lisp_eval_feedback"
    assert decoded["instruction"] == "retry with (return value)"
    assert decoded["untrusted_eval_result"]["status"] == "continue"
    assert decoded["variant"] == "2a"
  end

  test "2a: raw Bundle.compile/1 remains dep-blind for agent.core policy calls" do
    assert {:error, error} =
             Bundle.compile([
               %{id: "agent.feedback", source: @feedback_source},
               %{id: "agent.core", source: @core_source}
             ])

    assert error.reason == :compile_error
    assert error.message =~ "unknown namespace"
    assert error.message =~ "requires_preludes"
  end

  test "2a: kernel private tools still fail closed outside the authorized core export" do
    {:ok, feedback} = Compiler.compile(@feedback_source)

    {:ok, core} =
      Compiler.compile(@core_source,
        deps: [feedback],
        namespace_deps: %{"agent.core" => ["agent.feedback"]}
      )

    {:ok, prelude} =
      Bundle.compile_precompiled(
        [
          %{id: "agent.feedback", source: @feedback_source, prelude: feedback},
          %{id: "agent.core", source: @core_source, prelude: core}
        ],
        namespace_deps: %{"agent.core" => ["agent.feedback"]}
      )

    assert {:error, step} =
             Lisp.run(~S|(tool/log {"event" "forged"})|,
               prelude: prelude,
               tools: kernel_private_tools()
             )

    assert step.fail.reason == :private_tool_unauthorized
  end

  test "2b: default kernel bundle compiles full agent.core prompt and feedback graph" do
    assert {:ok, prelude} = Kernel.compile_prelude()

    assert Prelude.namespaces(prelude) == ["agent.core", "agent.feedback", "agent.prompt"]

    assert {:ok, core} = Prelude.fetch_export(prelude, "agent.core/run-mission")
    assert :error = Prelude.fetch_export(prelude, "agent.core/action-summary")
    assert {:ok, system_message} = Prelude.fetch_export(prelude, "agent.prompt/system-message")
    assert {:ok, task_message} = Prelude.fetch_export(prelude, "agent.prompt/task-message")

    assert {:ok, protocol_error} = Prelude.fetch_export(prelude, "agent.feedback/protocol-error")
    assert {:ok, eval_feedback} = Prelude.fetch_export(prelude, "agent.feedback/eval-feedback")
    assert {:ok, max_chars} = Prelude.fetch_export(prelude, "agent.feedback/feedback-max-chars")

    assert {:ok, truncation_hint} =
             Prelude.fetch_export(prelude, "agent.feedback/feedback-truncation-hint")

    assert Enum.sort(core.tool_refs) == ["eval-program", "llm-complete", "log"]

    for export <- [system_message, task_message, protocol_error, eval_feedback] do
      assert export.tool_refs == []
    end

    assert max_chars.kind == :constant
    assert truncation_hint.kind == :constant

    for internal <- ~w(bounded-scalar-max-chars eval-result-keys detail-keys) do
      assert :error = Prelude.fetch_export(prelude, "agent.feedback/#{internal}")
    end

    assert {:ok, step} =
             Lisp.run(~S|(agent.prompt/system-message {"protocol_tool_name" "run_ptc_lisp"})|,
               prelude: prelude,
               tools: kernel_private_tools()
             )

    assert step.return =~ "You are controlling PTC-Lisp through native tool calling."
    assert step.return =~ "run_ptc_lisp"
  end

  test "feedback policy emits valid bounded JSON with an explicit truncation hint" do
    assert {:ok, prelude} = Kernel.compile_prelude()

    source = """
    (agent.feedback/eval-feedback
      {"status" "continue"
       "reason" "retry"
       "details" {"large" "#{String.duplicate("x", 10_000)}"}
       "ignored" "#{String.duplicate("secret", 500)}"}
      {})
    """

    assert {:ok, step} = Lisp.run(source, prelude: prelude, tools: kernel_private_tools())
    assert String.length(step.return) <= 4_096

    decoded = Jason.decode!(step.return)

    eval = decoded["untrusted_eval_result"]
    assert eval["reason"] == "retry"
    assert eval["status"] == "continue"
    assert eval["details"]["limit_bytes"] == nil
    assert decoded["truncated"] == true
    assert decoded["hint"] =~ "smaller intermediate result"
    refute step.return =~ String.duplicate("x", 100)
    refute step.return =~ "secret"
  end

  test "feedback policy omits near-cap evaluator payloads before encoding" do
    assert {:ok, prelude} = Kernel.compile_prelude()

    large = String.duplicate("x", 500_000)

    source =
      ~S|(agent.feedback/eval-feedback {"status" "continue" "reason" "retry" "value" payload "details" {"payload" payload} "prints" [payload]} {})|

    assert {:ok, step} =
             Lisp.run(source,
               prelude: prelude,
               memory: %{"payload" => large},
               tools: kernel_private_tools()
             )

    assert String.length(step.return) <= 4_096
    eval = Jason.decode!(step.return)["untrusted_eval_result"]
    assert String.length(eval["value"]) == 512
    assert eval["details"]["limit_bytes"] == nil
    refute Map.has_key?(eval["details"], "payload")
    assert [print] = eval["prints"]
    assert String.length(print) == 512

    decoded = Jason.decode!(step.return)
    assert decoded["truncated"] == true
    assert decoded["hint"] =~ "persisted definitions"
  end

  test "feedback policy preserves an under-limit evaluator error message" do
    assert {:ok, prelude} = Kernel.compile_prelude()

    assert {:ok, step} =
             Lisp.run(
               ~S|(agent.feedback/eval-feedback {"status" "error" "reason" "unbound_var" "message" "Unknown symbol total"} {})|,
               prelude: prelude,
               tools: kernel_private_tools()
             )

    decoded = Jason.decode!(step.return)
    assert decoded["untrusted_eval_result"]["message"] == "Unknown symbol total"
    refute Map.has_key?(decoded, "truncated")
  end

  test "feedback policy omits an arbitrary-precision integer before JSON encoding" do
    assert {:ok, prelude} = Kernel.compile_prelude()

    source =
      ~S|(agent.feedback/eval-feedback {"status" "continue" "value" (reduce * (range 1 2000))} {"protocol_tool_name" "run_ptc_lisp"})|

    assert {:ok, step} = Lisp.run(source, prelude: prelude, tools: kernel_private_tools())
    assert String.length(step.return) <= 4_096

    decoded = Jason.decode!(step.return)
    assert decoded["truncated"] == true
    assert decoded["untrusted_eval_result"]["value"] == "<omitted: oversized number>"
  end

  defp kernel_private_tools do
    %{
      "llm-complete" => {fn _args -> %{"kind" => "ok"} end, [visibility: :private]},
      "eval-program" =>
        {fn _args -> %{"status" => "return", "value" => "ok"} end, [visibility: :private]},
      "log" => {fn _args -> %{"ok" => true} end, [visibility: :private]}
    }
  end
end
