defmodule PtcRunner.Kernel.InspectionSnapshotTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionQuery
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunAnalysisCapability
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.TestSupport.PrivateInspectionFixture
  alias PtcRunner.TestSupport.RunLifecycle

  @source "(return 42)"
  @source_hash :crypto.hash(:sha256, @source) |> Base.encode16(case: :lower)

  @tag :tmp_dir
  test "exposes one canonical terminal result through the singular query", %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    run_id = "result-run"
    value = %{"answer" => 42, "evidence" => List.duplicate(0, 200)}
    result_hash = result_hash(value)

    events = [
      event(run_id, 1, "run-started", %{"missions" => %{}}),
      event(run_id, 2, "run-stopped", %{
        "outcome" => "ok",
        "result_hash" => result_hash
      })
    ]

    File.write!(Path.join(trace, "#{run_id}.jsonl"), encode_jsonl(events))

    {:ok, sink} = InspectionSink.start(run_id: run_id, trace_id: "trace-#{run_id}")

    assert :ok =
             InspectionSink.emit(
               sink,
               "run-result",
               %{},
               %{result_hash: result_hash, value: value}
             )

    {:ok, records} = InspectionSink.records(sink)

    assert :ok =
             InspectionArtifact.persist(
               Path.join(inspection, "#{run_id}.inspection.jsonl"),
               records,
               events
             )

    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())

    {:ok, snapshot} =
      InspectionSnapshot.start({:directory, inspection}, trace_snapshot, owner: self())

    on_exit(fn ->
      InspectionSnapshot.stop(snapshot)
      TraceSnapshot.stop(trace_snapshot)
    end)

    assert {:ok,
            %{
              "run_id" => ^run_id,
              "trace_id" => "trace-result-run",
              "result_hash" => ^result_hash,
              "value" => ^value,
              "snapshot_hash" => "sha256:" <> _
            } = result} = InspectionSnapshot.query(snapshot, :result, %{"run_id" => run_id})

    assert {:error, :not_found} =
             InspectionSnapshot.query(snapshot, :result, %{"run_id" => "unknown"})

    {:ok, capabilities} = RunAnalysisCapability.from_snapshots(trace_snapshot, snapshot)
    result_capability = Enum.find(capabilities, &(&1.name == "analysis-open"))

    assert {:ok, %{"result" => %{"value" => ^value}}} =
             result_capability.callback.(%{"run_id" => run_id})

    encoded_bytes = result |> Jason.encode!() |> byte_size()
    retained_bytes = RetainedSize.bytes(result)
    assert retained_bytes > encoded_bytes
    retained_limit = div(encoded_bytes + retained_bytes, 2)

    {:ok, limited_snapshot} =
      InspectionSnapshot.start({:directory, inspection}, trace_snapshot,
        owner: self(),
        max_result_bytes: retained_limit
      )

    on_exit(fn -> InspectionSnapshot.stop(limited_snapshot) end)

    {:ok, limited_capabilities} =
      RunAnalysisCapability.from_snapshots(trace_snapshot, limited_snapshot)

    limited_result = Enum.find(limited_capabilities, &(&1.name == "analysis-open"))

    assert {:error,
            %ProviderError{
              kind: :invalid_request,
              details: "analysis result limit exceeded"
            }} = limited_result.callback.(%{"run_id" => run_id})
  end

  test "effective preludes qualify repeated component IDs by mission" do
    records =
      ["reader", "writer"]
      |> Enum.with_index(1)
      |> Enum.map(fn {mission_name, sequence} ->
        %{
          "schema_version" => 6,
          "run_id" => "qualified-preludes",
          "trace_id" => "trace-qualified-preludes",
          "sequence" => sequence,
          "timestamp" => "2026-08-11T12:00:00Z",
          "record_type" => "prelude-source",
          "correlation" => %{"component_id" => "shared.api"},
          "payload" => %{
            "environment" => "mission",
            "mission_name" => mission_name,
            "source" => @source,
            "source_hash" => @source_hash,
            "source_bytes" => byte_size(@source)
          }
        }
      end)

    assert {:ok, %{source_id: source_id, collections: collections}} =
             InspectionQuery.compile([records], "trace-source", %{
               "trace_snapshot_hash" => "trace-source",
               "runs" => %{"qualified-preludes" => %{}}
             })

    assert {:ok, %{"items" => items}} =
             InspectionQuery.query(
               collections,
               source_id,
               :effective_preludes,
               %{"run_id" => "qualified-preludes"},
               100_000
             )

    assert Enum.map(items, &{&1["component_id"], &1["mission_name"]}) == [
             {"shared.api", "reader"},
             {"shared.api", "writer"}
           ]
  end

  @tag :tmp_dir
  test "multiple artifacts expose paired deterministic private queries", %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "basic-run", :basic)
    write_run(trace, inspection, "mcp-run", :mcp)

    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())

    {:ok, snapshot} =
      InspectionSnapshot.start({:directory, inspection}, trace_snapshot, owner: self())

    on_exit(fn ->
      InspectionSnapshot.stop(snapshot)
      TraceSnapshot.stop(trace_snapshot)
    end)

    assert {:ok, %{snapshot_hash: snapshot_hash}} = InspectionSnapshot.info(snapshot)
    assert snapshot_hash =~ ~r/\Asha256:[0-9a-f]{64}\z/

    assert {:ok,
            %{
              "items" => [%{"run_id" => "basic-run"}],
              "next_cursor" => cursor,
              "truncated" => true,
              "snapshot_hash" => ^snapshot_hash
            }} = InspectionSnapshot.query(snapshot, :list_runs, %{"limit" => 1})

    assert {:ok,
            %{
              "items" => [%{"run_id" => "mcp-run", "schema_version" => 6}],
              "next_cursor" => nil,
              "snapshot_hash" => ^snapshot_hash
            }} =
             InspectionSnapshot.query(snapshot, :list_runs, %{
               "limit" => 1,
               "cursor" => cursor
             })

    assert {:error, :invalid_query} =
             InspectionSnapshot.query(snapshot, :model_exchanges, %{
               "run_id" => "mcp-run",
               "cursor" => cursor
             })

    assert {:error, :result_not_found} =
             InspectionSnapshot.query(snapshot, :result, %{"run_id" => "basic-run"})

    assert {:ok,
            %{
              "items" => [
                %{
                  "capability_id" => "llm-mcp-run",
                  "complete?" => true,
                  "input_sequence" => llm_input,
                  "output_sequence" => llm_output,
                  "arguments" => %{"messages" => [%{"content" => "private-mcp-run"}]},
                  "result" => %{"status" => "ok", "value" => %{"answer" => "model-mcp-run"}}
                }
              ],
              "snapshot_hash" => ^snapshot_hash
            }} =
             InspectionSnapshot.query(snapshot, :model_exchanges, %{"run_id" => "mcp-run"})

    assert llm_input < llm_output

    assert {:ok,
            %{
              "items" => [
                %{
                  "capability_id" => "tool-mcp-run",
                  "complete?" => true,
                  "arguments" => %{"path" => "private-mcp-run.txt"},
                  "result" => %{"status" => "ok", "value" => %{"text" => "secret-mcp-run"}}
                }
              ]
            }} =
             InspectionSnapshot.query(snapshot, :capability_calls, %{"run_id" => "mcp-run"})

    assert {:ok,
            %{
              "items" => [
                %{
                  "evaluation_id" => "eval-mcp-run",
                  "source" => @source,
                  "source_hash" => "sha256:" <> @source_hash
                }
              ]
            }} =
             InspectionSnapshot.query(snapshot, :generated_sources, %{"run_id" => "mcp-run"})

    assert {:ok,
            %{
              "items" => [
                %{
                  "component_id" => "component-mcp-run",
                  "source" => @source,
                  "source_hash" => "sha256:" <> @source_hash
                }
              ]
            }} =
             InspectionSnapshot.query(snapshot, :effective_preludes, %{"run_id" => "mcp-run"})

    assert {:ok, %{"items" => []}} =
             InspectionSnapshot.query(snapshot, :provider_exchanges, %{"run_id" => "basic-run"})

    assert {:ok,
            %{
              "items" => [
                %{
                  "capability_id" => "tool-mcp-run",
                  "request_id" => 7,
                  "transport" => "stdio",
                  "request_sequence" => request_sequence,
                  "response_sequence" => response_sequence,
                  "request" => %{
                    "jsonrpc" => "2.0",
                    "id" => 7,
                    "method" => "tools/call",
                    "params" => %{
                      "name" => "read",
                      "arguments" => %{"path" => "private-mcp-run.txt"}
                    }
                  },
                  "response" => %{
                    "jsonrpc" => "2.0",
                    "id" => 7,
                    "result" => %{"content" => [%{"type" => "text", "text" => "secret-mcp-run"}]}
                  }
                }
              ],
              "next_cursor" => provider_cursor
            }} =
             InspectionSnapshot.query(snapshot, :provider_exchanges, %{
               "run_id" => "mcp-run",
               "limit" => 1
             })

    assert {:ok,
            %{
              "items" => [%{"request_id" => 8}],
              "next_cursor" => descending_cursor
            }} =
             InspectionSnapshot.query(snapshot, :provider_exchanges, %{
               "run_id" => "mcp-run",
               "limit" => 1,
               "order" => "desc"
             })

    assert is_binary(descending_cursor)

    assert {:error, :invalid_query} =
             InspectionSnapshot.query(snapshot, :provider_exchanges, %{
               "run_id" => "mcp-run",
               "order" => "newest"
             })

    assert request_sequence < response_sequence

    assert {:ok, %{"items" => [%{"request_id" => 8}], "next_cursor" => nil}} =
             InspectionSnapshot.query(snapshot, :provider_exchanges, %{
               "run_id" => "mcp-run",
               "limit" => 1,
               "cursor" => provider_cursor
             })

    assert {:error, :invalid_query} =
             InspectionSnapshot.query(snapshot, :capability_calls, %{
               "run_id" => "mcp-run",
               "cursor" => provider_cursor
             })

    tampered_cursor =
      provider_cursor
      |> Base.url_decode64!(padding: false)
      |> Jason.decode!()
      |> Map.put("source", "another-capture")
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert {:error, :source_changed} =
             InspectionSnapshot.query(snapshot, :provider_exchanges, %{
               "run_id" => "mcp-run",
               "cursor" => tampered_cursor
             })

    {:ok, profile_capabilities} =
      RunAnalysisCapability.from_snapshots(trace_snapshot, snapshot)

    {:ok, manifest_capabilities} =
      RunAnalysisCapability.from_snapshots(trace_snapshot, snapshot, "private")

    arguments = [
      %{"limit" => 2},
      %{"run_id" => "mcp-run"},
      %{"run_id" => "mcp-run"},
      %{"run_id" => "mcp-run"},
      %{"run_id" => "mcp-run"},
      %{"run_id" => "mcp-run"}
    ]

    Enum.zip([profile_capabilities, manifest_capabilities, arguments])
    |> Enum.each(fn {profile, manifest, query} ->
      assert profile.callback.(query) == manifest.callback.(query)
    end)

    File.write!(Path.join(inspection, "mcp-run.inspection.jsonl"), "replaced")

    assert {:ok, %{"items" => [%{"request_id" => 7}]}} =
             InspectionSnapshot.query(snapshot, :provider_exchanges, %{
               "run_id" => "mcp-run",
               "limit" => 1
             })
  end

  @tag :tmp_dir
  test "interrupted capability attempts preserve the complete private prefix", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create_interrupted!(root)
    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, fixture.traces}, owner: self())

    {:ok, snapshot} =
      InspectionSnapshot.start({:directory, fixture.inspection}, trace_snapshot, owner: self())

    on_exit(fn ->
      InspectionSnapshot.stop(snapshot)
      TraceSnapshot.stop(trace_snapshot)
    end)

    assert {:ok,
            %{
              "counts" => %{
                "model_exchanges" => 2,
                "incomplete_model_exchanges" => 1,
                "capability_calls" => 2,
                "incomplete_capability_calls" => 1
              }
            }} = InspectionSnapshot.query(snapshot, :get_run, %{"run_id" => fixture.run_id})

    assert {:ok,
            %{
              "items" => [
                %{
                  "capability_id" => "llm-complete-" <> _,
                  "complete?" => true,
                  "result" => %{"status" => "ok"},
                  "output_sequence" => output_sequence,
                  "output_timestamp" => output_timestamp
                },
                %{
                  "capability_id" => "llm-interrupted-" <> _,
                  "complete?" => false,
                  "arguments" => %{"messages" => interrupted_messages}
                } = interrupted_model
              ]
            }} =
             InspectionSnapshot.query(snapshot, :model_exchanges, %{
               "run_id" => fixture.run_id
             })

    assert is_integer(output_sequence)
    assert is_binary(output_timestamp)
    assert List.last(interrupted_messages)["content"] == fixture.interrupted_model_secret
    refute Map.has_key?(interrupted_model, "result")
    refute Map.has_key?(interrupted_model, "output_sequence")
    refute Map.has_key?(interrupted_model, "output_timestamp")

    assert {:ok,
            %{
              "items" => [
                %{
                  "capability_id" => "tool-complete-" <> _,
                  "complete?" => true,
                  "result" => %{"status" => "ok"}
                },
                %{
                  "capability_id" => "tool-interrupted-" <> _,
                  "complete?" => false,
                  "arguments" => %{"path" => interrupted_tool_secret}
                } = interrupted_tool
              ]
            }} =
             InspectionSnapshot.query(snapshot, :capability_calls, %{
               "run_id" => fixture.run_id
             })

    assert interrupted_tool_secret == fixture.interrupted_tool_secret
    refute Map.has_key?(interrupted_tool, "result")
    refute Map.has_key?(interrupted_tool, "output_sequence")
    refute Map.has_key?(interrupted_tool, "output_timestamp")

    assert {:ok,
            %{
              "evidence" => %{
                "canonical_complete?" => true,
                "complete?" => false,
                "missing_exchange_count" => 1
              },
              "items" => [%{"capability_id" => "llm-complete-" <> _}]
            }} = InspectionSnapshot.query(snapshot, :turns, %{"run_id" => fixture.run_id})
  end

  @tag :tmp_dir
  test "execution diagnostics are exposed as bounded run-scoped queries", %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "diagnostics-run", :diagnostics)

    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())

    {:ok, snapshot} =
      InspectionSnapshot.start({:directory, inspection}, trace_snapshot, owner: self())

    on_exit(fn ->
      InspectionSnapshot.stop(snapshot)
      TraceSnapshot.stop(trace_snapshot)
    end)

    assert {:ok,
            %{
              "items" => [
                %{
                  "evaluation_id" => "workflow-eval-diagnostics-run",
                  "environment" => "workflow",
                  "prints" => ["private-print-diagnostics-run"],
                  "truncated" => false
                }
              ],
              "next_cursor" => nil
            }} =
             InspectionSnapshot.query(snapshot, :execution_prints, %{
               "run_id" => "diagnostics-run"
             })

    assert {:ok,
            %{
              "items" => [
                %{
                  "evaluation_id" => "workflow-eval-diagnostics-run",
                  "environment" => "workflow",
                  "kind" => "limit_exceeded",
                  "reason" => "timeout",
                  "details" => %{"limit" => "run_duration_ms", "limit_ms" => 1_000}
                }
              ],
              "next_cursor" => nil
            }} =
             InspectionSnapshot.query(snapshot, :execution_errors, %{
               "run_id" => "diagnostics-run"
             })
  end

  @tag :tmp_dir
  test "an effective-prelude hash is directly usable as an override base hash", %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "mcp-run", :mcp)

    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())

    {:ok, snapshot} =
      InspectionSnapshot.start({:directory, inspection}, trace_snapshot, owner: self())

    on_exit(fn ->
      InspectionSnapshot.stop(snapshot)
      TraceSnapshot.stop(trace_snapshot)
    end)

    assert {:ok, %{"items" => [item]}} =
             InspectionSnapshot.query(snapshot, :effective_preludes, %{"run_id" => "mcp-run"})

    candidate_source = item["source"] <> "\n"
    File.write!(Path.join(root, "candidate.clj"), candidate_source)

    File.write!(
      Path.join(root, "override.json"),
      Jason.encode!(%{
        "target" => %{"environment" => "workflow"},
        "component_id" => item["component_id"],
        "base_source_hash" => item["source_hash"],
        "source_hash" => ComponentOverride.hash(candidate_source),
        "path" => "candidate.clj"
      })
    )

    assert {:ok, override} = ComponentOverride.load(Path.join(root, "override.json"))

    assert {:ok, installed} =
             Component.new(
               id: item["component_id"],
               source: item["source"],
               dependencies: [],
               origin: "inspection"
             )

    assert {:ok, [_replacement], true} = ComponentOverride.apply([installed], override)
  end

  @tag :tmp_dir
  test "capability naming supports fixed profiles and manifest aliases", %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "named", :basic)
    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())
    {:ok, snapshot} = InspectionSnapshot.start({:directory, inspection}, trace_snapshot)

    on_exit(fn ->
      InspectionSnapshot.stop(snapshot)
      TraceSnapshot.stop(trace_snapshot)
    end)

    assert {:ok, profile_capabilities} =
             RunAnalysisCapability.from_snapshots(trace_snapshot, snapshot)

    assert {:ok, provider_capabilities} =
             RunAnalysisCapability.from_snapshots(trace_snapshot, snapshot, "private")

    assert Enum.map(profile_capabilities, & &1.name) == [
             "analysis-runs",
             "analysis-open",
             "analysis-read"
           ]

    assert Enum.map(provider_capabilities, & &1.name) == [
             "private.runs",
             "private.open",
             "private.read"
           ]

    provider_exchange = Enum.find(provider_capabilities, &(&1.name == "private.read"))

    assert {:ok, %{"items" => []}} =
             provider_exchange.callback.(%{
               "run_id" => "named",
               "collection" => "provider_exchanges"
             })

    snapshot_ref = Process.monitor(snapshot.pid)
    assert :ok = TraceSnapshot.stop(trace_snapshot)
    assert_receive {:DOWN, ^snapshot_ref, :process, _, :normal}
    assert {:error, :snapshot_unavailable} = InspectionSnapshot.info(snapshot)
  end

  @tag :tmp_dir
  test "an ordinary manifest acquires trace before private inspection and exposes alias operations",
       %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "manifest-run", :mcp)
    File.write!(Path.join(root, "workflow.clj"), "(ns app) (defn run [x] (return x))")

    host_path = Path.join(root, "host.json")

    File.write!(
      host_path,
      Jason.encode!(%{
        "install" => %{
          "history" => %{
            "source" => "ptc_trace_snapshot",
            "installation_revision" => "trace-v1",
            "directory" => "traces"
          },
          "private-history" => %{
            "source" => "ptc_inspection_snapshot",
            "installation_revision" => "inspection-v1",
            "directory" => "inspection",
            "ceilings" => %{"max_files" => 10}
          }
        }
      })
    )

    manifest_path = Path.join(root, "manifest.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "workflow.clj"}],
          "entry" => "app/run"
        },
        "input" => %{"value" => %{}},
        "missions" => %{
          "default" => %{"providers" => ["private-history", "history"]}
        },
        "providers" => %{
          "mission" => [
            %{"name" => "private-history"},
            %{"name" => "history"}
          ]
        }
      })
    )

    {:ok, host} = HostConfig.load(host_path)

    {:ok, registry} =
      HostInstallation.catalog(host)
      |> then(fn {:ok, catalog} ->
        HostInstallation.runtime_registry(host, catalog)
      end)

    {:ok, built} =
      manifest_path
      |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
      |> RunLifecycle.build(registry)

    assert built.config.event_sink.policy == :private

    assert Enum.map(built.config.connector_snapshots, & &1["provider"]) == [
             "history",
             "private-history"
           ]

    private_snapshot =
      Enum.find(built.config.connector_snapshots, &(&1["provider"] == "private-history"))

    assert private_snapshot["declaration"]["data_class"] == "private_inspection"

    assert private_snapshot["declaration"]["accepts_data"] == [
             "normal",
             "private_inspection"
           ]

    capability =
      Map.fetch!(
        built.config.missions["default"].environment.capabilities,
        "private-history.read"
      )

    assert {:ok,
            %{
              "snapshot_hash" => content_snapshot_hash,
              "items" => provider_exchanges
            }} =
             capability.callback.(%{
               "run_id" => "manifest-run",
               "collection" => "provider_exchanges",
               "limit" => 1
             })

    assert Enum.map(provider_exchanges, & &1["request_id"]) == [7]
    assert private_snapshot["content_snapshot_hash"] == content_snapshot_hash
    assert :ok = RunBuilder.close(built)
  end

  @tag :tmp_dir
  test "private data compatibility fails before sensitive snapshot preflight", %{tmp_dir: root} do
    File.write!(Path.join(root, "workflow.clj"), "(ns app) (defn run [x] (return x))")
    host_path = Path.join(root, "host.json")

    File.write!(
      host_path,
      Jason.encode!(%{
        "install" => %{
          "ordinary-egress" => %{
            "source" => "mcp",
            "installation_revision" => "private-only-v1",
            "transport" => %{
              "type" => "streamable_http",
              "endpoint" => "https://127.0.0.1:1/mcp"
            },
            "tools" => %{
              "read" => %{"as" => "ordinary.read", "effect" => "read"}
            }
          },
          "history" => %{
            "source" => "ptc_trace_snapshot",
            "installation_revision" => "trace-v1",
            "directory" => "missing-traces"
          },
          "private-history" => %{
            "source" => "ptc_inspection_snapshot",
            "installation_revision" => "inspection-v1",
            "directory" => "missing-inspection"
          }
        }
      })
    )

    manifest_path = Path.join(root, "manifest.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "workflow.clj"}],
          "entry" => "app/run"
        },
        "input" => %{"value" => %{}},
        "providers" => %{
          "mission" => [
            %{"name" => "ordinary-egress"},
            %{"name" => "history"},
            %{"name" => "private-history"}
          ]
        }
      })
    )

    {:ok, host} = HostConfig.load(host_path)

    {:ok, registry} =
      HostInstallation.catalog(host)
      |> then(fn {:ok, catalog} ->
        HostInstallation.runtime_registry(host, catalog)
      end)

    assert {:error, :provider_data_class_denied} =
             manifest_path
             |> ApplicationPackage.request_directory(installed_limits: registry.installed_limits)
             |> RunLifecycle.build(registry)
  end

  @tag :tmp_dir
  test "orphan, duplicate, malformed, symlink, and replacement captures fail closed",
       %{tmp_dir: root} do
    for scenario <- [:orphan, :duplicate, :malformed, :symlink, :replacement] do
      scenario_root = Path.join(root, Atom.to_string(scenario))
      {trace, inspection} = source_directories(scenario_root)
      write_run(trace, inspection, "valid", :basic)
      {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())

      result =
        case scenario do
          :orphan ->
            write_inspection(inspection, "orphan", :basic, canonical_events("orphan"))
            InspectionSnapshot.start({:directory, inspection}, trace_snapshot)

          :duplicate ->
            File.cp!(
              Path.join(inspection, "valid.inspection.jsonl"),
              Path.join(inspection, "duplicate.inspection.jsonl")
            )

            InspectionSnapshot.start({:directory, inspection}, trace_snapshot)

          :malformed ->
            File.write!(
              Path.join(inspection, "broken.inspection.jsonl"),
              ~s({"private":"private-marker")
            )

            InspectionSnapshot.start({:directory, inspection}, trace_snapshot)

          :symlink ->
            File.ln_s!(
              Path.join(inspection, "valid.inspection.jsonl"),
              Path.join(inspection, "linked.inspection.jsonl")
            )

            InspectionSnapshot.start({:directory, inspection}, trace_snapshot)

          :replacement ->
            path = Path.join(inspection, "valid.inspection.jsonl")

            InspectionSnapshot.start({:directory, inspection}, trace_snapshot,
              capture_hook: fn ->
                File.write!(path, File.read!(path) <> "\n")
                :ok
              end
            )
        end

      assert {:error, _reason} = result
      refute inspect(result) =~ "private-marker"
      refute inspect(result) =~ inspection
      TraceSnapshot.stop(trace_snapshot)
    end
  end

  @tag :tmp_dir
  test "an unsupported inspection schema remains distinguishable during capture", %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "unsupported", :basic)
    PrivateInspectionFixture.rewrite_schema!(inspection, 4)
    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(trace_snapshot) end)

    assert {:error,
            {:unsupported_inspection_schema_version, %{artifact_version: 4, supported_version: 6}}} =
             InspectionSnapshot.start({:directory, inspection}, trace_snapshot, owner: self())
  end

  @tag :tmp_dir
  test "encoded, retained, result, and file ceilings are independent", %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "bounded", :basic)
    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(trace_snapshot) end)

    assert {:ok, retained_snapshot} =
             InspectionSnapshot.start({:directory, inspection}, trace_snapshot)

    assert {:ok, %{retained_bytes: expected_retained_bytes}} =
             InspectionSnapshot.info(retained_snapshot)

    assert :ok = InspectionSnapshot.stop(retained_snapshot)

    assert {:error, :source_limit_exceeded} =
             InspectionSnapshot.start({:directory, inspection}, trace_snapshot,
               max_source_bytes: 1
             )

    assert {:error,
            {:source_retained_limit_exceeded,
             %{
               source: :ptc_inspection_snapshot,
               measured_bytes: measured_bytes,
               limit_bytes: 1
             }}} =
             InspectionSnapshot.start({:directory, inspection}, trace_snapshot,
               max_retained_bytes: 1
             )

    assert measured_bytes == expected_retained_bytes

    duplicate = Path.join(inspection, "second.inspection.jsonl")
    File.cp!(Path.join(inspection, "bounded.inspection.jsonl"), duplicate)

    assert {:error, :source_limit_exceeded} =
             InspectionSnapshot.start({:directory, inspection}, trace_snapshot, max_files: 1)

    File.rm!(duplicate)

    {:ok, snapshot} =
      InspectionSnapshot.start({:directory, inspection}, trace_snapshot, max_result_bytes: 1)

    on_exit(fn -> InspectionSnapshot.stop(snapshot) end)

    assert {:error, :result_limit_exceeded} =
             InspectionSnapshot.query(snapshot, :list_runs, %{})

    for operation <- [
          :model_exchanges,
          :capability_calls,
          :generated_sources,
          :effective_preludes,
          :provider_exchanges
        ] do
      assert {:error, :result_limit_exceeded} =
               InspectionSnapshot.query(snapshot, operation, %{"run_id" => "bounded"})
    end
  end

  @tag :tmp_dir
  test "capture heap exhaustion has the stable retained-limit error", %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "heap-bounded", :basic)
    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(trace_snapshot) end)

    assert {:error, :source_retained_limit_exceeded} =
             InspectionSnapshot.start({:directory, inspection}, trace_snapshot,
               capture_heap_words: 233
             )
  end

  @tag :tmp_dir
  test "an individually oversized query item fails instead of returning a stalled cursor", %{
    tmp_dir: root
  } do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "oversized", :basic)
    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())

    {:ok, snapshot} =
      InspectionSnapshot.start({:directory, inspection}, trace_snapshot, max_result_bytes: 256)

    on_exit(fn ->
      InspectionSnapshot.stop(snapshot)
      TraceSnapshot.stop(trace_snapshot)
    end)

    assert {:error, :result_limit_exceeded} =
             InspectionSnapshot.query(snapshot, :model_exchanges, %{
               "run_id" => "oversized",
               "limit" => 1
             })
  end

  @tag :tmp_dir
  test "safe metadata and owner lifecycle retain no private paths or payloads", %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "owned", :mcp)
    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, snapshot} =
      InspectionSnapshot.start({:directory, inspection}, trace_snapshot, owner: owner)

    snapshot_ref = Process.monitor(snapshot.pid)

    assert {:ok,
            %{
              capture_id: capture_id,
              file_count: 1,
              run_count: 1,
              source_bytes: source_bytes,
              retained_bytes: retained_bytes,
              trace_capture_id: trace_capture_id
            } = info} = InspectionSnapshot.info(snapshot)

    assert capture_id =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    assert trace_capture_id =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    assert source_bytes > 0
    assert retained_bytes > 0
    refute Map.has_key?(info, :path)

    status = inspect(:sys.get_status(snapshot.pid))
    refute status =~ inspection
    refute status =~ "private-owned"
    refute status =~ capture_id

    send(owner, :stop)
    assert_receive {:DOWN, ^snapshot_ref, :process, _, :normal}
    assert {:error, :snapshot_unavailable} = InspectionSnapshot.info(snapshot)
    assert :ok = InspectionSnapshot.stop(snapshot)
    TraceSnapshot.stop(trace_snapshot)
  end

  defp source_directories(root) do
    trace = Path.join(root, "traces")
    inspection = Path.join(root, "inspection")
    File.mkdir_p!(trace)
    File.mkdir_p!(inspection)
    {trace, inspection}
  end

  defp write_run(trace_directory, inspection_directory, run_id, variant) do
    events = canonical_events(run_id)
    File.write!(Path.join(trace_directory, "#{run_id}.jsonl"), encode_jsonl(events))
    write_inspection(inspection_directory, run_id, variant, events)
  end

  # ex_dna:disable-for-next-line — Explicit records keep snapshot fixture failures local.
  defp write_inspection(directory, run_id, variant, events) do
    {:ok, sink} = InspectionSink.start(run_id: run_id, trace_id: "trace-#{run_id}")

    emit!(sink, "capability-input", %{capability_id: "llm-#{run_id}"}, %{
      environment: :workflow,
      name: "llm-request",
      arguments: %{"messages" => [%{"content" => "private-#{run_id}"}]}
    })

    emit!(sink, "capability-output", %{capability_id: "llm-#{run_id}"}, %{
      environment: :workflow,
      name: "llm-request",
      result: %{status: :ok, value: %{"answer" => "model-#{run_id}"}}
    })

    emit!(sink, "capability-input", %{capability_id: "tool-#{run_id}"}, %{
      environment: :mission,
      mission_name: "default",
      name: "workspace.read",
      arguments: %{"path" => "private-#{run_id}.txt"}
    })

    if variant in [:mcp, :diagnostics] do
      emit!(sink, "mcp-request", %{capability_id: "tool-#{run_id}", request_id: 7}, %{
        mission_name: "default",
        transport: :stdio,
        body: %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "tools/call",
          "params" => %{
            "name" => "read",
            "arguments" => %{"path" => "private-#{run_id}.txt"}
          }
        }
      })

      emit!(sink, "mcp-response", %{capability_id: "tool-#{run_id}", request_id: 7}, %{
        mission_name: "default",
        transport: :stdio,
        body: %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "result" => %{
            "content" => [%{"type" => "text", "text" => "secret-#{run_id}"}]
          }
        }
      })

      emit!(sink, "mcp-request", %{capability_id: "tool-#{run_id}", request_id: 8}, %{
        mission_name: "default",
        transport: :stdio,
        body: %{
          "jsonrpc" => "2.0",
          "id" => 8,
          "method" => "tools/call",
          "params" => %{
            "name" => "read",
            "arguments" => %{"path" => "second-#{run_id}.txt"}
          }
        }
      })

      emit!(sink, "mcp-response", %{capability_id: "tool-#{run_id}", request_id: 8}, %{
        mission_name: "default",
        transport: :stdio,
        body: %{
          "jsonrpc" => "2.0",
          "id" => 8,
          "result" => %{
            "content" => [%{"type" => "text", "text" => "second-secret-#{run_id}"}]
          }
        }
      })
    end

    emit!(sink, "capability-output", %{capability_id: "tool-#{run_id}"}, %{
      environment: :mission,
      mission_name: "default",
      name: "workspace.read",
      result: %{status: :ok, value: %{"text" => "secret-#{run_id}"}}
    })

    emit!(sink, "evaluation-source", %{evaluation_id: "eval-#{run_id}"}, %{
      environment: :mission,
      mission_name: "default",
      program_kind: :"ptc-lisp",
      source: @source,
      source_hash: @source_hash,
      source_bytes: byte_size(@source)
    })

    emit!(sink, "prelude-source", %{component_id: "component-#{run_id}"}, %{
      environment: :workflow,
      source: @source,
      source_hash: @source_hash,
      source_bytes: byte_size(@source)
    })

    if variant == :diagnostics do
      PrivateInspectionFixture.emit_execution_diagnostics!(sink, run_id)
    end

    {:ok, records} = InspectionSink.records(sink)
    path = Path.join(directory, "#{run_id}.inspection.jsonl")
    :ok = InspectionArtifact.persist(path, records, events)
    :ok = InspectionSink.stop(sink)
  end

  defp emit!(sink, type, correlation, payload),
    do: :ok = InspectionSink.emit(sink, type, correlation, payload)

  # ex_dna:disable-for-next-line — Keep the compared snapshot-local trace readable here.
  defp canonical_events(run_id) do
    [
      event(run_id, 1, "run-started", %{
        "missions" => %{"default" => %{}},
        "workflow_prelude" => %{
          "component_ids" => ["component-#{run_id}"],
          "dependency_indices" => [],
          "hash" => "prelude-hash"
        }
      }),
      event(run_id, 2, "capability-started", %{
        "capability_id" => "llm-#{run_id}",
        "environment" => "workflow",
        "name" => "llm-request"
      }),
      event(run_id, 3, "capability-started", %{
        "capability_id" => "tool-#{run_id}",
        "environment" => "mission",
        "mission_name" => "default",
        "name" => "workspace.read"
      }),
      event(run_id, 4, "evaluation-started", %{
        "evaluation_id" => "eval-#{run_id}",
        "environment" => "mission",
        "mission_name" => "default",
        "program_kind" => "ptc-lisp",
        "source_hash" => @source_hash,
        "source_bytes" => byte_size(@source)
      }),
      PrivateInspectionFixture.workflow_evaluation_event(run_id, 5),
      event(run_id, 6, "run-stopped", %{"outcome" => "ok"})
    ]
  end

  # ex_dna:disable-for-next-line — The snapshot test owns its independent canonical-event constructor.
  defp event(run_id, sequence, type, data) do
    %{
      "schema_version" => 2,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-07-26T12:00:0#{sequence}Z",
      "type" => type,
      "data" => data
    }
  end

  defp encode_jsonl(events), do: Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))

  defp result_hash(value) do
    {:ok, encoded} = DeterministicJSON.encode(value)
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)
  end
end
