defmodule PtcRunner.Kernel.ArtifactPublisherTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.ArtifactPublisher
  alias PtcRunner.Kernel.CommandRunOutcome
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.ResultArtifact
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.ViewerAdapter
  alias PtcRunner.TestSupport.RunLifecycle

  @tag :tmp_dir
  test "normal publication reports partial ordering and path-free failures", %{tmp_dir: dir} do
    trace = Path.join(dir, "run.jsonl")
    inspection = Path.join(dir, "run.inspection.jsonl")
    output = Path.join(dir, "result.json")
    {built, registry} = build!(dir, "normal-publication", :normal, trace, inspection, output)

    assert {:ok, outcome} = RunBuilder.execute_built(built)
    assert {:ok, evidence} = ExecutionOutcome.open(outcome, built.publication_authority)

    fault = fn
      :after_validation -> {:error, :partial_write}
      _stage -> :ok
    end

    settlement =
      RunBuilder.publish_execution_report(
        outcome,
        built.publication_authority,
        %{trace: fault}
      )

    assert {:error, report} = settlement

    assert report.artifact_state == %{
             "trace" => "failed",
             "inspection" => "not_written",
             "result" => "not_written"
           }

    assert report.failed == [:trace]
    assert Enum.sort(report.withheld) == [:inspection, :result]
    assert report.error == {:trace, :partial_write}

    assert {:error, projected} =
             CommandRunOutcome.project(
               evidence,
               settlement,
               "cmd-00000000000000000000000000",
               false
             )

    assert projected.envelope["status"] == "error"
    assert projected.envelope["error"]["code"] == "trace_publication_failed"
    assert projected.envelope["artifact_state"] == report.artifact_state
    assert projected.envelope["execution"]["state"] == "finished"
    assert projected.envelope["execution"]["outcome"] == "ok"
    refute inspect(report) =~ dir
    refute File.exists?(trace)
    refute File.exists?(inspection)
    refute File.exists?(output)

    assert :ok = PublicationAuthority.abort(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "trace-proven event loss preserves the partial inspection and successful result", %{
    tmp_dir: dir
  } do
    trace = Path.join(dir, "partial.jsonl")
    inspection = Path.join(dir, "partial.inspection.jsonl")
    output = Path.join(dir, "result.json")
    run_id = "partial-publication"
    trace_id = "trace-partial-publication"
    timestamp = "2026-08-11T00:00:00Z"
    counts = %{"capability-started" => 1, "capability-stopped" => 1}
    value = %{"answer" => 42}
    {:ok, encoded} = ResultArtifact.prepare(value, :normal, :normal)
    result_hash = "sha256:" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)

    records = [
      %{
        "schema_version" => 1,
        "run_id" => run_id,
        "trace_id" => trace_id,
        "sequence" => 1,
        "timestamp" => timestamp,
        "record_type" => "capability-input",
        "correlation" => %{"capability_id" => "cap-dropped"},
        "payload" => %{
          "environment" => "mission",
          "name" => "evidence.get",
          "arguments" => %{"id" => 42}
        }
      }
    ]

    events = [
      trace_event(run_id, trace_id, 1, "run-started", %{}),
      trace_event(run_id, trace_id, 2, "events-dropped", %{"counts" => counts}),
      trace_event(run_id, trace_id, 3, "run-stopped", %{
        "outcome" => "ok",
        "reason" => nil,
        "result_hash" => result_hash,
        "usage" => %{"events_dropped" => counts}
      })
    ]

    evidence = %{
      result:
        {:ok, %Result{value: value, usage: %{events_dropped: counts}, evaluation_memory: %{}}},
      result_class: :normal,
      result_contract: :ok,
      terminal_batch: {:ok, events},
      inspection: {:ok, records}
    }

    assert {:ok, authority} =
             PublicationAuthority.authorize(
               "cmd-00000000000000000000000000",
               [trace: trace, inspect: inspection, output: output],
               :normal,
               :normal
             )

    assert {:ok, report} = ArtifactPublisher.publish(evidence, authority)

    assert report.artifact_state == %{
             "trace" => "written",
             "inspection" => "written",
             "result" => "written"
           }

    assert Jason.decode!(File.read!(output)) == value
    assert {:ok, ^records} = InspectionArtifact.load(inspection)
    assert {:ok, _source} = ViewerAdapter.pin_inspection(inspection, {:file, trace})

    trace_types =
      trace
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!(&1)["type"])

    assert trace_types == ["run-started", "events-dropped", "run-stopped"]
    assert :ok = PublicationAuthority.close(authority)
  end

  @tag :tmp_dir
  test "maximum-length capability names remain valid after usage qualification", %{tmp_dir: dir} do
    {built, registry} = build!(dir, "qualified-capability-name", :normal, nil, nil, nil)
    assert {:ok, outcome} = RunBuilder.execute_built(built)
    assert {:ok, evidence} = ExecutionOutcome.open(outcome, built.publication_authority)

    assert {:ok, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority)

    capability_name = "a" <> String.duplicate("b", 127)
    {:ok, %Result{} = result} = evidence.result

    evidence =
      put_in(
        evidence,
        [:result],
        {:ok,
         %Result{
           result
           | usage: put_in(result.usage, [:capability_calls, :workflow], %{capability_name => 1})
         }}
      )

    assert {:ok, projected} =
             CommandRunOutcome.project(
               evidence,
               {:ok, report},
               "cmd-00000000000000000000000000",
               false
             )

    assert projected.envelope["execution"]["usage"]["capability_calls"] == %{
             ("workflow/" <> capability_name) => 1
           }

    assert :ok = PublicationAuthority.close(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "result-contract failure remains primary when trace publication also fails", %{
    tmp_dir: dir
  } do
    trace = Path.join(dir, "contract-failure.jsonl")

    {built, registry} =
      build!(
        dir,
        "contract-and-publication-failure",
        :normal,
        trace,
        nil,
        nil,
        :policy,
        body: ~S|{"answer" "wrong"}|,
        result_schema: %{
          "type" => "object",
          "required" => ["answer"],
          "properties" => %{"answer" => %{"type" => "integer"}}
        }
      )

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    fault = fn
      :after_validation -> {:error, :partial_write}
      _stage -> :ok
    end

    assert {:error, report} =
             RunBuilder.publish_execution_report(
               outcome,
               built.publication_authority,
               %{trace: fault}
             )

    assert {:error, {:result_contract_failed, _details}} = report.error
    assert report.secondary_errors == [{:trace, :partial_write}]
    assert report.failed == [:trace]
    assert Enum.sort(report.withheld) == [:inspection, :result]
    refute Map.has_key?(report, :result)
    refute inspect(report) =~ dir

    assert :ok = PublicationAuthority.abort(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "explicit normal and private trace destinations append across runs", %{tmp_dir: dir} do
    for {policy, suffix} <- [{:normal, ".jsonl"}, {:private, ".private.jsonl"}] do
      trace = Path.join(dir, "append#{suffix}")

      line_counts =
        for index <- 1..2 do
          output = if policy == :private, do: Path.join(dir, "result-#{index}.json"), else: nil

          {built, registry} =
            build!(dir, "append-#{policy}-#{index}", policy, trace, nil, output)

          assert {:ok, outcome} = RunBuilder.execute_built(built)

          assert {:ok, report} =
                   RunBuilder.publish_execution_report(outcome, built.publication_authority)

          assert report.artifact_state["trace"] == "written"
          assert :ok = PublicationAuthority.close(built.publication_authority)
          assert :ok = ProviderRegistry.close(registry)

          trace |> File.read!() |> String.split("\n", trim: true) |> length()
        end

      assert Enum.at(line_counts, 0) > 0
      assert Enum.at(line_counts, 1) == 2 * Enum.at(line_counts, 0)
      assert {:ok, %{mode: mode}} = File.stat(trace)
      if policy == :private, do: assert(Bitwise.band(mode, 0o777) == 0o600)
    end
  end

  @tag :tmp_dir
  test "explicit trace appends reject malformed and oversized existing sources", %{tmp_dir: dir} do
    for {name, source, reason} <- [
          {"malformed", "not-json\n", :malformed_source},
          {"oversized", String.duplicate("x", 8_000_001), :source_limit_exceeded}
        ] do
      trace = Path.join(dir, "#{name}.jsonl")
      File.write!(trace, source)
      {built, registry} = build!(dir, "append-#{name}", :normal, trace, nil, nil)

      assert {:ok, outcome} = RunBuilder.execute_built(built)

      assert {:error, report} =
               RunBuilder.publish_execution_report(outcome, built.publication_authority)

      assert report.error == {:trace, reason}
      assert File.read!(trace) == source

      assert :ok = PublicationAuthority.abort(built.publication_authority)
      assert :ok = ProviderRegistry.close(registry)
    end
  end

  @tag :tmp_dir
  test "existing normal and private traces append without parent create access", %{tmp_dir: dir} do
    for policy <- [:normal, :private] do
      parent = Path.join(dir, "append-parent-#{policy}")
      File.mkdir!(parent)
      trace = Path.join(parent, "trace#{if(policy == :private, do: ".private", else: "")}.jsonl")
      File.write!(trace, "")
      if policy == :private, do: File.chmod!(trace, 0o600)
      File.chmod!(parent, 0o500)

      try do
        output = if policy == :private, do: Path.join(dir, "#{policy}-result.json"), else: nil
        {built, registry} = build!(dir, "append-parent-#{policy}-run", policy, trace, nil, output)

        assert {:ok, outcome} = RunBuilder.execute_built(built)

        assert {:ok, report} =
                 RunBuilder.publish_execution_report(outcome, built.publication_authority)

        assert report.artifact_state["trace"] == "written"

        assert :ok = PublicationAuthority.close(built.publication_authority)
        assert :ok = ProviderRegistry.close(registry)
      after
        File.chmod!(parent, 0o700)
      end
    end
  end

  @tag :tmp_dir
  test "existing trace append uses the file durability boundary", %{tmp_dir: dir} do
    parent = Path.join(dir, "execute-only-parent")
    File.mkdir!(parent)
    trace = Path.join(parent, "trace.jsonl")
    File.write!(trace, "")
    File.chmod!(parent, 0o111)

    try do
      {built, registry} = build!(dir, "execute-only-append", :normal, trace, nil, nil)

      assert {:ok, outcome} = RunBuilder.execute_built(built)

      assert {:ok, report} =
               RunBuilder.publish_execution_report(outcome, built.publication_authority)

      assert report.artifact_state["trace"] == "written"
      assert :ok = PublicationAuthority.close(built.publication_authority)
      assert :ok = ProviderRegistry.close(registry)
    after
      File.chmod!(parent, 0o700)
    end
  end

  @tag :tmp_dir
  test "existing trace append reports a post-sync fault as committed", %{tmp_dir: dir} do
    trace = Path.join(dir, "post-sync.jsonl")
    File.write!(trace, "")
    {built, registry} = build!(dir, "post-sync-trace", :normal, trace, nil, nil)

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:error, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority, %{
               trace: fn
                 :after_sync -> {:error, :sync_observed}
                 _stage -> :ok
               end
             })

    assert report.artifact_state["trace"] == "written"
    assert report.error == {:trace, :publication_committed}
    assert File.stat!(trace).size > 0

    assert :ok = PublicationAuthority.close(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "trace append lock failures are classified without leaking paths", %{tmp_dir: dir} do
    trace = Path.join(dir, "lock-failure.jsonl")
    {built, registry} = build!(dir, "lock-failure", :normal, trace, nil, nil)

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:error, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority, %{
               trace: fn
                 :before_lock -> {:error, :lock_observed}
                 _stage -> :ok
               end
             })

    assert report.artifact_state["trace"] == "failed"
    assert report.error == {:trace, :trace_persistence_failed}
    refute inspect(report) =~ dir
    refute File.exists?(trace)

    assert :ok = PublicationAuthority.abort(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "same-inode trace changes after validation fail closed", %{tmp_dir: dir} do
    trace = Path.join(dir, "same-inode.jsonl")
    File.write!(trace, "")
    {built, registry} = build!(dir, "same-inode", :normal, trace, nil, nil)

    hook = fn
      :after_validation ->
        {:ok, device} = File.open(trace, [:append, :binary])
        :ok = IO.binwrite(device, "not-json\n")
        :ok = File.close(device)
        :ok

      _stage ->
        :ok
    end

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:error, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority, %{
               trace: hook
             })

    assert report.error == {:trace, :source_changed}
    assert report.artifact_state["trace"] == "failed"
    assert File.read!(trace) == "not-json\n"
    refute inspect(report) =~ dir

    assert :ok = PublicationAuthority.abort(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "retained trace publication serializes the direct append writer", %{tmp_dir: dir} do
    trace = Path.join(dir, "serialized.jsonl")
    {built, registry} = build!(dir, "serialized", :normal, trace, nil, nil)
    assert {:ok, outcome} = RunBuilder.execute_built(built)
    test = self()

    direct_event = trace_event("direct", 1, "run-started")

    hook = fn
      :after_validation ->
        task =
          Task.async(fn ->
            send(test, :direct_append_started)
            TraceLog.append_jsonl(trace, [direct_event])
          end)

        receive do
          :direct_append_started ->
            send(test, {:direct_append_task, task})
            :ok
        after
          1_000 -> {:error, :direct_append_not_started}
        end

      _stage ->
        :ok
    end

    assert {:ok, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority, %{
               trace: hook
             })

    assert report.artifact_state["trace"] == "written"
    assert_receive {:direct_append_task, task}, 1_000
    assert :ok = Task.await(task)
    assert {:ok, trace_log} = TraceLog.new(source: {:file, trace})
    assert {:ok, %{"items" => items}} = TraceLog.query(trace_log, :list_runs, %{})
    assert Enum.map(items, & &1["run_id"]) |> Enum.sort() == ["direct", "serialized"]

    assert :ok = PublicationAuthority.close(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "normal observations publish before an unencodable result", %{tmp_dir: dir} do
    trace = Path.join(dir, "unencodable.jsonl")
    inspection = Path.join(dir, "unencodable.inspection.jsonl")
    output = Path.join(dir, "unencodable.json")

    {built, registry} =
      build!(
        dir,
        "unencodable",
        :normal,
        trace,
        inspection,
        output,
        :policy,
        ~S|#{1 2}|
      )

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:error, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority)

    assert match?({:result, {:result_not_json_encodable, _kind}}, report.error)

    assert report.artifact_state == %{
             "trace" => "written",
             "inspection" => "written",
             "result" => "failed"
           }

    assert File.regular?(trace)
    assert File.regular?(inspection)
    refute File.exists?(output)

    assert :ok = PublicationAuthority.abort(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "private publication materializes recovery before final requested result", %{tmp_dir: dir} do
    trace = Path.join(dir, "private.private.jsonl")
    inspection = Path.join(dir, "private.inspection.jsonl")
    output = Path.join(dir, "private-result.json")
    {built, registry} = build!(dir, "private-publication", :private, trace, inspection, output)
    recovery = PublicationAuthority.handles(built.publication_authority) |> Map.fetch!(:recovery)
    recovery_path = PublicationHandle.path(recovery)
    test = self()

    hook = fn stage ->
      send(test, {:publication_stage, stage})
      :ok
    end

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:ok, report} =
             RunBuilder.publish_execution_report(
               outcome,
               built.publication_authority,
               %{trace: hook, inspection: hook, result: hook}
             )

    assert report.artifact_state == %{
             "trace" => "written",
             "inspection" => "written",
             "result" => "written"
           }

    assert received_stages() |> Enum.uniq() |> Enum.sort() ==
             [
               :after_validation,
               :after_encoding,
               :before_write,
               :after_write,
               :after_sync,
               :before_lock,
               :directory_sync,
               :after_publish
             ]
             |> Enum.sort()

    assert File.regular?(trace)
    assert File.regular?(inspection)
    assert Jason.decode!(File.read!(output)) == "private-publication"
    assert {:ok, %{mode: trace_mode}} = File.stat(trace)
    assert {:ok, %{mode: output_mode}} = File.stat(output)
    assert Bitwise.band(trace_mode, 0o777) == 0o600
    assert Bitwise.band(output_mode, 0o777) == 0o600
    refute File.exists?(recovery_path)
    refute inspect(report) =~ dir

    assert :ok = PublicationAuthority.abort(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "private finalization with a lost requested reservation keeps recovery", %{tmp_dir: dir} do
    output = Path.join(dir, "private-result.json")
    {built, registry} = build!(dir, "private-requested-race", :private, nil, nil, output)
    recovery = PublicationAuthority.handles(built.publication_authority) |> Map.fetch!(:recovery)
    recovery_path = PublicationHandle.path(recovery)

    assert :ok = PublicationAuthority.release_requested_result(built.publication_authority)
    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:error, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority)

    assert report.artifact_state["result"] == "recovery_written"
    assert report.error == :result_publication_failed
    assert File.regular?(recovery_path)
    refute File.exists?(output)

    assert :ok = PublicationAuthority.abort(built.publication_authority)
    File.rm!(recovery_path)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "late destination races report a path-free destination collision", %{tmp_dir: dir} do
    trace = Path.join(dir, "late.jsonl")
    {built, registry} = build!(dir, "late-trace-collision", :normal, trace, nil, nil)
    File.write!(trace, "attacker")

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:error, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority)

    assert report.error == {:trace, :destination_collision}
    assert report.artifact_state["trace"] == "failed"
    refute inspect(report) =~ dir

    File.rm!(trace)
    assert :ok = PublicationAuthority.abort(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)

    output = Path.join(dir, "late-result.json")
    {built, registry} = build!(dir, "late-result-collision", :normal, nil, nil, output)

    hook = fn
      :after_sync ->
        File.write!(output, "attacker")
        :ok

      _stage ->
        :ok
    end

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:error, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority, %{
               result: hook
             })

    assert report.error == {:result, :destination_collision}
    assert report.artifact_state["result"] == "failed"
    refute inspect(report) =~ dir

    File.rm!(output)
    assert :ok = PublicationAuthority.abort(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "private recovery cleanup failure never discards the complete value", %{tmp_dir: dir} do
    output = Path.join(dir, "private-result.json")
    {built, registry} = build!(dir, "private-cleanup", :private, nil, nil, output)
    recovery = PublicationAuthority.handles(built.publication_authority) |> Map.fetch!(:recovery)
    recovery_path = PublicationHandle.path(recovery)

    hook = fn
      :after_write ->
        File.rm!(recovery_path)
        File.write!(recovery_path, "replacement")
        {:error, :write_failed}

      _stage ->
        :ok
    end

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:error, report} =
             RunBuilder.publish_execution_report(
               outcome,
               built.publication_authority,
               %{result: hook}
             )

    assert report.error == :recovery_cleanup_failed
    assert report.artifact_state["result"] == "failed"
    assert report.failed == [:result]
    assert File.read!(recovery_path) == "replacement"
    refute File.exists?(output)
    refute inspect(report) =~ dir

    assert :ok = PublicationAuthority.close(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "private recovery rejects same-inode contents added before its write", %{tmp_dir: dir} do
    output = Path.join(dir, "private-result.json")
    {built, registry} = build!(dir, "private-recovery-tamper", :private, nil, nil, output)
    recovery = PublicationAuthority.handles(built.publication_authority) |> Map.fetch!(:recovery)
    recovery_path = PublicationHandle.path(recovery)

    hook = fn
      :before_write ->
        {:ok, device} = File.open(recovery_path, [:append, :binary])
        :ok = IO.binwrite(device, "tampered")
        :ok = File.close(device)
        :ok

      _stage ->
        :ok
    end

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:error, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority, %{
               result: hook
             })

    assert report.error == :recovery_cleanup_failed
    assert report.artifact_state["result"] == "failed"
    assert File.read!(recovery_path) == "tampered"
    refute File.exists?(output)
    refute inspect(report) =~ dir

    assert :ok = PublicationAuthority.close(built.publication_authority)
    File.rm!(recovery_path)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "a post-sync fault preserves the private recovery value", %{tmp_dir: dir} do
    output = Path.join(dir, "private-result.json")
    {built, registry} = build!(dir, "private-post-sync", :private, nil, nil, output)
    recovery = PublicationAuthority.handles(built.publication_authority) |> Map.fetch!(:recovery)
    recovery_path = PublicationHandle.path(recovery)

    hook = fn
      :after_sync -> {:error, :sync_observed}
      _stage -> :ok
    end

    assert {:ok, outcome} = RunBuilder.execute_built(built)
    assert {:ok, evidence} = ExecutionOutcome.open(outcome, built.publication_authority)

    settlement =
      RunBuilder.publish_execution_report(
        outcome,
        built.publication_authority,
        %{result: hook}
      )

    assert {:error, report} = settlement

    assert report.artifact_state["result"] == "recovery_written"
    assert report.error == :sync_observed

    assert {:error, projected} =
             CommandRunOutcome.project(
               evidence,
               settlement,
               "cmd-00000000000000000000000000",
               false
             )

    assert projected.envelope["artifact_state"]["result"] == "recovery_written"
    assert File.regular?(recovery_path)
    refute File.exists?(output)
    refute inspect(report) =~ dir

    assert :ok = PublicationAuthority.close(built.publication_authority)
    assert File.regular?(recovery_path)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "a private recovery collision retains the collision diagnostic", %{tmp_dir: dir} do
    output = Path.join(dir, "private-collision.json")
    {built, registry} = build!(dir, "private-collision", :private, nil, nil, output)
    recovery = PublicationAuthority.handles(built.publication_authority) |> Map.fetch!(:recovery)
    recovery_path = PublicationHandle.path(recovery)

    hook = fn
      :after_sync ->
        File.write!(output, "attacker")
        :ok

      _stage ->
        :ok
    end

    assert {:ok, outcome} = RunBuilder.execute_built(built)
    assert {:ok, evidence} = ExecutionOutcome.open(outcome, built.publication_authority)

    assert {:error, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority, %{
               result: hook
             })

    assert report.artifact_state["result"] == "recovery_written"
    assert report.error == :destination_collision
    settlement = {:error, report}

    assert {:error, projected} =
             CommandRunOutcome.project(
               evidence,
               settlement,
               "cmd-00000000000000000000000000",
               false
             )

    assert projected.envelope["error"]["code"] == "destination_collision"
    assert projected.envelope["artifact_state"]["result"] == "recovery_written"

    File.rm!(output)
    assert :ok = PublicationAuthority.abort(built.publication_authority)
    File.rm!(recovery_path)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "a directory-sync failure reports failed but retains complete recovery", %{tmp_dir: dir} do
    output = Path.join(dir, "private-directory-sync.json")
    {built, registry} = build!(dir, "private-directory-sync", :private, nil, nil, output)
    recovery = PublicationAuthority.handles(built.publication_authority) |> Map.fetch!(:recovery)
    recovery_path = PublicationHandle.path(recovery)

    hook = fn
      :directory_sync -> {:error, :directory_sync_failed}
      _stage -> :ok
    end

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:error, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority, %{
               result: hook
             })

    assert report.error == {:result, :directory_sync_failed}
    assert report.artifact_state["result"] == "failed"
    assert report.failed == [:result]
    assert File.regular?(recovery_path)
    refute File.exists?(output)
    refute inspect(report) =~ dir

    assert :ok = PublicationAuthority.abort(built.publication_authority)
    assert File.regular?(recovery_path)
    File.rm!(recovery_path)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "loss of the recovery name is finalization uncertainty", %{tmp_dir: dir} do
    output = Path.join(dir, "private-result.json")
    {built, registry} = build!(dir, "private-recovery-race", :private, nil, nil, output)
    recovery = PublicationAuthority.handles(built.publication_authority) |> Map.fetch!(:recovery)
    recovery_path = PublicationHandle.path(recovery)

    hook = fn
      :after_sync ->
        File.rm!(recovery_path)
        :ok

      _stage ->
        :ok
    end

    assert {:ok, outcome} = RunBuilder.execute_built(built)
    assert {:ok, evidence} = ExecutionOutcome.open(outcome, built.publication_authority)

    settlement =
      RunBuilder.publish_execution_report(
        outcome,
        built.publication_authority,
        %{result: hook}
      )

    assert {:error, report} = settlement

    assert report.artifact_state["result"] == "finalization_uncertain"
    assert report.error == :result_publication_failed

    assert {:error, projected} =
             CommandRunOutcome.project(
               evidence,
               settlement,
               "cmd-00000000000000000000000000",
               false
             )

    assert projected.envelope["artifact_state"]["result"] == "finalization_uncertain"
    refute File.exists?(output)
    refute File.exists?(recovery_path)
    refute inspect(report) =~ dir

    assert :ok = PublicationAuthority.close(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "private values are withheld when no private result sink was authorized", %{tmp_dir: dir} do
    {built, registry} = build!(dir, "private-no-sink", :private, nil, nil, nil)
    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:error, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority)

    assert report.error == :private_result_requires_private_destination
    assert report.artifact_state["result"] == "not_requested"
    refute Map.has_key?(report, :result)
    refute inspect(report) =~ "private-no-sink"

    assert :ok = PublicationAuthority.abort(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "normal results can use the owner-only private output destination", %{tmp_dir: dir} do
    output = Path.join(dir, "private-result.json")

    {built, registry} =
      build!(dir, "normal-private-output", :normal, nil, nil, output, :private_output)

    assert {:ok, outcome} = RunBuilder.execute_built(built)

    assert {:ok, report} =
             RunBuilder.publish_execution_report(outcome, built.publication_authority)

    assert report.result_class == :normal
    assert report.artifact_state["result"] == "written"
    assert Jason.decode!(File.read!(output)) == "normal-private-output"
    assert {:ok, %{mode: mode}} = File.stat(output)
    assert Bitwise.band(mode, 0o777) == 0o600
    refute Enum.any?(File.ls!(dir), &String.starts_with?(&1, ".ptc-private-result-"))

    assert :ok = PublicationAuthority.close(built.publication_authority)
    assert :ok = ProviderRegistry.close(registry)
  end

  @tag :tmp_dir
  test "closing an unexecuted build releases its reserved destinations", %{tmp_dir: dir} do
    output = Path.join(dir, "reserved-result.json")
    {built, registry} = build!(dir, "reserved-output", :normal, nil, nil, output)

    assert :ok = RunBuilder.close(built)
    refute File.exists?(output)
    assert File.ls!(dir) == ["reserved-output"]

    assert :ok = ProviderRegistry.close(registry)
  end

  defp build!(
         dir,
         name,
         policy,
         trace,
         inspection,
         output,
         result_destination \\ :policy,
         fixture \\ nil
       ) do
    root = Path.join(dir, name)
    File.mkdir!(root)
    {body, result_schema} = fixture_parts(fixture)
    expression = body || "\"#{name}\""
    File.write!(Path.join(root, "main.clj"), "(ns main) (defn run [_] (return #{expression}))")

    if result_schema do
      File.write!(Path.join(root, "result.schema.json"), Jason.encode!(result_schema))
    end

    manifest =
      %{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "main", "path" => "main.clj"}],
          "entry" => "main/run"
        },
        "input" => %{"value" => %{}},
        "events" => %{"policy" => Atom.to_string(policy), "run_id" => name}
      }
      |> maybe_put_result_contract(result_schema)

    manifest_path = Path.join(root, "ptc.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    {:ok, registry} = ProviderRegistry.new()

    opts =
      []
      |> maybe_put(:trace_path, trace)
      |> maybe_put(:inspect, inspection)
      |> maybe_put(:private_output, output, result_destination == :private_output)
      |> maybe_put(:private_output, output, result_destination == :policy and policy == :private)
      |> maybe_put(:output, output, result_destination == :policy and policy == :normal)

    request_opts = [
      installed_limits: registry.installed_limits,
      inspection_capture: is_binary(opts[:inspect])
    ]

    {:ok, built} =
      manifest_path
      |> ApplicationPackage.request_directory(request_opts)
      |> RunLifecycle.build(registry, opts)

    {built, registry}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
  defp maybe_put(opts, _key, _value, false), do: opts
  defp maybe_put(opts, key, value, true), do: Keyword.put(opts, key, value)

  defp maybe_put_result_contract(manifest, nil), do: manifest

  defp maybe_put_result_contract(manifest, _schema) do
    Map.put(manifest, "contracts", %{
      "result_schema" => %{"path" => "result.schema.json"}
    })
  end

  defp fixture_parts(fixture) when is_list(fixture),
    do: {Keyword.get(fixture, :body), Keyword.get(fixture, :result_schema)}

  defp fixture_parts(body), do: {body, nil}

  defp trace_event(run_id, sequence, type) do
    %{
      "schema_version" => 1,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-07-12T12:00:00Z",
      "type" => type,
      "data" => %{}
    }
  end

  defp trace_event(run_id, trace_id, sequence, type, data) do
    %{
      "schema_version" => 1,
      "run_id" => run_id,
      "trace_id" => trace_id,
      "sequence" => sequence,
      "timestamp" => "2026-08-11T00:00:00Z",
      "type" => type,
      "data" => data
    }
  end

  defp received_stages do
    receive do
      {:publication_stage, stage} -> [stage | received_stages()]
    after
      0 -> []
    end
  end
end
