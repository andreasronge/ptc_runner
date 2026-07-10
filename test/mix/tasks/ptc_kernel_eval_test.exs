defmodule Mix.Tasks.Ptc.KernelEvalTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ptc.KernelEval

  test "allow-failures never suppresses an infrastructure abort" do
    report = %{aborted: true, abort_reason: "transport_failure", cases: []}

    assert_raise Mix.Error, ~r/kernel eval aborted: transport_failure/, fn ->
      KernelEval.validate_report!(report, true)
    end
  end

  test "allow-failures suppresses only ordinary case failures" do
    report = %{
      aborted: false,
      cases: [
        %{
          status: :fail,
          write_errors: 0,
          expected_turns: 1,
          actual_turns: 1
        }
      ]
    }

    assert :ok = KernelEval.validate_report!(report, true)

    assert_raise Mix.Error, ~r/1 case.*failed/, fn ->
      KernelEval.validate_report!(report, false)
    end
  end

  test "paired reports validate both child variants" do
    passing = %{
      aborted: false,
      variant: "paired",
      reports: [%{cases: []}, %{cases: []}]
    }

    assert :ok = KernelEval.validate_report!(passing, false)

    failing =
      put_in(passing, [:reports, Access.at(1), :cases], [
        %{status: :fail, write_errors: 0, expected_turns: 1, actual_turns: 1}
      ])

    assert_raise Mix.Error, ~r/1 paired case.*failed/, fn ->
      KernelEval.validate_report!(failing, false)
    end
  end

  @tag :tmp_dir
  test "paired task completes after publishing its reports", %{tmp_dir: dir} do
    report = Path.join(dir, "pair.md")
    Mix.Task.reenable("ptc.kernel_eval")

    assert :ok =
             KernelEval.run([
               "--suite",
               "tier2",
               "--seed",
               "17",
               "--paired",
               "--report",
               report
             ])

    assert File.exists?(report)
    assert File.read!(report) =~ "PTC Kernel Tier-2 Paired Eval"
  end
end
