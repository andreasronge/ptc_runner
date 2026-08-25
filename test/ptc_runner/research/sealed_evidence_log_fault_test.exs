defmodule PtcRunner.Research.SealedEvidenceLog.FaultTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Research.SealedEvidenceLog
  alias PtcRunner.Research.SealedEvidenceLog.Generator
  alias PtcRunner.Research.SealedEvidenceLog.Handle
  alias PtcRunner.Research.SealedEvidenceLog.Indexes
  alias PtcRunner.Research.SealedEvidenceLog.Snapshot

  @moduletag :tmp_dir

  test "malformed trailing bytes before open", %{tmp_dir: tmp} do
    path = Path.join(tmp, "trailing.ptcins")
    corpus = Generator.second_run("fault-run")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)
    File.write!(path, File.read!(path) <> <<0, 1, 2, 3>>, [:append])
    assert {:error, :malformed_source} = SealedEvidenceLog.admit(%{path: path, trace_facts: %{}})
  end

  test "append during admission returns source_changed", %{tmp_dir: tmp} do
    path = Path.join(tmp, "mutate.ptcins")
    corpus = Generator.mixed_run("mutate-run")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)

    parent = self()

    hook = fn
      :before_frames ->
        File.write!(path, "x", [:append])
        send(parent, :mutated)
        :ok

      _other ->
        :ok
    end

    result =
      SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts},
        during_admission_hook: hook
      )

    assert_receive :mutated
    assert result in [{:error, :source_changed}, {:error, :malformed_source}]
  end

  test "append after admission is observed by the next query", %{tmp_dir: tmp} do
    {path, snapshot} = admit_second(tmp, "after-run")
    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)
    File.write!(path, "x", [:append])

    assert {:error, :source_changed} =
             SealedEvidenceLog.query(snapshot, :list_runs, %{"limit" => 1})
  end

  test "relevant same-size overwrite returns source_changed", %{tmp_dir: tmp} do
    {path, snapshot} = admit_second(tmp, "overwrite-run")
    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)

    bytes = File.read!(path)
    flipped = flip_evidence_byte(bytes)
    File.write!(path, flipped)

    assert {:error, :source_changed} =
             SealedEvidenceLog.query(snapshot, :execution_prints, %{
               "run_id" => "overwrite-run",
               "limit" => 1
             })
  end

  test "path replacement continues against the pinned handle", %{tmp_dir: tmp} do
    {path, snapshot} = admit_second(tmp, "pinned-run")
    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)

    replacement = Path.join(tmp, "other.ptcins")
    other = Generator.second_run("other-run")
    assert {:ok, _} = SealedEvidenceLog.produce(replacement, other.records)
    File.rm!(path)
    File.rename!(replacement, path)

    assert {:ok, %{"items" => [%{"run_id" => "pinned-run"}]}, _metrics} =
             SealedEvidenceLog.query(snapshot, :list_runs, %{"limit" => 1})
  end

  test "snapshot owner death deletes tables and closes handles", %{tmp_dir: tmp} do
    corpus = Generator.second_run("owner-run")
    path = Path.join(tmp, "owner.ptcins")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)

    owner = spawn(fn -> Process.sleep(:infinity) end)
    owner_ref = Process.monitor(owner)

    assert {:ok, snapshot} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts}, owner: owner)

    tables = Snapshot.table_ids(snapshot)
    {:ok, handles} = Snapshot.handles(snapshot)
    snapshot_ref = Process.monitor(snapshot.pid)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
    assert_receive {:DOWN, ^snapshot_ref, :process, _, _}

    assert Enum.all?(tables, &(:ets.info(&1) == :undefined))
    assert Enum.all?(handles, &(not Handle.usable?(&1)))
  end

  test "normal close deletes tables and handles", %{tmp_dir: tmp} do
    {_path, snapshot} = admit_second(tmp, "close-run")
    tables = Snapshot.table_ids(snapshot)
    {:ok, handles} = Snapshot.handles(snapshot)
    snapshot_ref = Process.monitor(snapshot.pid)

    assert :ok = SealedEvidenceLog.close(snapshot)
    assert_receive {:DOWN, ^snapshot_ref, :process, _, :normal}
    assert Enum.all?(tables, &(:ets.info(&1) == :undefined))
    assert Enum.all?(handles, &(not Handle.usable?(&1)))

    assert Indexes.undefined?(%{
             tables: Map.new(Enum.with_index(tables), fn {tid, i} -> {i, tid} end)
           }) or
             Enum.all?(tables, &(:ets.info(&1) == :undefined))
  end

  test "query caller death leaves the snapshot usable", %{tmp_dir: tmp} do
    {_path, snapshot} = admit_second(tmp, "caller-run")
    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)

    caller =
      spawn(fn ->
        SealedEvidenceLog.query(snapshot, :list_runs, %{"limit" => 1})
      end)

    caller_ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}

    assert {:ok, %{"items" => [_run]}, _metrics} =
             SealedEvidenceLog.query(snapshot, :list_runs, %{"limit" => 1})
  end

  defp admit_second(tmp, run_id) do
    corpus = Generator.second_run(run_id)
    path = Path.join(tmp, "#{run_id}.ptcins")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)

    assert {:ok, snapshot} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts})

    {path, snapshot}
  end

  defp flip_evidence_byte(bytes) do
    # Flip a payload byte that sits after the 16-byte header and 8-byte length.
    offset = 16 + 8
    <<prefix::binary-size(^offset), byte, rest::binary>> = bytes
    <<prefix::binary, Bitwise.bxor(byte, 0xFF), rest::binary>>
  end
end
