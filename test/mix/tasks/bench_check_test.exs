defmodule Mix.Tasks.Bench.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Bench.Check

  setup do
    old_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(old_shell)
      Mix.Task.reenable("bench.check")
    end)

    :ok
  end

  test "writes and checks a temporary baseline" do
    baseline =
      Path.join(System.tmp_dir!(), "ptc-runner-bench-check-#{System.unique_integer()}.json")

    try do
      Check.run([
        "--write-baseline",
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
end
