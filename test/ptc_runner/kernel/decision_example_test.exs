defmodule PtcRunner.Kernel.DecisionExampleTest do
  use ExUnit.Case, async: true
  @moduletag :operator
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.TraceSnapshot

  @example Path.expand("../../../examples/decision-refund-triage", __DIR__)

  @tag :tmp_dir
  test "ptc run replays decisions as hashed model exchanges", %{tmp_dir: dir} do
    project = copy_example(dir)
    assert {:ok, outcome} = CommandEngine.dispatch(["run", project])
    assert outcome.envelope["result"]["value"]["refund_ticket_ids"] == ["T-1001", "T-1004"]
    assert outcome.envelope["result"]["value"]["decisions"]["T_1001"]["probability"] == 0.95
    assert outcome.envelope["execution"]["usage"]["llm_spend"]["total_cost"]["microunits"] == 28
    artifacts = Path.join(Path.dirname(project), ".ptc")

    assert {:ok, trace} =
             TraceSnapshot.start({:directory, Path.join(artifacts, "traces")}, owner: self())

    assert {:ok, row} =
             TraceSnapshot.query(trace, :get_run, %{"run_id" => outcome.envelope["run_ref"]})

    assert row["decision_calls"] == 1
    assert row["llm_calls"] == 0

    assert {:ok, inspection} =
             InspectionSnapshot.start({:directory, Path.join(artifacts, "inspection")}, trace,
               owner: self()
             )

    on_exit(fn ->
      InspectionSnapshot.stop(inspection)
      TraceSnapshot.stop(trace)
    end)

    assert {:ok, page} =
             InspectionSnapshot.query(inspection, :model_exchanges, %{
               "run_id" => outcome.envelope["run_ref"]
             })

    [trace_path] = Path.wildcard(Path.join([artifacts, "traces", "*.jsonl"]))

    events =
      trace_path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    stopped =
      Enum.find(
        events,
        &(&1["type"] == "capability-stopped" and &1["data"]["name"] == "decision-request")
      )

    assert stopped["data"]["served_model"] == "typesafe/jev-1.13-20260917"
    assert [exchange] = page["items"]
    assert exchange["request_hash"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert exchange["result"]["value"]["model"] == "typesafe/jev-1.13-20260917"
  end

  @tag :tmp_dir
  test "replay honors the host reservation bound before dispatch", %{tmp_dir: dir} do
    project = copy_example(dir)
    host = Path.join(Path.dirname(project), "ptc-host.json")

    config =
      host |> File.read!() |> Jason.decode!() |> Map.put("limits", %{"llm_cost_microusd" => 9999})

    File.write!(host, Jason.encode!(config))
    assert {:error, outcome} = CommandEngine.dispatch(["run", project])
    assert outcome.exit_status == 6
    assert outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
  end

  @tag :tmp_dir
  test "decision replay settles overruns at reported cost and tokens", %{tmp_dir: dir} do
    project = copy_example(dir)
    directory = Path.dirname(project)
    host_path = Path.join(directory, "ptc-host.json")

    host =
      host_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("limits", %{"llm_cost_microusd" => 100_000, "llm_total_tokens" => 20_000})

    File.write!(host_path, Jason.encode!(host))
    fixture_path = Path.join(directory, "replay.jsonl")

    fixture =
      fixture_path
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["response", "usage"], %{
        "input_tokens" => 9000,
        "output_tokens" => 10,
        "cost" => 0.02
      })

    File.write!(fixture_path, Jason.encode!(fixture) <> "\n")
    assert {:error, outcome} = CommandEngine.dispatch(["run", project])
    usage = outcome.envelope["execution"]["usage"]
    assert usage["llm_budget"]["cost"]["charged_microusd"] == 20_000
    assert usage["llm_budget"]["total_tokens"]["charged"] == 9010
    assert usage["capability_calls"]["workflow/decision-request"] == 1
  end

  defp copy_example(dir) do
    dest = Path.join(dir, "example")
    File.cp_r!(@example, dest)
    File.rm_rf!(Path.join(dest, ".ptc"))
    Path.join(dest, "ptc-project.json")
  end
end
