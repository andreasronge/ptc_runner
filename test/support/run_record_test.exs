defmodule PtcRunner.TestSupport.RunRecordTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TestSupport.RunRecord

  test "a record carries the split, the seed, and each failure's first line" do
    {:ok, state} = RunRecord.init(seed: 99, max_cases: 4)

    passed = %ExUnit.Test{
      name: :"test passes",
      module: __MODULE__,
      state: nil,
      tags: %{file: __ENV__.file, line: 1}
    }

    failed = %{
      passed
      | name: :"test fails",
        tags: %{file: __ENV__.file, line: 2},
        state:
          {:failed,
           [
             {:error,
              %RuntimeError{
                message: "Assertion failed, no matching message after 2000ms\nmailbox: []"
              }, []},
             {:exit, :shutdown, []}
           ]}
    }

    {:noreply, state} = RunRecord.handle_cast({:test_finished, passed}, state)
    {:noreply, state} = RunRecord.handle_cast({:test_finished, failed}, state)

    record = RunRecord.record(state, %{run: 4_500_000, async: 1_000_000, load: 250_000})

    assert %{
             seed: 99,
             max_cases: 4,
             tests: 2,
             wall_ms: 4_500,
             async_ms: 1_000,
             sync_ms: 3_500,
             load_ms: 250
           } =
             record

    assert [%{name: "test fails", line: 2, message: message}] = record.failures
    assert message == "Assertion failed, no matching message after 2000ms | :shutdown"
    assert Path.type(hd(record.failures).file) == :relative
  end

  @tag :tmp_dir
  test "an unwritable record destination is reported, never raised", %{tmp_dir: directory} do
    blocker = Path.join(directory, "blocker")
    File.write!(blocker, "a file where a directory is needed")
    {:ok, state} = RunRecord.init(run_log: Path.join(blocker, "runs.jsonl"), seed: 1)

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:noreply, ^state} =
                 RunRecord.handle_cast(
                   {:suite_finished, %{run: 1_000, async: nil, load: nil}},
                   state
                 )
      end)

    assert stderr =~ "[run-record] not written to #{blocker}/runs.jsonl"
    refute File.exists?(Path.join(blocker, "runs.jsonl"))
  end

  test "an empty destination records nothing" do
    {:ok, state} = RunRecord.init(run_log: "", seed: 1)
    assert {:noreply, ^state} = RunRecord.handle_cast({:suite_finished, %{run: 1_000}}, state)
  end
end
