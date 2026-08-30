defmodule PtcRunner.Kernel.PrivateRunAnalysisProfileTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.AnalysisAssembly
  alias PtcRunner.Kernel.AnalysisDirectory
  alias PtcRunner.Kernel.AnalysisProfileRegistry
  alias PtcRunner.Kernel.AnalysisResources
  alias PtcRunner.Kernel.AnalysisSession
  alias PtcRunner.Kernel.AnalysisSessionBuilder
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.PrivateRunAnalysisProfile
  alias PtcRunner.Kernel.PublicRunAnalysisProfile
  alias PtcRunner.Kernel.RunAnalysisCapability
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.SessionTrace
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.TestSupport.PrivateInspectionFixture

  @profile_id "private-run-analysis-v1"

  test "the profile registry is closed and describes fixed private authority" do
    assert AnalysisProfileRegistry.ids() == [
             "private-run-analysis-v1",
             "private-run-catalog-v1",
             "run-analysis-v1"
           ]

    assert {:error, :unsupported_analysis_profile} = AnalysisProfileRegistry.fetch("custom")
    assert {:error, :unsupported_analysis_profile} = AnalysisProfileRegistry.fetch(nil)

    assert {:ok, description} = AnalysisProfileRegistry.description(@profile_id)
    assert description["resources"] |> Map.keys() |> Enum.sort() == ["inspection", "traces"]

    assert description["components"] == ["cap", "analysis", "prompt.audit"]
    assert description["namespaces"] == ["analysis", "cap", "prompt.audit"]

    assert description["source_data_class"] == "private_inspection"
    assert description["result_data_class"] == "private_inspection"

    assert description["trace_capture_policy"] == "private-authorized-canonical-v1"

    # The declared modes describe the attended path; the private_unattended
    # block describes the rest of the reachable surface, so a caller reading
    # this contract is not told half of it.
    assert description["frontend"] == %{
             "continue_on_error" => "forbidden",
             "input_modes" => ["interactive", "load"],
             "output_formats" => ["clojure"],
             "private_terminal" => "required",
             "private_unattended" => %{
               "input_modes" => ["eval", "load", "script", "stdin"],
               "output_formats" => ["clojure", "jsonl"]
             }
           }

    assert description["explicit_capabilities"] ==
             PrivateRunAnalysisProfile.explicit_capabilities()

    {:ok, recipe} = AnalysisProfileRegistry.fetch(@profile_id)

    assert :ok =
             AnalysisProfileRegistry.authorize_frontend(recipe, %{
               input_mode: :load,
               output_format: :clojure,
               continue_on_error: false,
               private_terminal: true,
               terminal_attached: true
             })

    for input_mode <- [:eval, :script, :stdin] do
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

  @tag :tmp_dir
  test "analysis resources reject trace snapshots from the other authority", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)

    assert {:ok, private_trace} =
             TraceSnapshot.start({:private_authorized_directory, fixture.traces})

    on_exit(fn -> TraceSnapshot.stop(private_trace) end)

    assert {:error, :invalid_analysis_resources} =
             AnalysisResources.new("run-analysis-v1", %{traces: private_trace})

    assert {:ok, normal_trace} = TraceSnapshot.start({:directory, fixture.traces})

    assert {:ok, inspection} =
             InspectionSnapshot.start({:directory, fixture.inspection}, normal_trace)

    on_exit(fn ->
      InspectionSnapshot.stop(inspection)
      TraceSnapshot.stop(normal_trace)
    end)

    assert {:error, :invalid_analysis_resources} =
             AnalysisResources.new("private-run-analysis-v1", %{
               traces: normal_trace,
               inspection: inspection
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

    assert {:error, :interactive_terminal_required} =
             AnalysisSessionBuilder.start(
               @profile_id,
               resources,
               {:directory, "/definitely/missing/private-output"},
               private_terminal: true,
               terminal_attached: false
             )

    assert {:error, :invalid_private_run_analysis_source} =
             AnalysisSessionBuilder.start(
               @profile_id,
               resources,
               {:directory, "/definitely/missing/private-output"},
               private_terminal: true,
               terminal_attached: true
             )
  end

  test "private_unattended is a second authorized destination, mutually exclusive with the terminal" do
    {:ok, recipe} = AnalysisProfileRegistry.fetch(@profile_id)

    base = %{
      output_format: :clojure,
      continue_on_error: false,
      private_terminal: false,
      terminal_attached: false
    }

    # Unattended alone admits every non-interactive input mode.
    for input_mode <- [:eval, :load, :script, :stdin] do
      assert :ok =
               AnalysisProfileRegistry.authorize_frontend(
                 recipe,
                 Map.merge(base, %{input_mode: input_mode, private_unattended: true})
               )
    end

    # ...but not :interactive. Waiting on a human at a keyboard is the one
    # thing "unattended" rules out, and admitting it let
    # `--private-unattended --format jsonl` with no input reach the
    # interactive REPL loop and print its prompt banner into the JSONL
    # stream (#1220).
    assert {:error, :unsupported_profile_input} =
             AnalysisProfileRegistry.authorize_frontend(
               recipe,
               Map.merge(base, %{input_mode: :interactive, private_unattended: true})
             )

    # The reachable surface is what a frontend must consult; the static
    # declaration describes only the attended path, and reading it instead is
    # what skipped the guard that should have caught #1220.
    assert %{input_modes: [:eval, :load, :script, :stdin], output_formats: [:clojure, :jsonl]} =
             AnalysisProfileRegistry.reachable_frontend(recipe, true)

    assert %{input_modes: [:interactive, :load], output_formats: [:clojure]} =
             AnalysisProfileRegistry.reachable_frontend(recipe, false)

    # ...and the machine-readable output format.
    assert :ok =
             AnalysisProfileRegistry.authorize_frontend(
               recipe,
               Map.merge(base, %{
                 input_mode: :eval,
                 output_format: :jsonl,
                 private_unattended: true
               })
             )

    # Neither destination: unchanged behavior.
    assert {:error, :private_terminal_required} =
             AnalysisProfileRegistry.authorize_frontend(
               recipe,
               Map.merge(base, %{input_mode: :interactive, private_unattended: false})
             )

    # Both destinations at once is a conflict, not a silent preference.
    assert {:error, :private_destination_conflict} =
             AnalysisProfileRegistry.authorize_frontend(
               recipe,
               Map.merge(base, %{
                 input_mode: :interactive,
                 private_terminal: true,
                 private_unattended: true,
                 terminal_attached: true
               })
             )

    # A profile that forbids the terminal (run-analysis-v1) forbids unattended too.
    {:ok, log_recipe} = AnalysisProfileRegistry.fetch("run-analysis-v1")

    assert {:error, :private_terminal_unsupported} =
             AnalysisProfileRegistry.authorize_frontend(
               log_recipe,
               Map.merge(base, %{input_mode: :interactive, private_unattended: true})
             )

    # The builder layer mirrors the same matrix for an embedding host.
    resources = %{
      "traces" => "/definitely/missing/private-traces",
      "inspection" => "/definitely/missing/private-inspection"
    }

    assert {:error, :private_destination_conflict} =
             AnalysisSessionBuilder.start(
               @profile_id,
               resources,
               {:directory, "/definitely/missing/private-output"},
               private_terminal: true,
               private_unattended: true
             )

    # Unattended bypasses the terminal-attachment check entirely and reaches
    # source preflight instead - a different, later failure than the gate
    # itself, proving the gate was actually crossed.
    assert {:error, :invalid_private_run_analysis_source} =
             AnalysisSessionBuilder.start(
               @profile_id,
               resources,
               {:directory, "/definitely/missing/private-output"},
               private_unattended: true
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
  test "profile and manifest capabilities share navigation queries", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, resources} = capture(fixture)

    on_exit(fn -> AnalysisResources.stop(resources) end)

    {:ok, all_profile_capabilities} = PrivateRunAnalysisProfile.capabilities(resources)

    {:ok, manifest_capabilities} =
      RunAnalysisCapability.from_snapshots(
        AnalysisResources.handle(resources, :traces),
        AnalysisResources.handle(resources, :inspection),
        "private"
      )

    arguments = [
      %{"limit" => 10},
      %{"run_id" => fixture.run_id},
      %{"run_id" => fixture.run_id, "collection" => "provider_exchanges"},
      %{}
    ]

    Enum.zip([all_profile_capabilities, manifest_capabilities, arguments])
    |> Enum.each(fn {profile, manifest, query} ->
      assert profile.callback.(query) == manifest.callback.(query)
    end)

    read = Enum.find(all_profile_capabilities, &(&1.name == "analysis-read"))

    assert {:ok,
            %{
              "items" => [
                %{
                  "request_id" => 7,
                  "request" => %{"method" => "tools/call"},
                  "response" => %{"result" => %{"content" => [_ | _]}}
                }
              ]
            }} =
             read.callback.(%{
               "run_id" => fixture.run_id,
               "collection" => "provider_exchanges"
             })
  end

  @tag :tmp_dir
  test "PTC-Lisp follows typed boundary relations without collection scans", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create_boundary_failure!(root)
    {:ok, session, _info} = start_internal_session(fixture)
    on_exit(fn -> AnalysisSession.stop(session) end)

    program = ~S"""
    (let [run-id "RUN_ID"
          error (first (get (analysis/read run-id {"collection" "execution_errors"}) "items"))
          error-relations (get error "relationships")
          producer-rel (first (filter (fn [relation]
                                        (= (get relation "rel") "direct_boundary_producer"))
                                      error-relations))
          source-rel (first (filter (fn [relation]
                                      (= (get relation "rel") "generated_source"))
                                    error-relations))
          producer (first (get (analysis/read run-id
                                              (assoc (get producer-rel "filters")
                                                     "collection"
                                                     (get producer-rel "target_collection")))
                               "items"))
          source (first (get (analysis/read run-id
                                            (assoc (get source-rel "filters")
                                                   "collection"
                                                   (get source-rel "target_collection")))
                             "items"))
          source-relations (get source "relationships")
          turn-rel (first (filter (fn [relation]
                                    (= (get relation "rel") "producing_turn"))
                                  source-relations))
          prelude-rel (first (filter (fn [relation]
                                       (= (get relation "rel") "referenced_prelude_source"))
                                     source-relations))
          turn (first (get (analysis/read run-id
                                          (assoc (get turn-rel "filters")
                                                 "collection"
                                                 (get turn-rel "target_collection")))
                           "items"))
          prelude (first (get (analysis/read run-id
                                             (assoc (get prelude-rel "filters")
                                                    "collection"
                                                    (get prelude-rel "target_collection")))
                              "items"))]
      (return {"error_reason" (get error "reason")
               "producer_status" (get (get producer "data") "status")
               "source" (get source "source")
               "turn" (get turn "turn")
               "prelude_component" (get prelude "component_id")}))
    """

    program = String.replace(program, "RUN_ID", fixture.run_id)

    assert {:ok,
            %{
              status: :ok,
              value: %{
                "error_reason" => "terminal_result_exceeded",
                "producer_status" => "returned",
                "source" => "(return 42)",
                "turn" => 1,
                "prelude_component" => "mission-component-" <> _
              },
              usage: %{capability_calls: capability_calls}
            }} = AnalysisSession.evaluate(session, program)

    assert capability_calls["analysis-read"].used == 5
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
    mission = state.config.missions["default"].environment

    assert identity["components"] == ["cap", "analysis"]

    assert identity["source_data_class"] == "private_inspection"
    assert identity["result_data_class"] == "private_inspection"
    assert identity["trace_capture_policy"] == "private-authorized-canonical-v1"

    {:ok, old_identity_encoding} =
      identity
      |> Map.delete("trace_capture_policy")
      |> DeterministicJSON.encode()

    old_profile_digest =
      "sha256:" <>
        (:crypto.hash(:sha256, old_identity_encoding) |> Base.encode16(case: :lower))

    refute info.profile_digest == old_profile_digest
    assert mission.bundle.component_ids == identity["components"]
    assert mission.data == %{}

    assert mission.capabilities |> Map.keys() |> Enum.sort() ==
             PrivateRunAnalysisProfile.explicit_capabilities()

    assert {:ok,
            %{
              status: :ok,
              value: %{
                "items" => [%{"messages_added" => messages, "response" => model_result}]
              },
              usage: %{capability_calls: capability_calls} = usage
            }} =
             AnalysisSession.evaluate(
               session,
               ~s|(analysis/read "#{fixture.run_id}" {"collection" "turns"})|
             )

    refute Map.has_key?(usage, :trace_calls)
    assert capability_calls["analysis-read"].used == 1

    assert messages == [%{"content" => "private-prompt-#{fixture.run_id}"}]

    assert model_result == %{
             "status" => "ok",
             "value" => %{
               "answer" => "private-answer-#{fixture.run_id}",
               "tool_calls" => [
                 %{"id" => "program-#{fixture.run_id}", "args" => %{"program" => "(return 42)"}}
               ]
             }
           }

    assert {:ok, %{value: %{"items" => [source]}}} =
             AnalysisSession.evaluate(
               session,
               ~s|(analysis/read "#{fixture.run_id}" {"collection" "generated_sources"})|
             )

    assert source["source"] == "(return 42)"

    assert {:ok, %{status: :error, outcome: :failed}} =
             AnalysisSession.evaluate(session, ~S|(analysis/runs {"limit" 1001})|)

    assert {:ok, %{value: %{"items" => [exchange]}}} =
             AnalysisSession.evaluate(
               session,
               ~s|(analysis/read "#{fixture.run_id}" {"collection" "provider_exchanges"})|
             )

    assert exchange["response"]["result"]["content"] == [
             %{"type" => "text", "text" => "private-tool-result-#{fixture.run_id}"}
           ]

    execution_id = "workflow-eval-#{fixture.run_id}"
    execution_print = "private-print-#{fixture.run_id}"

    assert {:ok,
            %{
              value: %{
                "items" => [
                  %{"evaluation_id" => ^execution_id, "prints" => [^execution_print]}
                ]
              }
            }} =
             AnalysisSession.evaluate(
               session,
               ~s|(analysis/read "#{fixture.run_id}" {"collection" "execution_prints"})|
             )

    assert {:ok,
            %{
              value: %{
                "items" => [
                  %{
                    "evaluation_id" => ^execution_id,
                    "kind" => "limit_exceeded",
                    "reason" => "timeout"
                  }
                ]
              }
            }} =
             AnalysisSession.evaluate(
               session,
               ~s|(analysis/read "#{fixture.run_id}" {"collection" "execution_errors"})|
             )

    assert {:ok, %{lifecycle: :closed}} = AnalysisSession.close(session)
    assert File.regular?(trace_path)

    encoded_trace = File.read!(trace_path)
    refute encoded_trace =~ "private-prompt"
    refute encoded_trace =~ "private-answer"
    refute encoded_trace =~ "private-tool-result"
    refute encoded_trace =~ "analysis/read"
    refute encoded_trace =~ "(return 42)"

    assert {:ok, trace} = TraceLog.new(source: {:file, trace_path})

    assert {:ok, %{"items" => [%{"run_id" => analysis_run, "complete" => true}]}} =
             TraceLog.query(trace, :list_runs, %{})

    assert analysis_run == info.session_id
  end

  @tag :tmp_dir
  test "private analysis returns a retained-bounded model exchange page", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create_model_exchanges!(root)
    {:ok, session, _info} = start_internal_session(fixture)
    on_exit(fn -> AnalysisSession.stop(session) end)

    assert {:ok,
            %{
              status: :ok,
              value: %{
                "count" => count,
                "cursor" => cursor,
                "truncated" => true
              }
            }} =
             AnalysisSession.evaluate(
               session,
               """
               (let [page (analysis/read "#{fixture.run_id}" {"collection" "model_exchanges"})]
                 (return {"count" (count (get page "items"))
                          "cursor" (get page "next_cursor")
                          "truncated" (get page "truncated")}))
               """
             )

    assert count in 1..(fixture.model_exchange_count - 1)
    assert is_binary(cursor)
  end

  @tag :tmp_dir
  test "PTC-Lisp returns an exact successful terminal value and its canonical hash", %{
    tmp_dir: root
  } do
    value = %{"answer" => 42, "nested" => [true, nil, "done"]}
    fixture = PrivateInspectionFixture.create_result!(root, value)
    {:ok, session, _info} = start_internal_session(fixture)
    on_exit(fn -> AnalysisSession.stop(session) end)

    assert {:ok,
            %{
              status: :ok,
              value: %{
                "run" => %{"run_id" => run_id},
                "result" => %{
                  "result_hash" => result_hash,
                  "value" => ^value,
                  "snapshot_hash" => snapshot_hash
                }
              }
            }} = AnalysisSession.evaluate(session, ~s|(analysis/open "#{fixture.run_id}")|)

    assert run_id == fixture.run_id
    assert result_hash == fixture.result_hash
    assert snapshot_hash =~ ~r/\Asha256:[0-9a-f]{64}\z/
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
  test "a private session admits pre-execution arity and form diagnostics", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, session, info} = start_internal_session(fixture)
    on_exit(fn -> AnalysisSession.stop(session) end)

    assert {:ok,
            %{
              status: :error,
              error: %{
                kind: :invalid_arity,
                message: arity_message,
                message_redacted?: false,
                capability_activity?: false
              }
            }} = AnalysisSession.evaluate(session, "(defn foo)")

    assert arity_message =~ "expected (defn name [params] body)"
    refute arity_message =~ "private result policy"

    assert {:ok,
            %{
              status: :error,
              error: %{
                kind: :invalid_form,
                message: form_message,
                message_redacted?: false,
                capability_activity?: false
              }
            }} = AnalysisSession.evaluate(session, "(let [x] x)")

    assert form_message =~ "even number of forms"
    refute form_message =~ "private result policy"

    assert {:ok,
            %{
              status: :error,
              error: %{
                kind: :parse_error,
                message: parse_message,
                message_redacted?: false,
                capability_activity?: false
              }
            }} = AnalysisSession.evaluate(session, "(unclosed")

    assert is_binary(parse_message) and parse_message != ""
    refute parse_message =~ "private result policy"

    assert {:ok, %{lifecycle: :closed}} = AnalysisSession.close(session)

    encoded_trace = File.read!(Path.join(fixture.output, info.session_id <> ".jsonl"))
    refute encoded_trace =~ "expected (defn name [params] body)"
    refute encoded_trace =~ "even number of forms"
    refute encoded_trace =~ parse_message
  end

  @tag :tmp_dir
  test "a private session names a prelude arity fault without opening evidence", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, session, _info} = start_internal_session(fixture)
    on_exit(fn -> AnalysisSession.stop(session) end)

    # Same shape as the operator detour in #1175: analysis/runs takes one options
    # map, while analysis/read takes [run-id options]. Calling read the way runs
    # is taught is an analyzer arity fault before any capability executes.
    assert {:ok,
            %{
              status: :error,
              error: %{
                kind: :invalid_arity,
                message: message,
                message_redacted?: false,
                capability_activity?: false
              }
            }} = AnalysisSession.evaluate(session, ~s|(analysis/read "x")|)

    assert message =~ "argument"
    refute message =~ "private result policy"
  end

  @tag :tmp_dir
  test "a private session redacts a post-capability arity fault of an allowlisted kind", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, session, _info} = start_internal_session(fixture)
    on_exit(fn -> AnalysisSession.stop(session) end)

    # `invalid_arity` also has runtime producers. In the same evaluation that
    # opens a private record, the activity flag must keep that path redacted.
    source = ~s|(do (analysis/open "#{fixture.run_id}") (apply pmap [inc]))|

    assert {:ok,
            %{
              status: :error,
              error: %{
                kind: :invalid_arity,
                message: message,
                message_redacted?: true,
                capability_activity?: true
              }
            }} = AnalysisSession.evaluate(session, source)

    assert message ==
             "private evaluation failed; diagnostic withheld by the private result policy"
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
             PrivateRunAnalysisProfile.capture(
               %{"traces" => nested_traces, "inspection" => fixture.inspection},
               []
             )

    assert {:error, :empty_inspection_resource} =
             PrivateRunAnalysisProfile.capture(
               %{"traces" => fixture.traces, "inspection" => nested_inspection},
               []
             )

    assert {:error, :empty_traces_resource} =
             PublicRunAnalysisProfile.capture(%{"traces" => nested_traces}, [])

    assert {:ok, resources} = PublicRunAnalysisProfile.capture(%{"traces" => fixture.traces}, [])
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
  test "a directory whose only artifact is empty is captured with isolation evidence", %{
    tmp_dir: root
  } do
    traces = Path.join(root, "traces")
    File.mkdir_p!(traces)
    File.write!(Path.join(traces, "empty.jsonl"), "")

    assert {:ok, resources} = PublicRunAnalysisProfile.capture(%{"traces" => traces}, [])
    assert {:ok, %{file_count: 1, run_count: 0}} = AnalysisResources.info(resources)

    trace = AnalysisResources.handle(resources, :traces)

    assert {:ok, %{"items" => [], "isolation" => isolation}} =
             TraceSnapshot.query(trace, :list_runs, %{})

    assert isolation["component_count"] == 1
    assert isolation["known_run_count"] == 1

    assert isolation["reasons"] == [
             %{
               "reason" => "malformed_jsonl",
               "component_count" => 1,
               "source_count" => 1
             }
           ]

    AnalysisResources.stop(resources)
  end

  @tag :tmp_dir
  test "a refused capture leaves no snapshot owner behind", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    empty_inspection = Path.join(root, "empty-inspection")
    File.mkdir_p!(empty_inspection)

    monitoring_before = monitoring_processes()

    assert {:error, :empty_inspection_resource} =
             PrivateRunAnalysisProfile.capture(
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
        Path.join(fixture.inspection, fixture.run_id <> ".ptcins")

      result =
        case scenario do
          :malformed ->
            File.write!(inspection_path, ~s({"private":"private-malformed"))
            capture(fixture)

          :uncorrelated ->
            File.rm!(Path.join(fixture.traces, fixture.run_id <> ".jsonl"))
            capture(fixture)

          :replaced ->
            PrivateRunAnalysisProfile.capture(
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
    PrivateRunAnalysisProfile.capture(
      %{"traces" => fixture.traces, "inspection" => fixture.inspection},
      []
    )
  end

  defp start_internal_session(fixture) do
    {:ok, resources} = capture(fixture)
    limits = PrivateRunAnalysisProfile.limits()
    run_id = "private-run-analysis-test-" <> Integer.to_string(System.unique_integer([:positive]))
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
      PrivateRunAnalysisProfile.assemble(resources, sink)

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
