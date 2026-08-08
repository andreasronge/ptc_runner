defmodule PtcRunner.Kernel.ArtifactPublisherTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.RunBuilder

  @tag :tmp_dir
  test "normal publication reports partial ordering and path-free failures", %{tmp_dir: dir} do
    trace = Path.join(dir, "run.jsonl")
    inspection = Path.join(dir, "run.inspection.jsonl")
    output = Path.join(dir, "result.json")
    {built, registry} = build!(dir, "normal-publication", :normal, trace, inspection, output)

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

    assert report.artifact_state == %{
             "trace" => "failed",
             "inspection" => "not_written",
             "result" => "not_written"
           }

    assert report.failed == [:trace]
    assert Enum.sort(report.withheld) == [:inspection, :result]
    assert report.error == {:trace, :partial_write}
    refute inspect(report) =~ dir
    refute File.exists?(trace)
    refute File.exists?(inspection)
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

    assert {:error, report} =
             RunBuilder.publish_execution_report(
               outcome,
               built.publication_authority,
               %{result: hook}
             )

    assert report.artifact_state["result"] == "recovery_written"
    assert report.error == :sync_observed
    assert File.regular?(recovery_path)
    refute File.exists?(output)
    refute inspect(report) =~ dir

    assert :ok = PublicationAuthority.close(built.publication_authority)
    assert File.regular?(recovery_path)
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

    assert {:error, report} =
             RunBuilder.publish_execution_report(
               outcome,
               built.publication_authority,
               %{result: hook}
             )

    assert report.artifact_state["result"] == "finalization_uncertain"
    assert report.error == :result_publication_failed
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

  defp build!(dir, name, policy, trace, inspection, output, result_destination \\ :policy) do
    root = Path.join(dir, name)
    File.mkdir!(root)
    File.write!(Path.join(root, "main.clj"), "(ns main) (defn run [_] (return \"#{name}\"))")

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.clj"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "events" => %{"policy" => Atom.to_string(policy), "run_id" => name}
    }

    manifest_path = Path.join(root, "ptc.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    {:ok, registry} = ProviderRegistry.new()

    opts =
      []
      |> maybe_put(:trace, trace)
      |> maybe_put(:inspect, inspection)
      |> maybe_put(:private_output, output, result_destination == :private_output)
      |> maybe_put(:private_output, output, result_destination == :policy and policy == :private)
      |> maybe_put(:output, output, result_destination == :policy and policy == :normal)

    {:ok, built} = RunBuilder.load_and_build(manifest_path, registry, opts)
    {built, registry}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
  defp maybe_put(opts, _key, _value, false), do: opts
  defp maybe_put(opts, key, value, true), do: Keyword.put(opts, key, value)

  defp received_stages do
    receive do
      {:publication_stage, stage} -> [stage | received_stages()]
    after
      0 -> []
    end
  end
end
