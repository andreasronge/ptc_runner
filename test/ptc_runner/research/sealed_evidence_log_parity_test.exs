defmodule PtcRunner.Research.SealedEvidenceLog.ParityTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Research.SealedEvidenceLog
  alias PtcRunner.Research.SealedEvidenceLog.Generator
  alias PtcRunner.Research.SealedEvidenceLog.Oracle
  alias PtcRunner.Research.SealedEvidenceLog.Query

  @moduletag :tmp_dir

  test "matches InspectionQuery for every operation on a mixed corpus", %{tmp_dir: tmp} do
    {current, snapshot} = admit_mixed(tmp, "parity-mixed")
    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)

    for operation <- Query.operations() do
      args = args(operation, "parity-mixed")

      assert :ok = Oracle.walk_equal(current, snapshot, operation, args, 1_000_000),
             "operation #{operation} diverged"
    end
  end

  test "covers filter absence, nil, presence, conjunctions, and order", %{tmp_dir: tmp} do
    {current, snapshot} = admit_mixed(tmp, "parity-filters")
    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)

    cases = [
      {:capability_calls, %{"run_id" => "parity-filters"}},
      {:capability_calls, %{"run_id" => "parity-filters", "name" => nil}},
      {:capability_calls, %{"run_id" => "parity-filters", "name" => "search"}},
      {:capability_calls,
       %{"run_id" => "parity-filters", "name" => "search", "mission_name" => "default"}},
      {:generated_sources, %{"run_id" => "parity-filters", "evaluation_id" => "evaluation-1"}},
      {:generated_sources,
       %{
         "run_id" => "parity-filters",
         "evaluation_id" => "evaluation-1",
         "parent_evaluation_id" => "workflow-1"
       }},
      {:generated_sources,
       %{
         "run_id" => "parity-filters",
         "evaluation_id" => "evaluation-1",
         "parent_evaluation_id" => "workflow-2"
       }},
      {:generated_sources, %{"run_id" => "parity-filters", "prelude_call" => "call-1"}},
      {:turns,
       %{
         "run_id" => "parity-filters",
         "evaluation_id" => "evaluation-1",
         "parent_evaluation_id" => "workflow-2"
       }},
      {:model_exchanges, %{"run_id" => "parity-filters", "order" => "desc"}},
      {:execution_prints, %{"run_id" => "parity-filters", "limit" => 1}}
    ]

    for {operation, arguments} <- cases do
      assert :ok = Oracle.walk_equal(current, snapshot, operation, arguments, 1_000_000),
             "#{operation} #{inspect(arguments)} diverged"
    end
  end

  test "enumerates filter absence, nil, presence, and conjunctions", %{tmp_dir: tmp} do
    {current, snapshot} = admit_mixed(tmp, "parity-grid")
    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)

    for {operation, arguments} <- filter_grid("parity-grid") do
      assert :ok = Oracle.walk_equal(current, snapshot, operation, arguments, 1_000_000),
             "#{operation} #{inspect(arguments)} diverged"
    end
  end

  test "result-byte shrinking stays aligned", %{tmp_dir: tmp} do
    corpus = Generator.dense_filter_run("parity-shrink", 8)
    path = Path.join(tmp, "parity-shrink.ptcins")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)

    assert {:ok, snapshot} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts})

    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)

    {:ok, current} =
      Oracle.compile_current([corpus.records], "trace-source", %{
        "trace_snapshot_hash" => "trace-source",
        "runs" => %{"parity-shrink" => corpus.trace_facts}
      })

    assert :ok =
             Oracle.walk_equal(
               current,
               snapshot,
               :generated_sources,
               %{"run_id" => "parity-shrink", "limit" => 8},
               500
             )
  end

  test "rejects invalid filter types and unknown keys", %{tmp_dir: tmp} do
    {current, snapshot} = admit_mixed(tmp, "parity-invalid")
    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)

    assert {:error, :invalid_query} =
             SealedEvidenceLog.query(snapshot, :capability_calls, %{
               "run_id" => "parity-invalid",
               "unknown" => "x"
             })

    assert :ok =
             Oracle.walk_equal(
               current,
               snapshot,
               :capability_calls,
               %{"run_id" => "parity-invalid", "name" => 1},
               1_000_000
             )
  end

  test "multi-run list_runs, get_run, and result", %{tmp_dir: tmp} do
    mixed = Generator.mixed_run("alpha-run")
    other = Generator.second_run("beta-run")
    mixed_path = Path.join(tmp, "alpha.ptcins")
    other_path = Path.join(tmp, "beta.ptcins")
    assert {:ok, _} = SealedEvidenceLog.produce(mixed_path, mixed.records)
    assert {:ok, _} = SealedEvidenceLog.produce(other_path, other.records)

    assert {:ok, snapshot} =
             SealedEvidenceLog.admit([
               %{path: mixed_path, trace_facts: mixed.trace_facts},
               %{path: other_path, trace_facts: other.trace_facts}
             ])

    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)

    {:ok, current} =
      Oracle.compile_current(
        [mixed.records, other.records],
        "trace-source",
        %{
          "trace_snapshot_hash" => "trace-source",
          "runs" => %{
            "alpha-run" => mixed.trace_facts,
            "beta-run" => other.trace_facts
          }
        }
      )

    assert :ok = Oracle.walk_equal(current, snapshot, :list_runs, %{"limit" => 1}, 1_000_000)

    assert :ok =
             Oracle.walk_equal(current, snapshot, :get_run, %{"run_id" => "alpha-run"}, 1_000_000)

    assert :ok =
             Oracle.walk_equal(current, snapshot, :result, %{"run_id" => "alpha-run"}, 1_000_000)

    assert :ok =
             Oracle.walk_equal(current, snapshot, :result, %{"run_id" => "beta-run"}, 1_000_000)
  end

  test "invalid cursor reuse against another query", %{tmp_dir: tmp} do
    {_current, snapshot} = admit_mixed(tmp, "cursor-run")
    on_exit(fn -> SealedEvidenceLog.close(snapshot) end)

    assert {:ok, %{"next_cursor" => cursor}, _metrics} =
             SealedEvidenceLog.query(snapshot, :model_exchanges, %{
               "run_id" => "cursor-run",
               "limit" => 1
             })

    assert is_binary(cursor)

    assert {:error, :invalid_query} =
             SealedEvidenceLog.query(snapshot, :list_runs, %{"limit" => 1, "cursor" => cursor})
  end

  test "cursor from another snapshot is source_changed", %{tmp_dir: tmp} do
    {_current, first} = admit_mixed(tmp, "cursor-a")
    {_current, second} = admit_mixed(tmp, "cursor-b")
    on_exit(fn -> SealedEvidenceLog.close(first) end)
    on_exit(fn -> SealedEvidenceLog.close(second) end)

    assert {:ok, %{"next_cursor" => cursor}, _} =
             SealedEvidenceLog.query(first, :model_exchanges, %{
               "run_id" => "cursor-a",
               "limit" => 1
             })

    assert is_binary(cursor)

    assert {:error, :source_changed} =
             SealedEvidenceLog.query(second, :model_exchanges, %{
               "run_id" => "cursor-b",
               "limit" => 1,
               "cursor" => cursor
             })
  end

  defp admit_mixed(tmp, run_id) do
    corpus = Generator.mixed_run(run_id)
    path = Path.join(tmp, "#{run_id}.ptcins")
    assert {:ok, _} = SealedEvidenceLog.produce(path, corpus.records)

    assert {:ok, snapshot} =
             SealedEvidenceLog.admit(%{path: path, trace_facts: corpus.trace_facts})

    {:ok, current} =
      Oracle.compile_current([corpus.records], "trace-source", corpus.trace_analysis)

    {current, snapshot}
  end

  defp args(:list_runs, _run_id), do: %{"limit" => 10}
  defp args(operation, run_id) when operation in [:get_run, :result], do: %{"run_id" => run_id}
  defp args(_operation, run_id), do: %{"run_id" => run_id, "limit" => 10}

  defp filter_grid(run_id) do
    [
      {:capability_calls, ~w(name mission_name capability_id),
       %{
         "name" => "search",
         "mission_name" => "default",
         "capability_id" => "tool-1"
       }},
      {:generated_sources,
       ~w(evaluation_id parent_evaluation_id mission_name prelude_call prelude_component),
       %{
         "evaluation_id" => "evaluation-1",
         "parent_evaluation_id" => "workflow-1",
         "mission_name" => "default",
         "prelude_call" => "call-1",
         "prelude_component" => "shared.api"
       }},
      {:model_exchanges, ~w(capability_id input_sequence),
       %{"capability_id" => "llm-1", "input_sequence" => 1}},
      {:provider_exchanges, ~w(capability_id mission_name request_id),
       %{"capability_id" => "tool-1", "mission_name" => "default", "request_id" => 1}},
      {:effective_preludes, ~w(component_id environment mission_name),
       %{
         "component_id" => "shared.api",
         "environment" => "mission",
         "mission_name" => "default"
       }},
      {:execution_prints, ~w(evaluation_id), %{"evaluation_id" => "workflow-eval"}},
      {:execution_errors, ~w(evaluation_id), %{"evaluation_id" => "workflow-eval"}},
      {:explicit_failure_values, ~w(evaluation_id), %{"evaluation_id" => "workflow-eval"}},
      {:turns, ~w(stream_id capability_id evaluation_id),
       %{
         "stream_id" => "stream-1",
         "capability_id" => "llm-1",
         "evaluation_id" => "evaluation-1"
       }}
    ]
    |> Enum.flat_map(fn {operation, keys, values} ->
      base = %{"run_id" => run_id}
      absent = [{operation, base}]
      nils = Enum.map(keys, fn key -> {operation, Map.put(base, key, nil)} end)

      presents =
        Enum.map(keys, fn key -> {operation, Map.put(base, key, Map.fetch!(values, key))} end)

      conjunctions =
        (combinations(keys, 2) ++ combinations(keys, 3))
        |> Enum.map(fn pair -> {operation, Map.merge(base, Map.take(values, pair))} end)

      all = [{operation, Map.merge(base, values)}]
      absent ++ nils ++ presents ++ conjunctions ++ all
    end)
  end

  defp combinations(list, 2) do
    for a <- list, b <- list, a < b, do: [a, b]
  end

  defp combinations(list, 3) do
    for a <- list, b <- list, c <- list, a < b, b < c, do: [a, b, c]
  end
end
