defmodule Mix.Tasks.Ptc.KernelFeedbackAbTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ptc.KernelFeedbackAb
  alias PtcRunner.Kernel.Eval.RunContext

  @tag :tmp_dir
  test "writes an aborted report before raising even when failures are allowed", %{tmp_dir: dir} do
    report_path = Path.join(dir, "aborted.md")
    unsafe_path = Path.join(dir, "unsafe.md")
    File.write!(unsafe_path, "old world-readable data")
    File.chmod!(unsafe_path, 0o644)
    snapshot = %{commit: String.duplicate("a", 40), clean: true}

    run_context =
      RunContext.start!(
        report_path,
        %{suite: "feedback_ab"},
        repository_snapshot_fn: fn -> snapshot end
      )

    result = %{
      suite: "mini",
      mode: :live,
      model: "openrouter:test/model",
      requested_model: "deepseek",
      llm_source: "registry",
      evidence_eligible: false,
      preregistered_config: false,
      case_definition_hash: "case-hash",
      complete: false,
      commit: "commit-a",
      runs: 1,
      seed: "test-seed",
      cells: [],
      rows: [
        %{
          replicate: 1,
          case: "arithmetic",
          cell: "A",
          status: :pass,
          action_count: 1,
          eval_count: 1,
          prompt_hash: "prompt",
          feedback_hash: "feedback",
          failure_reason: nil,
          commit: "commit-a",
          value: 42,
          unsafe_trace: []
        }
      ],
      aborted: true,
      abort_reason: {:infrastructure_abort, "arithmetic", 1, "B", "transport_failure"},
      run_context: run_context
    }

    assert_raise Mix.Error, ~r/feedback A\/B shakedown aborted/, fn ->
      KernelFeedbackAb.handle_result!(result,
        report: report_path,
        unsafe_debug_report: unsafe_path,
        allow_failures: true
      )
    end

    report = File.read!(report_path)
    assert report =~ "aborted: true"
    assert report =~ "transport_failure"
    assert report =~ "| 1 | arithmetic | A | pass |"
    assert Bitwise.band(File.stat!(unsafe_path).mode, 0o777) == 0o600

    manifest = Jason.decode!(File.read!(report_path <> ".attempt.json"))
    assert manifest["state"] == "aborted"
  end
end
