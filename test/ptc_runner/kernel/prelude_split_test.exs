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
      (tool/llm-complete {"messages" [] "turn" 0})
      (tool/eval-program {"program" "(return :ok)"})
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

    assert Enum.sort(core.tool_refs) == ["eval-program", "llm-complete", "log"]

    for export <- [system_message, task_message, protocol_error, eval_feedback] do
      assert export.tool_refs == []
    end

    assert {:ok, step} =
             Lisp.run(~S|(agent.prompt/system-message {})|,
               prelude: prelude,
               tools: kernel_private_tools()
             )

    assert step.return =~ "You are controlling PTC-Lisp through native tool calling."
    assert step.return =~ "run_ptc_lisp"
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
