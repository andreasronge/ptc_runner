defmodule PtcRunner.Research.SealedEvidenceLog.FaultTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Research.SealedEvidenceLog
  alias PtcRunner.Research.SealedEvidenceLog.Format
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

  test "truncated evidence before open", %{tmp_dir: tmp} do
    path = Path.join(tmp, "truncated-body.ptcins")
    File.write!(path, Format.encode_header() <> <<0, 1, 2, 3>>)
    assert {:error, :malformed_source} = SealedEvidenceLog.admit(%{path: path, trace_facts: %{}})
  end

  test "truncated footer before open", %{tmp_dir: tmp} do
    {path, _snapshot} = produce_only(tmp, "trunc-footer")
    {:ok, bytes} = File.read(path)
    File.write!(path, binary_part(bytes, 0, byte_size(bytes) - 10))
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
    assert result == {:error, :source_changed}
  end

  test "overwrite during admission returns source_changed", %{tmp_dir: tmp} do
    path = Path.join(tmp, "overwrite-admit.ptcins")
    corpus = Generator.mixed_run("overwrite-admit")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)

    parent = self()

    hook = fn
      :after_frames ->
        File.write!(path, flip_evidence_byte(File.read!(path)))
        send(parent, :overwritten)
        :ok

      _other ->
        :ok
    end

    result =
      SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts},
        during_admission_hook: hook
      )

    assert_receive :overwritten
    assert result == {:error, :source_changed}
  end

  test "truncate during admission returns source_changed", %{tmp_dir: tmp} do
    path = Path.join(tmp, "trunc-admit.ptcins")
    corpus = Generator.mixed_run("trunc-admit")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)
    size = File.stat!(path).size

    parent = self()

    hook = fn
      :after_frames ->
        {:ok, io} = :file.open(path, [:raw, :write, :binary, :read])
        {:ok, _} = :file.position(io, size - 1)
        :ok = :file.truncate(io)
        :ok = :file.close(io)
        send(parent, :truncated)
        :ok

      _other ->
        :ok
    end

    result =
      SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts},
        during_admission_hook: hook
      )

    assert_receive :truncated
    assert result == {:error, :source_changed}
  end

  test "append after admission is observed by the next query", %{tmp_dir: tmp} do
    {path, snapshot} = admit_second(tmp, "after-run")
    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)
    File.write!(path, "x", [:append])

    assert {:error, :source_changed} =
             SealedEvidenceLog.query(snapshot, :list_runs, %{"limit" => 1})
  end

  test "truncate after admission is observed by the next query", %{tmp_dir: tmp} do
    {path, snapshot} = admit_second(tmp, "trunc-after")
    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)
    size = File.stat!(path).size
    {:ok, io} = :file.open(path, [:raw, :write, :binary, :read])
    {:ok, _} = :file.position(io, size - 1)
    :ok = :file.truncate(io)
    :ok = :file.close(io)

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

  test "unrelated overwrite is detected when the range becomes a dependency", %{tmp_dir: tmp} do
    corpus = Generator.mixed_run("unrelated-run")
    path = Path.join(tmp, "unrelated.ptcins")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)

    assert {:ok, snapshot} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts})

    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)

    File.write!(path, flip_evidence_byte(File.read!(path)))

    catalog = SealedEvidenceLog.query(snapshot, :list_runs, %{"limit" => 1})
    assert catalog == {:error, :source_changed} or match?({:ok, _page, _metrics}, catalog)

    assert {:error, :source_changed} =
             SealedEvidenceLog.query(snapshot, :model_exchanges, %{
               "run_id" => "unrelated-run",
               "limit" => 1
             })
  end

  test "get_run observes append after admission", %{tmp_dir: tmp} do
    {path, snapshot} = admit_second(tmp, "get-run-append")
    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)
    File.write!(path, "x", [:append])

    assert {:error, :source_changed} =
             SealedEvidenceLog.query(snapshot, :get_run, %{"run_id" => "get-run-append"})
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

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

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

  test "query caller death cancels the worker and leaves the snapshot usable", %{tmp_dir: tmp} do
    corpus = Generator.second_run("caller-run")
    path = Path.join(tmp, "caller.ptcins")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)
    parent = self()
    {:ok, gate} = Agent.start_link(fn -> :block end)
    on_exit(fn -> if Process.alive?(gate), do: Agent.stop(gate) end)

    hook = fn
      :before_query ->
        send(parent, {:query_worker, self()})

        if Agent.get_and_update(gate, fn
             :block -> {:block, :open}
             other -> {other, other}
           end) == :block do
          receive do
            :never -> :ok
          after
            10_000 -> :ok
          end
        end
    end

    assert {:ok, snapshot} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts},
               query_hook: hook
             )

    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)

    caller =
      spawn(fn ->
        SealedEvidenceLog.query(snapshot, :list_runs, %{"limit" => 1})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:query_worker, worker}, 5_000
    worker_ref = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 5_000

    assert {:ok, %{"items" => [_run]}, _metrics} =
             SealedEvidenceLog.query(snapshot, :list_runs, %{"limit" => 1})
  end

  test "admission caller death cancels the admission worker", %{tmp_dir: tmp} do
    corpus = Generator.mixed_run("admit-caller")
    path = Path.join(tmp, "admit-caller.ptcins")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)
    parent = self()

    hook = fn
      :before_frames ->
        send(parent, {:worker, self()})

        receive do
          :never -> :ok
        after
          10_000 -> :ok
        end

      _other ->
        :ok
    end

    caller =
      spawn(fn ->
        SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts},
          during_admission_hook: hook,
          owner: self()
        )
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:worker, worker}, 5_000
    worker_ref = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 5_000
  end

  test "quota refusal deletes tables and leaves the artifact", %{tmp_dir: tmp} do
    path = Path.join(tmp, "quota.ptcins")
    {:ok, _} = SealedEvidenceLog.produce(path, Generator.count_stream("quota-run", 3))

    assert {:error, :max_records} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()},
               limits: [max_records: 2]
             )

    assert File.exists?(path)

    assert {:ok, snapshot} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()},
               limits: [max_records: 3]
             )

    tables = Snapshot.table_ids(snapshot)
    assert :ok = SealedEvidenceLog.close(snapshot)
    assert Enum.all?(tables, &(:ets.info(&1) == :undefined))
  end

  test "retained-ceiling overrun refuses and cleans up", %{tmp_dir: tmp} do
    path = Path.join(tmp, "retained.ptcins")
    {:ok, _} = SealedEvidenceLog.produce(path, Generator.count_stream("retained-run", 3))

    assert {:error, :max_retained_bytes} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()},
               limits: [max_retained_bytes: 1]
             )
  end

  test "forged snapshot token is rejected", %{tmp_dir: tmp} do
    {_path, snapshot} = admit_second(tmp, "token-run")
    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)
    forged = %{snapshot | token: make_ref()}

    assert {:error, :invalid_snapshot} =
             SealedEvidenceLog.query(forged, :list_runs, %{"limit" => 1})

    assert {:error, :invalid_snapshot} = SealedEvidenceLog.info(forged)
    assert :ok = SealedEvidenceLog.close(forged)
    assert Snapshot.alive?(snapshot)
  end

  test "admission deadline cancels the worker", %{tmp_dir: tmp} do
    corpus = Generator.mixed_run("deadline-run")
    path = Path.join(tmp, "deadline.ptcins")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)

    hook = fn
      :before_frames ->
        receive do
          :never -> :ok
        after
          50 -> :ok
        end

      _other ->
        :ok
    end

    assert {:error, :deadline_exceeded} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts},
               during_admission_hook: hook,
               deadline_ms: 1
             )
  end

  test "query cannot widen the installed result-byte ceiling", %{tmp_dir: tmp} do
    corpus = Generator.mixed_run("result-cap")
    path = Path.join(tmp, "result-cap.ptcins")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)

    assert {:ok, snapshot} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts},
               limits: [max_result_bytes: 100]
             )

    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)

    assert {:error, :result_limit_exceeded} =
             SealedEvidenceLog.query(
               snapshot,
               :capability_calls,
               %{"run_id" => "result-cap", "limit" => 10},
               max_result_bytes: 1_000_000
             )
  end

  defp produce_only(tmp, run_id) do
    corpus = Generator.second_run(run_id)
    path = Path.join(tmp, "#{run_id}.ptcins")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)
    {path, corpus}
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
    offset = 16 + 8
    <<prefix::binary-size(^offset), byte, rest::binary>> = bytes
    <<prefix::binary, Bitwise.bxor(byte, 0xFF), rest::binary>>
  end
end
