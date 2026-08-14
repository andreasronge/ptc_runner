defmodule Mix.Tasks.Bench.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Bench.Check
  alias PtcRunner.Bench.Baseline

  setup do
    old_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(old_shell)
      Mix.Task.reenable("bench.check")
    end)

    :ok
  end

  @tag :nightly
  # This test executes the real matrix twice; the cheap option/provenance tests
  # below remain in the per-commit suite.
  test "writes and checks a temporary baseline" do
    baseline =
      Path.join(System.tmp_dir!(), "ptc-runner-bench-check-#{System.unique_integer()}.json")

    try do
      Check.run([
        "--write-baseline",
        "--reason",
        "test baseline",
        "--baseline",
        baseline,
        "--samples",
        "1",
        "--warmup",
        "0"
      ])

      assert File.exists?(baseline)

      Mix.Task.reenable("bench.check")

      Check.run([
        "--baseline",
        baseline,
        "--samples",
        "1",
        "--warmup",
        "0",
        "--threshold",
        "100.0"
      ])
    after
      File.rm(baseline)
    end
  end

  test "raises when the baseline is missing" do
    baseline = Path.join(System.tmp_dir!(), "missing-ptc-runner-bench-check.json")

    assert_raise Mix.Error, ~r/missing baseline/, fn ->
      Check.run(["--baseline", baseline, "--samples", "1", "--warmup", "0"])
    end
  end

  test "requires a written reason when replacing the baseline" do
    assert_raise Mix.Error, ~r/requires a non-empty --reason/, fn ->
      Check.run(["--write-baseline", "--samples", "1", "--warmup", "0"])
    end
  end

  test "rejects a baseline from another runtime before measuring" do
    baseline =
      Path.join(System.tmp_dir!(), "ptc-runner-bench-provenance-#{System.unique_integer()}.json")

    try do
      provenance = Map.put(Baseline.provenance(), "erts", "mismatched")

      Baseline.write!(baseline, %{
        "version" => 2,
        "reason" => "test mismatch",
        "provenance" => provenance,
        "scenarios" => []
      })

      assert_raise Mix.Error, ~r/baseline runtime does not match.*erts:/s, fn ->
        Check.run(["--baseline", baseline, "--samples", "1", "--warmup", "0"])
      end
    after
      File.rm(baseline)
    end
  end

  test "rejects a baseline whose scenario configuration digest changed before measuring" do
    baseline =
      Path.join(System.tmp_dir!(), "ptc-runner-bench-policy-#{System.unique_integer()}.json")

    try do
      committed = Baseline.read!(Path.join(["bench", "baselines", "lisp_eval.json"]))

      scenarios =
        Enum.map(committed["scenarios"], fn
          %{"name" => "strict_transitive_prelude"} = scenario ->
            Map.put(scenario, "identity_sha256", String.duplicate("0", 64))

          scenario ->
            scenario
        end)

      Baseline.write!(baseline, %{
        committed
        | "provenance" => Baseline.provenance(),
          "scenarios" => scenarios
      })

      assert_raise Mix.Error, ~r/scenario definitions differ/, fn ->
        Check.run(["--baseline", baseline, "--samples", "1", "--warmup", "0"])
      end
    after
      File.rm(baseline)
    end
  end
end
