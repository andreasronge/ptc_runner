defmodule PtcRunner.Kernel.RunCoordinatorExecutionTest do
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules
  alias PtcRunner.TestSupport.HostBoundFixture

  test "provider-free execution returns sealed path-free publication evidence" do
    {prepared, catalog} = prepared_run("(return {\"answer\" 42})")
    assert {:ok, authority} = PublicationAuthority.new([])

    assert {:ok, outcome} = RunCoordinator.execute(prepared, authority)
    assert ExecutionOutcome.valid?(outcome)

    assert {:ok, %{value: %{"answer" => 42}}, :normal} =
             RunBuilder.publish_execution(outcome, authority)

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

    assert {:ok, %{value: %{"answer" => 42}}, :normal} =
             RunBuilder.publish_execution(outcome, authority)

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
             PublicationAuthority.new(inspect: Path.join(dir, "unreserved.inspection.jsonl"))

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
    original_path = Path.join(directory, "original.inspection.jsonl")
    replacement_path = Path.join(directory, "occupied.inspection.jsonl")
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

  test "sink-open failure releases the consumed prepared activity" do
    {prepared, catalog} = prepared_run("(return 1)", normal_event_bytes: 1)
    activity = prepared.provider_activity.owner
    activity_ref = Process.monitor(activity)
    assert {:ok, authority} = PublicationAuthority.new([])

    assert {:error, :invalid_event_sink} = RunCoordinator.execute(prepared, authority)
    assert_receive {:DOWN, ^activity_ref, :process, ^activity, :normal}, 5_000

    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "owned execution preserves inspection and cross-artifact preflight", %{tmp_dir: directory} do
    occupied = Path.join(directory, "occupied.inspection.jsonl")
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

    shared = Path.join(directory, "shared.inspection.jsonl")
    {prepared, catalog} = prepared_run("(return 1)", inspection_capture: true)

    assert {:error, :conflicting_destinations} =
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

  @tag :tmp_dir
  test "failed opening finalizes and stops both sinks from the execution owner", %{
    tmp_dir: directory
  } do
    {prepared, catalog} = oversized_metadata_prepared_run()
    inspection_path = Path.join(directory, "failed.inspection.jsonl")

    assert {:ok, authority} =
             PublicationAuthority.authorize(
               "failed-opening",
               [inspect: inspection_path],
               :normal,
               :normal
             )

    trace_calls([
      {EventSink, :start, 3},
      {EventSink, :finalize_and_events, 2},
      {EventSink, :stop, 1},
      {InspectionSink, :start, 1},
      {InspectionSink, :stop, 1}
    ])

    try do
      assert {:ok, owner} = ExecutionSessionOwner.start(prepared, authority, self())
      owner_pid = ExecutionSessionOwner.pid(owner)

      assert {:error, :run_started_metadata_exceeded} = ExecutionSessionOwner.await(owner)

      assert_receive {:trace, ^owner_pid, :call, {EventSink, :start, _arguments}}, 5_000

      assert_receive {:trace, ^owner_pid, :call, {InspectionSink, :start, _arguments}},
                     5_000

      assert_receive {:trace, ^owner_pid, :call,
                      {EventSink, :finalize_and_events,
                       [event_sink, %{outcome: :error, reason: :session_owner_failed}]}},
                     5_000

      assert_receive {:trace, ^owner_pid, :call, {InspectionSink, :stop, [inspection_sink]}},
                     5_000

      assert_receive {:trace, ^owner_pid, :call, {EventSink, :stop, [^event_sink]}}, 5_000

      refute Process.alive?(event_sink.pid)
      refute Process.alive?(inspection_sink.pid)
    after
      stop_trace_calls([
        {EventSink, :start, 3},
        {EventSink, :finalize_and_events, 2},
        {EventSink, :stop, 1},
        {InspectionSink, :start, 1},
        {InspectionSink, :stop, 1}
      ])
    end

    assert :ok = PublicationAuthority.abort(authority)
    assert :ok = InstallationCatalog.close(catalog)
  end

  @tag :tmp_dir
  test "caller death aborts the worker and stops both owner-backed sinks", %{
    tmp_dir: directory
  } do
    {prepared, catalog} =
      prepared_run("(loop [] (recur))", inspection_capture: true)

    inspection_path = Path.join(directory, "run.inspection.jsonl")

    assert {:ok, authority} =
             PublicationAuthority.authorize(
               "caller-death",
               [inspect: inspection_path],
               :normal,
               :normal
             )

    parent = self()

    caller =
      spawn(fn ->
        assert {:ok, owner} = ExecutionSessionOwner.start(prepared, authority, self())
        send(parent, {:execution_owner, owner})
        send(parent, {:execution_result, ExecutionSessionOwner.await(owner)})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:execution_owner, owner}, 5_000
    owner_pid = ExecutionSessionOwner.pid(owner)
    state = :sys.get_state(owner_pid)
    event_sink = state.built.config.event_sink
    inspection_sink = state.built.config.inspection_sink

    assert {:ok, ^owner_pid} = EventSink.owner(event_sink)
    assert {:ok, ^owner_pid} = InspectionSink.owner(inspection_sink)
    assert_eventually(fn -> run_started?(event_sink) end)

    Code.ensure_loaded!(EventSink)
    assert :erlang.trace_pattern({EventSink, :finalize_and_events, 2}, true, [:local]) == 1

    # `owner_pid` runs an infinite `(loop [] (recur))`, so it must still be
    # alive here. If it is not, the run aborted early (a real bug) rather
    # than this check merely losing a race with scheduler delay -- fail with
    # that distinction instead of the opaque ArgumentError `:erlang.trace/3`
    # raises on a dead pid.
    assert Process.alive?(owner_pid),
           "owner #{inspect(owner_pid)} exited before tracing could start; " <>
             "the infinite-loop run ended early instead of merely running late"

    assert :erlang.trace(owner_pid, true, [:call]) == 1

    owner_ref = Process.monitor(owner_pid)
    worker_ref = Process.monitor(state.worker_pid)
    event_sink_ref = Process.monitor(event_sink.pid)
    inspection_sink_ref = Process.monitor(inspection_sink.pid)
    activity_ref = Process.monitor(prepared.provider_activity.owner)

    try do
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}

      assert_receive {:trace, ^owner_pid, :call,
                      {EventSink, :finalize_and_events,
                       [^event_sink, %{outcome: :error, reason: :session_owner_failed} = stopped]}}

      assert is_map(stopped.usage)
      assert_receive {:DOWN, ^worker_ref, :process, _worker, :killed}, 5_000
      assert_receive {:DOWN, ^inspection_sink_ref, :process, _pid, :normal}, 5_000
      assert_receive {:DOWN, ^event_sink_ref, :process, _pid, :normal}, 5_000
      assert_receive {:DOWN, ^activity_ref, :process, _pid, :normal}, 5_000
      assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :normal}, 5_000
      refute_received {:execution_result, _result}
    after
      stop_trace(owner_pid)
      :erlang.trace_pattern({EventSink, :finalize_and_events, 2}, false, [:local])
    end

    assert :ok = PublicationAuthority.abort(authority)
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

  defp prepared_run(body, opts \\ []) do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}}
    }

    {limit_opts, request_opts} = Keyword.split(opts, [:normal_event_bytes])

    manifest =
      case Keyword.fetch(limit_opts, :normal_event_bytes) do
        {:ok, bytes} -> Map.put(manifest, "limits", %{"normal_event_bytes" => bytes})
        :error -> manifest
      end

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] #{body})"
    }

    request_opts = Keyword.merge([result_projection: :json], request_opts)
    assert {:ok, request} = ApplicationPackage.request_memory("ptc.json", documents, request_opts)
    assert {:ok, catalog} = InstallationCatalog.new()
    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    {prepared, catalog}
  end

  defp provider_prepared_run do
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: "owned-v1",
        credential_names: [],
        authorization_mode: :none,
        data_class: :normal,
        accepts_data: [:normal],
        requires: [],
        provides: [],
        destinations: [:workflow],
        workflow_llm?: false,
        connectivity_mode: :none,
        probe_effect: nil,
        selection_validation: :declarative,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :none
      )

    {:ok, capability} =
      Capability.new(
        name: "fixture",
        input_schema: %{"type" => "object", "additionalProperties" => false},
        callback: fn _arguments -> {:ok, %{}} end
      )

    staged = fn _selection, _context ->
      {:ok,
       %{
         credential_names: [],
         preflight: fn -> {:ok, fn %{} -> {:ok, capability} end} end
       }}
    end

    registration = %{
      descriptor: descriptor,
      implementation: %{builder: staged},
      authority: nil
    }

    assert {:ok, catalog} = InstallationCatalog.new(%{"selected" => registration})
    assert {:ok, services} = ProviderRuntimeServices.new()

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => [%{"name" => "selected", "config" => %{}}],
        "mission" => []
      }
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] (return {\"answer\" 42}))"
    }

    assert {:ok, request} =
             ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    {prepared, catalog, services}
  end

  # A host-bound catalog over a shipped source, because nothing else may declare
  # an audited-local check. The callback reports itself so a test can prove both
  # that phase 7 ran and where it stopped.
  defp audited_local_prepared_run(failing) do
    parent = self()
    services = HostBoundFixture.runtime_services()
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :llm,
        installation_revision: "model-v1",
        credential_names: [],
        authorization_mode: :none,
        data_class: :normal,
        accepts_data: [:normal],
        requires: [],
        provides: [],
        destinations: [:workflow],
        workflow_llm?: true,
        connectivity_mode: :probe,
        probe_effect: :metadata,
        selection_validation: :declarative,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :audited_local
      )

    {:ok, capability} =
      Capability.new(
        name: "fixture",
        input_schema: %{"type" => "object", "additionalProperties" => false},
        callback: fn _arguments -> {:ok, %{}} end
      )

    # A host-bound catalog routes its builders through the real host
    # installation, so this one exists to satisfy registration parity and to
    # prove, by never being called, that a failed phase 7 stops before it.
    staged = fn _selection, _context ->
      send(parent, {:builder_invoked, "model"})

      {:ok,
       %{
         credential_names: [],
         preflight: fn -> {:ok, fn %{} -> {:ok, capability} end} end
       }}
    end

    implementation = %{
      builder: staged,
      connectivity_probe: fn _selection, _context, _services -> :ok end,
      local_preflight: fn _selection, _context, _services ->
        send(parent, {:audited_local, "model"})
        if failing, do: {:error, failing}, else: :ok
      end
    }

    registration = %{descriptor: descriptor, implementation: implementation, authority: nil}

    assert {:ok, catalog} =
             InstallationCatalog.new(%{"model" => registration},
               runtime_binding: services.runtime_binding
             )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => [%{"name" => "model", "config" => %{}}],
        "mission" => []
      }
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] (return {\"answer\" 42}))"
    }

    assert {:ok, request} =
             ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    {prepared, catalog, services}
  end

  defp oversized_metadata_prepared_run do
    component_ids = Enum.map(1..96, &"component#{&1}")

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" =>
          [%{"id" => "app", "path" => "main.clj"}] ++
            Enum.map(component_ids, &%{"id" => &1, "path" => "#{&1}.clj"}),
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "limits" => %{"event_payload_bytes" => 5_000}
    }

    documents =
      Map.new(component_ids, &{"#{&1}.clj", "(ns #{&1})"})
      |> Map.put("ptc.json", Jason.encode!(manifest))
      |> Map.put("main.clj", "(ns app) (defn run [_input] (return 42))")

    assert {:ok, request} =
             ApplicationPackage.request_memory("ptc.json", documents, inspection_capture: true)

    assert {:ok, catalog} = InstallationCatalog.new()
    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    {prepared, catalog}
  end

  defp run_started?(sink), do: Enum.any?(EventSink.events(sink), &(&1.type == "run-started"))

  defp stop_trace(pid) do
    :erlang.trace(pid, false, [:call])
  catch
    :error, :badarg -> false
  end

  defp trace_calls(patterns) do
    patterns
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.each(&Code.ensure_loaded!/1)

    assert :erlang.trace(:new_processes, true, [:call]) >= 0
    Enum.each(patterns, &assert(:erlang.trace_pattern(&1, true, [:local]) == 1))
  end

  defp stop_trace_calls(patterns) do
    :erlang.trace(:new_processes, false, [:call])
    Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))
  end
end
