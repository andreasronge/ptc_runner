defmodule PtcRunner.Research.SealedEvidenceLog.LimitsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Research.SealedEvidenceLog
  alias PtcRunner.Research.SealedEvidenceLog.Generator
  alias PtcRunner.Research.SealedEvidenceLog.Limits

  @moduletag :tmp_dir

  test "exact one-over refusal for max_records", %{tmp_dir: tmp} do
    path = Path.join(tmp, "records.ptcins")
    {:ok, _} = SealedEvidenceLog.produce(path, Generator.count_stream("limit-run", 3))

    assert {:error, :max_records} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()},
               limits: [max_records: 2]
             )

    assert {:ok, snapshot} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()},
               limits: [max_records: 3]
             )

    SealedEvidenceLog.close(snapshot)
  end

  test "exact one-over refusal for max_index_entries", %{tmp_dir: tmp} do
    path = Path.join(tmp, "entries.ptcins")
    {:ok, _} = SealedEvidenceLog.produce(path, Generator.count_stream("entry-run", 2))

    assert {:error, :max_index_entries} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()},
               limits: [max_index_entries: 1]
             )
  end

  test "exact one-over refusal for max_logical_index_bytes", %{tmp_dir: tmp} do
    path = Path.join(tmp, "bytes.ptcins")
    {:ok, _} = SealedEvidenceLog.produce(path, Generator.count_stream("bytes-run", 2))

    assert {:error, :max_logical_index_bytes} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()},
               limits: [max_logical_index_bytes: 16]
             )
  end

  test "count ladder accounting grows with records, not payloads", %{tmp_dir: tmp} do
    measurements =
      Enum.map([8, 32], fn count ->
        path = Path.join(tmp, "count-#{count}.ptcins")
        {:ok, _} = SealedEvidenceLog.produce(path, Generator.count_stream("acc-#{count}", count))

        {:ok, snapshot} =
          SealedEvidenceLog.admit(%{path: path, trace_facts: Generator.empty_trace_facts()})

        {:ok, info} = SealedEvidenceLog.info(snapshot)
        SealedEvidenceLog.close(snapshot)
        {count, info.accounting.logical_entries, info.accounting.ets_bytes}
      end)

    [{small_n, small_entries, small_bytes}, {large_n, large_entries, large_bytes}] = measurements
    assert small_entries < large_entries
    assert small_bytes < large_bytes
    assert large_n > small_n
  end

  test "inventory separates host, snapshot, producer, and prototype limits" do
    rows = Limits.inventory()
    classes = MapSet.new(Enum.map(rows, & &1["class"]))

    assert MapSet.subset?(
             MapSet.new([
               :host_facing,
               :snapshot_internal,
               :producer,
               :prototype,
               :maintained_guard
             ]),
             classes
           )

    assert Enum.any?(rows, &(&1["path"] == "install.ptc_inspection_snapshot.ceilings.max_files"))
  end
end
