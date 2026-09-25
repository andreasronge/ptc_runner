defmodule PtcRunner.Kernel.RunCoordinatorExecutionTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.RunCoordinatorExecutionFixture
  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.EventBudget
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.LimitCapacityDiagnostic
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator

  test "provider-free execution returns sealed path-free publication evidence" do
    {prepared, catalog} = prepared_run("(return {\"answer\" 42})")
    assert {:ok, authority} = PublicationAuthority.new([])

    assert {:ok, outcome} = RunCoordinator.execute(prepared, authority)
    assert ExecutionOutcome.valid?(outcome)

    assert {:ok, %{result: {:ok, %{value: %{"answer" => 42}}}, result_class: :normal}} =
             RunBuilder.publish_execution_report(outcome, authority)

    assert :ok = PreparedRun.close(prepared)
    assert :ok = InstallationCatalog.close(catalog)
  end

  test "provider-backed execution uses the one-shot owner and returns sealed evidence" do
    {prepared, catalog, services} = provider_prepared_run()
    assert {:ok, execution} = ProviderExecution.new(catalog, services, [])
    assert ProviderExecution.valid?(execution)
    assert {:ok, authority} = PublicationAuthority.new([])

    assert {:ok, outcome} =
             RunCoordinator.execute(prepared, authority, execution, fn _url ->
               flunk("ordinary provider execution must not notify authorization")
             end)

    assert ExecutionOutcome.valid?(outcome)

    assert {:ok, %{result: {:ok, %{value: %{"answer" => 42}}}, result_class: :normal}} =
             RunBuilder.publish_execution_report(outcome, authority)

    assert :ok = PreparedRun.close(prepared)
    assert :ok = InstallationCatalog.close(catalog)
  end

  test "noninteractive provider execution needs no authorization notifier" do
    {prepared, catalog, services} = provider_prepared_run()
    assert {:ok, execution} = ProviderExecution.new(catalog, services, [])
    assert {:ok, authority} = PublicationAuthority.new([])

    assert {:ok, outcome} = RunCoordinator.execute(prepared, authority, execution, nil)
    assert ExecutionOutcome.valid?(outcome)

    assert :ok = PreparedRun.close(prepared)
    assert :ok = InstallationCatalog.close(catalog)
  end

  test "a run crosses phase 7 before provider activity is marked" do
    # Doctor is not the only caller of the shared step. A run whose audited-local
    # check fails must report the local diagnostic with activity still false, and
    # must never reach the builder behind the marker.
    {prepared, catalog, services} = audited_local_prepared_run(:invalid_llm_model)
    assert {:ok, execution} = ProviderExecution.new(catalog, services, [])
    assert {:ok, authority} = PublicationAuthority.new([])

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             RunCoordinator.execute(prepared, authority, execution, fn _url ->
               flunk("phase 7 must not reach the authorization subphase")
             end)

    assert diagnostic.phase == :local_preflight
    assert diagnostic.code == :adapter_unavailable
    refute diagnostic.provider_activity
    assert_received {:audited_local, "model"}
    refute_received {:builder_invoked, "model"}

    assert :ok = InstallationCatalog.close(catalog)
  end

  test "invalid publication authority does not consume the prepared run" do
    {prepared, catalog} = prepared_run("(return 42)")
    assert {:ok, authority} = PublicationAuthority.new([])
    invalid = Map.put(authority, :output, "relative.json")

    assert {:error, :invalid_publication_authority} =
             RunCoordinator.execute(prepared, invalid)

    assert PreparedRun.valid?(prepared)
    assert :ok = PreparedRun.close(prepared)
    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "an unreserved destination authority is rejected before execution", %{tmp_dir: dir} do
    {prepared, catalog} = prepared_run("(return 42)")

    assert {:ok, authority} =
             PublicationAuthority.new(inspect: Path.join(dir, "unreserved.ptcins"))

    assert {:error, :invalid_publication_authority} =
             RunCoordinator.execute(prepared, authority)

    assert {:error, :invalid_publication_authority} =
             PublicationAuthority.new(trace_dir: Path.join(dir, "traces"))

    assert ProviderActivity.value(prepared.provider_activity) == false
    assert PreparedRun.valid?(prepared)
    assert :ok = PreparedRun.close(prepared)
    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "a terminal publication authority cannot be reused", %{tmp_dir: dir} do
    for terminal <- [:close, :abort] do
      {prepared, catalog} = prepared_run("(return 42)")

      assert {:ok, authority} =
               PublicationAuthority.authorize(
                 "terminal-#{terminal}",
                 [trace: Path.join(dir, "#{terminal}.jsonl")],
                 :normal,
                 :normal
               )

      assert :ok = apply(PublicationAuthority, terminal, [authority])

      assert {:error, :invalid_publication_authority} =
               RunCoordinator.execute(prepared, authority)

      refute ProviderActivity.value(prepared.provider_activity)

      assert :ok = PreparedRun.close(prepared)
      assert :ok = InstallationCatalog.close(catalog)
    end
  end

  test "a claimed publication authority cannot execute a second preparation" do
    {first, first_catalog} = prepared_run("(return 1)")
    {second, second_catalog} = prepared_run("(return 2)")
    assert {:ok, authority} = PublicationAuthority.new([])

    assert {:ok, _outcome} = RunCoordinator.execute(first, authority)
    assert {:error, :invalid_publication_authority} = RunCoordinator.execute(second, authority)
    refute ProviderActivity.value(second.provider_activity)

    assert :ok = PublicationAuthority.abort(authority)
    assert :ok = InstallationCatalog.close(first_catalog)
    assert :ok = PreparedRun.close(second)
    assert :ok = InstallationCatalog.close(second_catalog)
  end

  test "coordinator completion claims an authority before a direct build can reuse it" do
    {first, first_catalog} = prepared_run("(return 1)")
    {second, second_catalog} = prepared_run("(return 2)")
    assert {:ok, authority} = PublicationAuthority.new([])
    assert {:ok, opened_sinks} = RunBuilder.open_prepared_sinks(second, authority, self())
    assert {:ok, registry} = ProviderRegistry.new()

    assert {:ok, built} =
             RunBuilder.build_prepared_owned(second, registry, authority, opened_sinks)

    assert {:ok, _outcome} = RunCoordinator.execute(first, authority)
    assert {:error, :invalid_execution_outcome} = RunBuilder.execute_built(built)

    assert :ok = RunBuilder.close(built.config)
    assert :ok = PublicationAuthority.abort(authority)
    assert :ok = PreparedRun.close(first)
    assert :ok = InstallationCatalog.close(first_catalog)
    assert :ok = PreparedRun.close(second)
    assert :ok = ProviderRegistry.close(registry)
    assert :ok = InstallationCatalog.close(second_catalog)
  end

  test "authority disclosure policy must match the prepared run" do
    {prepared, catalog} = prepared_run("(return 42)", input_authority: :private)

    assert {:ok, authority} =
             PublicationAuthority.authorize("policy-mismatch", [], :normal, :normal)

    assert {:error, :invalid_publication_authority} = RunCoordinator.execute(prepared, authority)
    refute ProviderActivity.value(prepared.provider_activity)

    assert :ok = PreparedRun.close(prepared)
    assert :ok = InstallationCatalog.close(catalog)
  end

  test "owned sinks cannot be rebound to another prepared run" do
    {first, first_catalog} = prepared_run("(return 1)")
    {second, second_catalog} = prepared_run("(return 2)")
    assert {:ok, authority} = PublicationAuthority.new([])
    assert {:ok, opened_sinks} = RunBuilder.open_prepared_sinks(first, authority, self())
    assert {:ok, registry} = ProviderRegistry.new()
    assert :ok = PreparedRun.consume(second)

    rebound = Map.put(opened_sinks, :prepared_binding, second.attestation)

    assert {:error, :invalid_execution_sinks} =
             RunBuilder.build_prepared_owned(second, registry, authority, rebound)

    assert PreparedRun.consumed_valid?(second)
    EventSink.stop(opened_sinks.event_sink)
    assert :ok = PreparedRun.close(first)
    assert :ok = PreparedRun.close(second)
    assert :ok = ProviderRegistry.close(registry)
    assert :ok = InstallationCatalog.close(first_catalog)
    assert :ok = InstallationCatalog.close(second_catalog)
  end

  @tag :tmp_dir
  test "owned sink authority and inspection path cannot be replaced", %{tmp_dir: directory} do
    original_path = Path.join(directory, "original.ptcins")
    replacement_path = Path.join(directory, "occupied.ptcins")
    {prepared, catalog} = prepared_run("(return 1)", inspection_capture: true)

    assert {:ok, original_authority} =
             PublicationAuthority.authorize(
               "original-sink",
               [inspect: original_path],
               :normal,
               :normal
             )

    assert {:ok, replacement_authority} =
             PublicationAuthority.authorize(
               "replacement-sink",
               [inspect: replacement_path],
               :normal,
               :normal
             )

    assert {:ok, opened_sinks} =
             RunBuilder.open_prepared_sinks(prepared, original_authority, self())

    assert {:ok, registry} = ProviderRegistry.new()

    rebound =
      opened_sinks
      |> Map.put(:inspection_path, replacement_path)
      |> Map.put(:publication_binding, PublicationAuthority.binding(replacement_authority))

    assert {:error, :invalid_execution_sinks} =
             RunBuilder.build_prepared_owned(
               prepared,
               registry,
               replacement_authority,
               rebound
             )

    InspectionSink.stop(opened_sinks.inspection_sink)
    EventSink.stop(opened_sinks.event_sink)
    assert :ok = PublicationAuthority.abort(original_authority)
    assert :ok = PublicationAuthority.abort(replacement_authority)
    assert :ok = PreparedRun.close(prepared)
    assert :ok = ProviderRegistry.close(registry)
    assert :ok = InstallationCatalog.close(catalog)
  end

  test "owned prepared builds are single use" do
    {prepared, catalog} = prepared_run("(return 1)")
    assert {:ok, authority} = PublicationAuthority.new([])
    assert {:ok, opened_sinks} = RunBuilder.open_prepared_sinks(prepared, authority, self())
    assert {:ok, registry} = ProviderRegistry.new()

    assert {:ok, built} =
             RunBuilder.build_prepared_owned(prepared, registry, authority, opened_sinks)

    assert {:error, :invalid_prepared_run} =
             RunBuilder.build_prepared_owned(prepared, registry, authority, opened_sinks)

    assert :ok = RunBuilder.close(built.config)
    assert :ok = PreparedRun.close(prepared)
    assert :ok = ProviderRegistry.close(registry)
    assert :ok = InstallationCatalog.close(catalog)
  end

  test "sink opening rejects a different owner before consuming the prepared run" do
    {prepared, catalog} = prepared_run("(return 1)")
    assert {:ok, authority} = PublicationAuthority.new([])
    parent = self()

    other_owner =
      spawn(fn ->
        receive do
          {:stop, ^parent} -> :ok
        end
      end)

    assert {:error, :invalid_execution_sinks} =
             RunBuilder.open_prepared_sinks(prepared, authority, other_owner)

    assert PreparedRun.valid?(prepared)
    send(other_owner, {:stop, parent})
    assert :ok = PreparedRun.close(prepared)
    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "owned execution preserves inspection and cross-artifact preflight", %{tmp_dir: directory} do
    occupied = Path.join(directory, "occupied.ptcins")
    File.write!(occupied, "occupied")
    {prepared, catalog} = prepared_run("(return 1)", inspection_capture: true)

    assert {:error, :destination_exists} =
             PublicationAuthority.authorize(
               "run-collision",
               [inspect: occupied],
               :normal,
               :normal
             )

    assert ProviderActivity.value(prepared.provider_activity) == false
    assert :ok = PreparedRun.close(prepared)
    assert :ok = InstallationCatalog.close(catalog)

    shared = Path.join(directory, "shared.ptcins")
    {prepared, catalog} = prepared_run("(return 1)", inspection_capture: true)

    assert {:error, {:conflicting_destinations, [:inspect, :output]}} =
             PublicationAuthority.authorize(
               "run-conflict",
               [inspect: shared, output: shared],
               :normal,
               :normal
             )

    assert ProviderActivity.value(prepared.provider_activity) == false
    assert :ok = PreparedRun.close(prepared)
    assert :ok = InstallationCatalog.close(catalog)
  end

  # The refusal is computed after provider assembly, so the active path reports
  # it with provider activity. A code whose catalog policy forbids that value
  # cannot be constructed there, and the run falls back to exit 70.
  test "a terminal capacity refusal is classified on both the provider-free and active paths" do
    {prepared, catalog} = oversized_metadata_prepared_run()
    payload_bytes = EventBudget.minimum_normal_payload_bytes()
    reason = {:terminal_payload_capacity_exceeded, payload_bytes, payload_bytes * 2}

    for provider_activity <- [false, true] do
      assert {:ok, diagnostic} =
               RunBuilder.environment_failure_diagnostic(reason, prepared, provider_activity)

      assert diagnostic.phase == :application
      assert diagnostic.code == :limit_capacity_invalid
      assert diagnostic.exit_status == 3
      assert diagnostic.provider_activity == provider_activity

      assert diagnostic.message ==
               elem(LimitCapacityDiagnostic.message(payload_bytes, payload_bytes * 2), 1)
    end

    assert :ok = PreparedRun.close(prepared)
    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "caller death after a stored success aborts unretrieved publication authority", %{
    tmp_dir: directory
  } do
    {prepared, catalog} = prepared_run("(return 42)")
    trace_path = Path.join(directory, "stored-success.jsonl")

    assert {:ok, authority} =
             PublicationAuthority.authorize(
               "stored-success",
               [trace: trace_path],
               :normal,
               :normal
             )

    parent = self()

    caller =
      spawn(fn ->
        assert {:ok, owner} = ExecutionSessionOwner.start(prepared, authority, self())
        send(parent, {:stored_success_owner, owner})

        receive do
          {:await_raw, token} ->
            send(
              parent,
              {:raw_result, GenServer.call(ExecutionSessionOwner.pid(owner), {token, :await})}
            )

            receive do: (:hold -> :ok)
        end
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:stored_success_owner, owner}, 5_000
    owner_pid = ExecutionSessionOwner.pid(owner)
    owner_ref = Process.monitor(owner_pid)

    assert_eventually(fn ->
      case :sys.get_state(owner_pid) do
        %{result: {:ok, _outcome}} -> true
        _state -> false
      end
    end)

    send(caller, {:await_raw, :sys.get_state(owner_pid).token})
    assert_receive {:raw_result, {:ok, _outcome}}, 5_000

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 5_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}, 5_000

    refute PublicationAuthority.authorized?(authority)
    refute File.exists?(trace_path)
    assert :ok = InstallationCatalog.close(catalog)
  end
end
