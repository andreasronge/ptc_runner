defmodule PtcRunner.Kernel.Eval.RunContextTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Eval.RunContext

  @tag :tmp_dir
  test "requires the same clean repository snapshot throughout the run", %{tmp_dir: dir} do
    clean = %{commit: String.duplicate("a", 40), clean: true}
    dirty = %{commit: String.duplicate("a", 40), clean: false}
    {:ok, snapshots} = Agent.start_link(fn -> [clean, clean, dirty] end)

    snapshot_fn = fn ->
      Agent.get_and_update(snapshots, fn
        [snapshot | rest] -> {snapshot, rest}
        [] -> {dirty, []}
      end)
    end

    report = Path.join(dir, "run.md")
    context = RunContext.start!(report, %{suite: "tier2"}, repository_snapshot_fn: snapshot_fn)

    assert :ok = RunContext.validate(context)
    assert {:error, "repository_state_changed"} = RunContext.validate(context)
  end

  @tag :tmp_dir
  test "reserves the attempt manifest exclusively", %{tmp_dir: dir} do
    snapshot = %{commit: String.duplicate("b", 40), clean: true}
    opts = [repository_snapshot_fn: fn -> snapshot end]
    report = Path.join(dir, "run.md")

    assert %RunContext{} = RunContext.start!(report, %{suite: "tier2"}, opts)

    assert_raise ArgumentError, ~r/canonical experiment artifact already exists/, fn ->
      RunContext.start!(report, %{suite: "tier2"}, opts)
    end
  end
end
