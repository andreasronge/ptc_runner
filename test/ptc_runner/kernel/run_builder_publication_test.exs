defmodule PtcRunner.Kernel.RunBuilderPublicationTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder

  @tag :tmp_dir
  test "one-shot publication uses only frozen execution evidence", %{tmp_dir: directory} do
    original_cwd = File.cwd!()
    changed_cwd = Path.join(directory, "changed")
    File.mkdir!(changed_cwd)
    on_exit(fn -> File.cd!(original_cwd) end)

    File.write!(
      Path.join(directory, "main.clj"),
      ~S|(ns main) (defn run [_] (return {"answer" 42}))|
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "events" => %{"policy" => "normal", "run_id" => "publication-class"}
    }

    manifest_path = Path.join(directory, "ptc.json")
    trace_path = Path.join(directory, "run.jsonl")
    inspection_path = Path.join(directory, "run.inspection.jsonl")
    output_path = Path.join(directory, "result.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    {:ok, registry} = ProviderRegistry.new()

    File.cd!(directory)
    opts = [trace_path: "run.jsonl", inspect: "run.inspection.jsonl", output: "result.json"]
    assert {:ok, built} = RunBuilder.load_and_build(manifest_path, registry, opts)
    event_sink_pid = built.config.event_sink.pid
    inspection_sink_pid = built.config.inspection_sink.pid

    assert {:error, :invalid_execution_outcome} =
             RunBuilder.execute_built_claimed(built, {self(), make_ref()})

    assert Process.alive?(event_sink_pid)
    assert Process.alive?(inspection_sink_pid)

    tampered_config = %{built.config | input: %{"tampered" => true}}

    assert {:error, :invalid_execution_outcome} =
             RunBuilder.execute_built(%{built | config: tampered_config})

    assert Process.alive?(event_sink_pid)
    assert Process.alive?(inspection_sink_pid)

    Code.ensure_loaded!(EventSink)
    assert :erlang.trace_pattern({EventSink, :policy, 1}, true, [:local]) == 1
    test = self()
    tracer = spawn_link(fn -> policy_trace_loop(test, 0) end)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      assert {:ok, outcome} = RunBuilder.execute_built(built)
      assert {:error, :invalid_execution_outcome} = RunBuilder.execute_built(built)
      refute Process.alive?(event_sink_pid)
      refute Process.alive?(inspection_sink_pid)
      File.cd!(changed_cwd)

      conflicting_path = Path.join(directory, "substituted.json")

      assert {:ok, substituted_authority} =
               PublicationAuthority.new(trace: conflicting_path, output: conflicting_path)

      assert {:error, :invalid_execution_outcome} =
               RunBuilder.publish_execution_report(outcome, substituted_authority)

      refute File.exists?(conflicting_path)

      assert {:error, :invalid_execution_outcome} =
               RunBuilder.publish_execution_report(outcome, opts)

      assert {:ok, %{result: {:ok, %{value: %{"answer" => 42}}}, result_class: :normal}} =
               RunBuilder.publish_execution_report(outcome, built.publication_authority)

      tracee = self()
      reference = :erlang.trace_delivered(tracee)
      assert_receive {:trace_delivered, ^tracee, ^reference}
      send(tracer, :count)

      # A later sink loss cannot change publication authority when the live
      # policy is read exactly once, at the execution/publication checkpoint.
      assert_receive {:policy_call_count, 1}
      assert File.regular?(trace_path)
      assert {:ok, [_record | _records]} = InspectionArtifact.load(inspection_path)
      assert Jason.decode!(File.read!(output_path)) == %{"answer" => 42}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({EventSink, :policy, 1}, false, [:local])
      send(tracer, :stop)
    end
  end

  @tag :tmp_dir
  test "split execution enforces the contract sealed in the run config", %{tmp_dir: directory} do
    File.write!(
      Path.join(directory, "main.clj"),
      ~S|(ns main) (defn run [_] (return {"answer" "wrong"}))|
    )

    File.write!(
      Path.join(directory, "result.schema.json"),
      Jason.encode!(%{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["answer"],
        "properties" => %{"answer" => %{"type" => "integer"}}
      })
    )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "events" => %{"policy" => "normal", "run_id" => "publication-contract"},
      "contracts" => %{"result_schema" => %{"path" => "result.schema.json"}}
    }

    manifest_path = Path.join(directory, "ptc.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    {:ok, registry} = ProviderRegistry.new()
    assert {:ok, built} = RunBuilder.load_and_build(manifest_path, registry)

    tampered_config = %{built.config | result_contract: nil}

    assert {:error, :invalid_execution_outcome} =
             RunBuilder.execute_built(%{built | config: tampered_config})

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:error, %{error: {:error, {:result_contract_failed, details}}}} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority)

    assert is_map(details)
    assert :ok = RunBuilder.close(built)
    assert :ok = ProviderRegistry.close(registry)
  end

  defp policy_trace_loop(test, count) do
    receive do
      {:trace, _pid, :call, {EventSink, :policy, [_sink]}} ->
        policy_trace_loop(test, count + 1)

      :count ->
        send(test, {:policy_call_count, count})
        policy_trace_loop(test, count)

      :stop ->
        :ok
    end
  end
end
