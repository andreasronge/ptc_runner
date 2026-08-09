defmodule PtcRunner.Kernel.InspectionAnalysisProfileTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.AnalysisAssembly
  alias PtcRunner.Kernel.AnalysisDirectory
  alias PtcRunner.Kernel.AnalysisProfileRegistry
  alias PtcRunner.Kernel.AnalysisResources
  alias PtcRunner.Kernel.AnalysisSession
  alias PtcRunner.Kernel.AnalysisSessionBuilder
  alias PtcRunner.Kernel.AnalysisTerminal
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionAnalysisProfile
  alias PtcRunner.Kernel.InspectionCapability
  alias PtcRunner.Kernel.LogAnalysisProfile
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.SessionTrace
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.TestSupport.PrivateInspectionFixture

  @profile_id "inspection-analysis-v2"

  test "the profile registry is closed and describes fixed private authority" do
    assert AnalysisProfileRegistry.ids() == ["inspection-analysis-v2", "log-analysis-v2"]
    assert {:error, :unsupported_analysis_profile} = AnalysisProfileRegistry.fetch("custom")
    assert {:error, :unsupported_analysis_profile} = AnalysisProfileRegistry.fetch(nil)

    assert {:ok, description} = AnalysisProfileRegistry.description(@profile_id)
    assert description["resources"] |> Map.keys() |> Enum.sort() == ["inspection", "traces"]

    assert description["components"] == [
             "cap",
             "inspection.core",
             "inspection.analysis",
             "log.core",
             "log.analysis"
           ]

    assert description["namespaces"] == [
             "cap",
             "inspection",
             "inspection.analysis",
             "log",
             "log.analysis"
           ]

    assert description["source_data_class"] == "private_inspection"
    assert description["result_data_class"] == "private_inspection"

    assert description["frontend"] == %{
             "continue_on_error" => "forbidden",
             "input_modes" => ["interactive"],
             "output_formats" => ["clojure"],
             "private_terminal" => "required"
           }

    assert description["explicit_capabilities"] ==
             InspectionAnalysisProfile.explicit_capabilities()

    {:ok, recipe} = AnalysisProfileRegistry.fetch(@profile_id)

    for input_mode <- [:eval, :load, :script, :stdin] do
      assert {:error, :unsupported_profile_input} =
               AnalysisProfileRegistry.authorize_frontend(recipe, %{
                 input_mode: input_mode,
                 output_format: :clojure,
                 continue_on_error: false,
                 private_terminal: true,
                 terminal_attached: true
               })
    end

    assert {:error, :unsupported_profile_output} =
             AnalysisProfileRegistry.authorize_frontend(recipe, %{
               input_mode: :interactive,
               output_format: :jsonl,
               continue_on_error: false,
               private_terminal: true,
               terminal_attached: true
             })
  end

  test "the private terminal gate runs before any source preflight" do
    resources = %{
      "traces" => "/definitely/missing/private-traces",
      "inspection" => "/definitely/missing/private-inspection"
    }

    assert {:error, :private_terminal_required} =
             AnalysisSessionBuilder.start(
               @profile_id,
               resources,
               {:directory, "/definitely/missing/private-output"}
             )

    refute AnalysisTerminal.attached?()

    assert {:error, :interactive_terminal_required} =
             AnalysisSessionBuilder.start(
               @profile_id,
               resources,
               {:directory, "/definitely/missing/private-output"},
               private_terminal: true
             )
  end

  @tag :tmp_dir
  test "private resource and output lineages must be physically separate", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, traces} = AnalysisDirectory.resolve(fixture.traces)
    {:ok, inspection} = AnalysisDirectory.resolve(fixture.inspection)
    {:ok, output} = AnalysisDirectory.resolve(fixture.output)

    assert AnalysisDirectory.pairwise_separate?([traces, inspection, output])

    nested = Path.join(fixture.traces, "nested")
    File.mkdir!(nested)
    {:ok, nested} = AnalysisDirectory.resolve(nested)
    refute AnalysisDirectory.pairwise_separate?([traces, inspection, nested])

    alias_root = Path.join(root, "alias")
    File.ln_s!(root, alias_root)
    {:ok, aliased_traces} = AnalysisDirectory.resolve(Path.join(alias_root, "traces"))
    refute AnalysisDirectory.pairwise_separate?([traces, inspection, aliased_traces])
  end

  @tag :tmp_dir
  test "profile and manifest capabilities share E1 queries including populated V2 exchanges", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, resources} = capture(fixture)

    on_exit(fn -> AnalysisResources.stop(resources) end)

    {:ok, all_profile_capabilities} = InspectionAnalysisProfile.capabilities(resources)

    profile_capabilities =
      Enum.filter(all_profile_capabilities, &String.starts_with?(&1.name, "inspection-"))

    inspection_snapshot = AnalysisResources.handle(resources, :inspection)

    {:ok, manifest_capabilities} =
      InspectionCapability.from_snapshot(inspection_snapshot, "private")

    arguments = [
      %{"limit" => 10},
      %{"run_id" => fixture.run_id},
      %{"run_id" => fixture.run_id},
      %{"run_id" => fixture.run_id},
      %{"run_id" => fixture.run_id},
      %{"run_id" => fixture.run_id}
    ]

    Enum.zip([profile_capabilities, manifest_capabilities, arguments])
    |> Enum.each(fn {profile, manifest, query} ->
      assert profile.callback.(query) == manifest.callback.(query)
    end)

    provider_exchanges = List.last(profile_capabilities)

    assert {:ok,
            %{
              "items" => [
                %{
                  "request_id" => 7,
                  "request" => %{"method" => "tools/call"},
                  "response" => %{"result" => %{"content" => [_ | _]}}
                }
              ]
            }} = provider_exchanges.callback.(%{"run_id" => fixture.run_id})
  end

  @tag :tmp_dir
  test "PTC-Lisp reaches exact evidence while its analysis trace stays payload-free", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, session, info} = start_internal_session(fixture)
    trace_path = Path.join(fixture.output, info.session_id <> ".jsonl")

    on_exit(fn -> AnalysisSession.stop(session) end)

    state = :sys.get_state(session.pid)
    identity = state.profile.identity
    mission = state.config.mission_environment

    assert identity["components"] == [
             "cap",
             "inspection.core",
             "inspection.analysis",
             "log.core",
             "log.analysis"
           ]

    assert identity["source_data_class"] == "private_inspection"
    assert identity["result_data_class"] == "private_inspection"
    assert mission.bundle.component_ids == identity["components"]
    assert mission.data == %{}

    assert mission.capabilities |> Map.keys() |> Enum.sort() ==
             InspectionAnalysisProfile.explicit_capabilities()

    assert {:ok,
            %{
              status: :ok,
              value: %{"items" => [model_exchange]},
              usage: %{capability_calls: capability_calls} = usage
            }} =
             AnalysisSession.evaluate(
               session,
               ~s|(inspection/model-exchanges "#{fixture.run_id}" nil)|
             )

    refute Map.has_key?(usage, :trace_calls)
    assert capability_calls["inspection-model-exchanges"].used == 1

    assert model_exchange["arguments"] == %{
             "messages" => [%{"content" => "private-prompt-#{fixture.run_id}"}]
           }

    assert model_exchange["result"] == %{
             "status" => "ok",
             "value" => %{"answer" => "private-answer-#{fixture.run_id}"}
           }

    assert {:ok, %{value: %{"items" => [source]}}} =
             AnalysisSession.evaluate(
               session,
               ~s|(inspection/generated-sources "#{fixture.run_id}" nil)|
             )

    assert source["source"] == "(return 42)"

    assert {:ok, %{status: :error, outcome: :failed}} =
             AnalysisSession.evaluate(session, ~S|(inspection/runs {"limit" 1001})|)

    assert {:ok,
            %{
              value: %{
                "complete?" => true,
                "items" => [collected_exchange],
                "pages" => 1,
                "snapshot_hash" => inspection_snapshot_hash
              }
            }} =
             AnalysisSession.evaluate(
               session,
               ~s|(inspection.analysis/all-model-exchanges "#{fixture.run_id}" 2)|
             )

    assert collected_exchange == model_exchange
    assert inspection_snapshot_hash =~ ~r/\Asha256:[0-9a-f]{64}\z/

    assert {:ok, %{value: %{"items" => [exchange]}}} =
             AnalysisSession.evaluate(
               session,
               ~s|(inspection/provider-exchanges "#{fixture.run_id}" nil)|
             )

    assert exchange["response"]["result"]["content"] == [
             %{"type" => "text", "text" => "private-tool-result-#{fixture.run_id}"}
           ]

    assert {:ok, %{lifecycle: :closed}} = AnalysisSession.close(session)
    assert File.regular?(trace_path)

    encoded_trace = File.read!(trace_path)
    refute encoded_trace =~ "private-prompt"
    refute encoded_trace =~ "private-answer"
    refute encoded_trace =~ "private-tool-result"
    refute encoded_trace =~ "inspection/model-exchanges"
    refute encoded_trace =~ "(return 42)"

    assert {:ok, trace} = TraceLog.new(source: {:file, trace_path})

    assert {:ok, %{"items" => [%{"run_id" => analysis_run, "complete" => true}]}} =
             TraceLog.query(trace, :list_runs, %{})

    assert analysis_run == info.session_id
  end

  @tag :tmp_dir
  test "private analysis evaluator errors expose only fixed diagnostics", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, session, _info} = start_internal_session(fixture)
    on_exit(fn -> AnalysisSession.stop(session) end)

    secret = "PRIVATE_ANALYSIS_NOT_CALLABLE"

    assert {:ok,
            %{
              status: :error,
              error: %{
                message: "private evaluation failed; diagnostic withheld by the private" <> _,
                message_redacted?: true
              }
            } = result} = AnalysisSession.evaluate(session, ~s|("#{secret}" 1)|)

    refute inspect(result) =~ secret
  end

  @tag :tmp_dir
  test "a private session reports the analyst's own undefined identifiers", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, session, info} = start_internal_session(fixture)
    on_exit(fn -> AnalysisSession.stop(session) end)

    assert {:ok,
            %{
              status: :error,
              error: %{
                kind: :unbound_var,
                message: message,
                message_redacted?: false
              }
            }} = AnalysisSession.evaluate(session, "(defn- g [x] (* x 3)) (return (g 14))")

    assert message =~ "Undefined variables: defn-, g, x"
    assert message =~ "component source only"

    assert {:ok, %{lifecycle: :closed}} = AnalysisSession.close(session)

    trace_path = Path.join(fixture.output, info.session_id <> ".jsonl")
    encoded_trace = File.read!(trace_path)
    refute encoded_trace =~ "Undefined variables"
    refute encoded_trace =~ "defn-"
  end

  @tag :tmp_dir
  test "resource directories whose artifacts sit one level down are refused", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(Path.join(root, "nested"))
    nested_traces = Path.join(root, "nested-traces")
    nested_inspection = Path.join(root, "nested-inspection")
    File.mkdir_p!(Path.join(nested_traces, "run-tag"))
    File.mkdir_p!(Path.join(nested_inspection, "run-tag"))

    File.cp_r!(fixture.traces, Path.join(nested_traces, "run-tag"))
    File.cp_r!(fixture.inspection, Path.join(nested_inspection, "run-tag"))

    assert {:error, :empty_traces_resource} =
             InspectionAnalysisProfile.capture(
               %{"traces" => nested_traces, "inspection" => fixture.inspection},
               []
             )

    assert {:error, :empty_inspection_resource} =
             InspectionAnalysisProfile.capture(
               %{"traces" => fixture.traces, "inspection" => nested_inspection},
               []
             )

    assert {:error, :empty_traces_resource} =
             LogAnalysisProfile.capture(%{"traces" => nested_traces}, [])

    assert {:ok, resources} = LogAnalysisProfile.capture(%{"traces" => fixture.traces}, [])
    assert {:ok, %{file_count: 1, run_count: 1}} = AnalysisResources.info(resources)
    AnalysisResources.stop(resources)

    assert {:ok, private_resources} = capture(fixture)

    assert {:ok,
            %{
              traces: %{file_count: 1, run_count: 1},
              inspection: %{file_count: 1, run_count: 1}
            }} = AnalysisResources.info(private_resources)

    AnalysisResources.stop(private_resources)
  end

  @tag :tmp_dir
  test "a directory whose only artifact holds no runs is captured, not refused", %{tmp_dir: root} do
    traces = Path.join(root, "traces")
    File.mkdir_p!(traces)
    File.write!(Path.join(traces, "empty.jsonl"), "")

    assert {:ok, resources} = LogAnalysisProfile.capture(%{"traces" => traces}, [])
    assert {:ok, %{file_count: 1, run_count: 0}} = AnalysisResources.info(resources)
    AnalysisResources.stop(resources)
  end

  @tag :tmp_dir
  test "a refused capture leaves no snapshot owner behind", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    empty_inspection = Path.join(root, "empty-inspection")
    File.mkdir_p!(empty_inspection)

    monitoring_before = monitoring_processes()

    assert {:error, :empty_inspection_resource} =
             InspectionAnalysisProfile.capture(
               %{"traces" => fixture.traces, "inspection" => empty_inspection},
               []
             )

    # A live snapshot monitors its owner, so anything that started monitoring
    # this process during the refused capture and is still alive is a leak.
    for pid <- monitoring_processes() -- monitoring_before do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end
  end

  @tag :tmp_dir
  test "session owner death closes both captures and persists an aborted canonical trace", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, session, info} = start_internal_session(fixture)
    state = :sys.get_state(session.pid)
    trace = AnalysisResources.handle(state.resources, :traces)
    inspection = AnalysisResources.handle(state.resources, :inspection)
    trace_path = Path.join(fixture.output, info.session_id <> ".jsonl")

    trace_ref = Process.monitor(trace.pid)
    inspection_ref = Process.monitor(inspection.pid)
    session_trace_ref = Process.monitor(state.session_trace.pid)

    Process.exit(session.pid, :kill)

    assert_receive {:DOWN, ^trace_ref, :process, _, :normal}, 5_000
    assert_receive {:DOWN, ^inspection_ref, :process, _, :normal}, 5_000
    assert_receive {:DOWN, ^session_trace_ref, :process, _, :normal}, 5_000
    assert File.regular?(trace_path)

    contents = File.read!(trace_path)
    refute contents =~ "private-prompt"
    refute contents =~ "private-answer"
  end

  @tag :tmp_dir
  test "malformed, uncorrelated, and replaced private sources fail as a whole", %{tmp_dir: root} do
    for scenario <- [:malformed, :uncorrelated, :replaced] do
      fixture = PrivateInspectionFixture.create!(Path.join(root, Atom.to_string(scenario)))

      inspection_path =
        Path.join(fixture.inspection, fixture.run_id <> ".inspection.jsonl")

      result =
        case scenario do
          :malformed ->
            File.write!(inspection_path, ~s({"private":"private-malformed"))
            capture(fixture)

          :uncorrelated ->
            File.rm!(Path.join(fixture.traces, fixture.run_id <> ".jsonl"))
            capture(fixture)

          :replaced ->
            InspectionAnalysisProfile.capture(
              %{"traces" => fixture.traces, "inspection" => fixture.inspection},
              inspection_capture_hook: fn ->
                File.write!(inspection_path, File.read!(inspection_path) <> "\n")
                :ok
              end
            )
        end

      assert {:error, _reason} = result
      refute inspect(result) =~ "private-malformed"
      refute inspect(result) =~ fixture.inspection
    end
  end

  defp monitoring_processes do
    {:monitored_by, pids} = Process.info(self(), :monitored_by)
    pids
  end

  defp capture(fixture) do
    InspectionAnalysisProfile.capture(
      %{"traces" => fixture.traces, "inspection" => fixture.inspection},
      []
    )
  end

  defp start_internal_session(fixture) do
    {:ok, resources} = capture(fixture)
    limits = InspectionAnalysisProfile.limits()
    run_id = "inspection-analysis-test-" <> Integer.to_string(System.unique_integer([:positive]))
    destination = Path.join(fixture.output, run_id <> ".jsonl")
    reserve = EventSink.terminal_reserve(:normal, limits)

    {:ok, run_state, sink} =
      RunState.start_with_event_sink(
        limits,
        [
          run_id: run_id,
          trace_id: run_id,
          fail_closed: true,
          terminal_reserve: reserve
        ],
        owner: self()
      )

    {:ok, session_trace} =
      SessionTrace.start(limits, destination, run_id,
        owner: self(),
        destination_directory_identity: directory_identity(fixture.output),
        run_state: run_state,
        event_sink: sink
      )

    :ok = RunState.transfer_owner(run_state, session_trace.pid)

    {:ok, %{config: config, profile: profile}} =
      InspectionAnalysisProfile.assemble(resources, sink)

    assembly = AnalysisAssembly.seal(config, profile, resources, session_trace, run_state)
    {:ok, session} = AnalysisSession.start(assembly)
    :ok = AnalysisResources.transfer_owner(resources, session.pid)
    {:ok, info} = AnalysisSession.info(session)
    :ok = SessionTrace.complete_construction(session_trace)
    {:ok, session, info}
  end

  defp directory_identity(directory) do
    stat = File.stat!(directory)
    {stat.major_device, stat.minor_device, stat.inode}
  end
end
