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
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.SessionTrace
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.TestSupport.PrivateInspectionFixture

  @profile_id "inspection-analysis-v1"

  test "the profile registry is closed and describes fixed private authority" do
    assert AnalysisProfileRegistry.ids() == ["inspection-analysis-v1", "log-analysis-v1"]
    assert {:error, :unsupported_analysis_profile} = AnalysisProfileRegistry.fetch("custom")
    assert {:error, :unsupported_analysis_profile} = AnalysisProfileRegistry.fetch(nil)

    assert {:ok, description} = AnalysisProfileRegistry.description(@profile_id)
    assert description["resources"] |> Map.keys() |> Enum.sort() == ["inspection", "traces"]
    assert description["components"] == ["inspection.core", "log.core"]
    assert description["namespaces"] == ["inspection", "log"]
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

    assert identity["components"] == ["inspection.core", "log.core"]
    assert identity["source_data_class"] == "private_inspection"
    assert identity["result_data_class"] == "private_inspection"
    assert mission.bundle.component_ids == ["inspection.core", "log.core"]
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
