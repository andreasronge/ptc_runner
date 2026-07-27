defmodule PtcRunner.Kernel.InspectionSnapshotTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionCapability
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.TraceSnapshot

  @source "(return 42)"
  @source_hash :crypto.hash(:sha256, @source) |> Base.encode16(case: :lower)

  @tag :tmp_dir
  test "mixed V1/V2 artifacts expose paired deterministic private queries", %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "v1-run", 1)
    write_run(trace, inspection, "v2-run", 2)

    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())

    {:ok, snapshot} =
      InspectionSnapshot.start({:directory, inspection}, trace_snapshot, owner: self())

    on_exit(fn ->
      InspectionSnapshot.stop(snapshot)
      TraceSnapshot.stop(trace_snapshot)
    end)

    assert {:ok,
            %{
              "items" => [%{"run_id" => "v1-run"}],
              "next_cursor" => cursor,
              "truncated" => true
            }} = InspectionSnapshot.query(snapshot, :list_runs, %{"limit" => 1})

    assert {:ok,
            %{
              "items" => [%{"run_id" => "v2-run", "schema_version" => 2}],
              "next_cursor" => nil
            }} =
             InspectionSnapshot.query(snapshot, :list_runs, %{
               "limit" => 1,
               "cursor" => cursor
             })

    assert {:error, :invalid_query} =
             InspectionSnapshot.query(snapshot, :model_exchanges, %{
               "run_id" => "v2-run",
               "cursor" => cursor
             })

    assert {:ok,
            %{
              "items" => [
                %{
                  "capability_id" => "llm-v2-run",
                  "input_sequence" => llm_input,
                  "output_sequence" => llm_output,
                  "arguments" => %{"messages" => [%{"content" => "private-v2-run"}]},
                  "result" => %{"status" => "ok", "value" => %{"answer" => "model-v2-run"}}
                }
              ]
            }} =
             InspectionSnapshot.query(snapshot, :model_exchanges, %{"run_id" => "v2-run"})

    assert llm_input < llm_output

    assert {:ok,
            %{
              "items" => [
                %{
                  "capability_id" => "tool-v2-run",
                  "arguments" => %{"path" => "private-v2-run.txt"},
                  "result" => %{"status" => "ok", "value" => %{"text" => "secret-v2-run"}}
                }
              ]
            }} =
             InspectionSnapshot.query(snapshot, :capability_calls, %{"run_id" => "v2-run"})

    assert {:ok,
            %{
              "items" => [
                %{
                  "evaluation_id" => "eval-v2-run",
                  "source" => @source,
                  "source_hash" => @source_hash
                }
              ]
            }} =
             InspectionSnapshot.query(snapshot, :generated_sources, %{"run_id" => "v2-run"})

    assert {:ok,
            %{
              "items" => [
                %{
                  "component_id" => "component-v2-run",
                  "source" => @source,
                  "source_hash" => @source_hash
                }
              ]
            }} =
             InspectionSnapshot.query(snapshot, :effective_preludes, %{"run_id" => "v2-run"})

    assert {:ok, %{"items" => []}} =
             InspectionSnapshot.query(snapshot, :provider_exchanges, %{"run_id" => "v1-run"})

    assert {:ok,
            %{
              "items" => [
                %{
                  "capability_id" => "tool-v2-run",
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
                      "arguments" => %{"path" => "private-v2-run.txt"}
                    }
                  },
                  "response" => %{
                    "jsonrpc" => "2.0",
                    "id" => 7,
                    "result" => %{"content" => [%{"type" => "text", "text" => "secret-v2-run"}]}
                  }
                }
              ],
              "next_cursor" => provider_cursor
            }} =
             InspectionSnapshot.query(snapshot, :provider_exchanges, %{
               "run_id" => "v2-run",
               "limit" => 1
             })

    assert {:ok,
            %{
              "items" => [%{"request_id" => 8}],
              "next_cursor" => descending_cursor
            }} =
             InspectionSnapshot.query(snapshot, :provider_exchanges, %{
               "run_id" => "v2-run",
               "limit" => 1,
               "order" => "desc"
             })

    assert is_binary(descending_cursor)

    assert {:error, :invalid_query} =
             InspectionSnapshot.query(snapshot, :provider_exchanges, %{
               "run_id" => "v2-run",
               "order" => "newest"
             })

    assert request_sequence < response_sequence

    assert {:ok, %{"items" => [%{"request_id" => 8}], "next_cursor" => nil}} =
             InspectionSnapshot.query(snapshot, :provider_exchanges, %{
               "run_id" => "v2-run",
               "limit" => 1,
               "cursor" => provider_cursor
             })

    assert {:error, :invalid_query} =
             InspectionSnapshot.query(snapshot, :capability_calls, %{
               "run_id" => "v2-run",
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
               "run_id" => "v2-run",
               "cursor" => tampered_cursor
             })

    {:ok, profile_capabilities} = InspectionCapability.from_snapshot(snapshot)
    {:ok, manifest_capabilities} = InspectionCapability.from_snapshot(snapshot, "private")

    arguments = [
      %{"limit" => 2},
      %{"run_id" => "v2-run"},
      %{"run_id" => "v2-run"},
      %{"run_id" => "v2-run"},
      %{"run_id" => "v2-run"},
      %{"run_id" => "v2-run"}
    ]

    Enum.zip([profile_capabilities, manifest_capabilities, arguments])
    |> Enum.each(fn {profile, manifest, query} ->
      assert profile.callback.(query) == manifest.callback.(query)
    end)

    File.write!(Path.join(inspection, "v2-run.inspection.jsonl"), "replaced")

    assert {:ok, %{"items" => [%{"request_id" => 7}]}} =
             InspectionSnapshot.query(snapshot, :provider_exchanges, %{
               "run_id" => "v2-run",
               "limit" => 1
             })
  end

  @tag :tmp_dir
  test "capability naming supports fixed profiles and manifest aliases", %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "named", 1)
    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())
    {:ok, snapshot} = InspectionSnapshot.start({:directory, inspection}, trace_snapshot)

    on_exit(fn ->
      InspectionSnapshot.stop(snapshot)
      TraceSnapshot.stop(trace_snapshot)
    end)

    assert {:ok, profile_capabilities} = InspectionCapability.from_snapshot(snapshot)
    assert {:ok, provider_capabilities} = InspectionCapability.from_snapshot(snapshot, "private")

    assert Enum.map(profile_capabilities, & &1.name) == [
             "inspection-list-runs",
             "inspection-model-exchanges",
             "inspection-capability-calls",
             "inspection-generated-sources",
             "inspection-effective-preludes",
             "inspection-provider-exchanges"
           ]

    assert Enum.map(provider_capabilities, & &1.name) == [
             "private.list-runs",
             "private.model-exchanges",
             "private.capability-calls",
             "private.generated-sources",
             "private.effective-preludes",
             "private.provider-exchanges"
           ]

    provider_exchange = List.last(provider_capabilities)

    assert {:ok, %{"items" => []}} =
             provider_exchange.callback.(%{"run_id" => "named"})

    snapshot_ref = Process.monitor(snapshot.pid)
    assert :ok = TraceSnapshot.stop(trace_snapshot)
    assert_receive {:DOWN, ^snapshot_ref, :process, _, :normal}
    assert {:error, :snapshot_unavailable} = InspectionSnapshot.info(snapshot)
  end

  @tag :tmp_dir
  test "an ordinary manifest acquires trace before private inspection and exposes alias operations",
       %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "manifest-run", 2)
    File.write!(Path.join(root, "workflow.clj"), "(ns app) (defn run [x] (return x))")

    host_path = Path.join(root, "host.json")

    File.write!(
      host_path,
      Jason.encode!(%{
        "install" => %{
          "history" => %{
            "source" => "ptc_trace_snapshot",
            "directory" => "traces"
          },
          "private-history" => %{
            "source" => "ptc_inspection_snapshot",
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
        "providers" => %{
          "mission" => [
            %{"name" => "private-history"},
            %{"name" => "history"}
          ]
        }
      })
    )

    {:ok, host} = HostConfig.load(host_path)
    {:ok, registry} = HostInstallation.registry(host)
    {:ok, built} = RunBuilder.load_and_build(manifest_path, registry)

    assert built.config.event_sink.policy == :private

    assert Enum.map(built.config.connector_snapshots, & &1["provider"]) == [
             "history",
             "private-history"
           ]

    capability =
      Map.fetch!(
        built.config.mission_environment.capabilities,
        "private-history.provider-exchanges"
      )

    assert {:ok, %{"items" => [%{"request_id" => 7}]}} =
             capability.callback.(%{"run_id" => "manifest-run", "limit" => 1})

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
            "directory" => "missing-traces"
          },
          "private-history" => %{
            "source" => "ptc_inspection_snapshot",
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
    {:ok, registry} = HostInstallation.registry(host)

    assert {:error, :provider_data_class_denied} =
             RunBuilder.load_and_build(manifest_path, registry)
  end

  @tag :tmp_dir
  test "orphan, duplicate, incomplete, malformed, symlink, and replacement captures fail closed",
       %{tmp_dir: root} do
    for scenario <- [:orphan, :duplicate, :incomplete, :malformed, :symlink, :replacement] do
      scenario_root = Path.join(root, Atom.to_string(scenario))
      {trace, inspection} = source_directories(scenario_root)
      write_run(trace, inspection, "valid", 1)
      {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())

      result =
        case scenario do
          :orphan ->
            write_inspection(inspection, "orphan", 1, canonical_events("orphan"))
            InspectionSnapshot.start({:directory, inspection}, trace_snapshot)

          :duplicate ->
            File.cp!(
              Path.join(inspection, "valid.inspection.jsonl"),
              Path.join(inspection, "duplicate.inspection.jsonl")
            )

            InspectionSnapshot.start({:directory, inspection}, trace_snapshot)

          :incomplete ->
            File.rm!(Path.join(inspection, "valid.inspection.jsonl"))
            write_incomplete_inspection(inspection, "valid")
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
  test "encoded, retained, result, and file ceilings are independent", %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "bounded", 1)
    {:ok, trace_snapshot} = TraceSnapshot.start({:directory, trace}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(trace_snapshot) end)

    assert {:error, :source_limit_exceeded} =
             InspectionSnapshot.start({:directory, inspection}, trace_snapshot,
               max_source_bytes: 1
             )

    assert {:error, :source_retained_limit_exceeded} =
             InspectionSnapshot.start({:directory, inspection}, trace_snapshot,
               max_retained_bytes: 1
             )

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
  test "safe metadata and owner lifecycle retain no private paths or payloads", %{tmp_dir: root} do
    {trace, inspection} = source_directories(root)
    write_run(trace, inspection, "owned", 2)
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

  defp write_run(trace_directory, inspection_directory, run_id, version) do
    events = canonical_events(run_id)
    File.write!(Path.join(trace_directory, "#{run_id}.jsonl"), encode_jsonl(events))
    write_inspection(inspection_directory, run_id, version, events)
  end

  defp write_inspection(directory, run_id, version, events) do
    {:ok, sink} =
      InspectionSink.start(
        run_id: run_id,
        trace_id: "trace-#{run_id}",
        schema_version: version
      )

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
      name: "workspace.read",
      arguments: %{"path" => "private-#{run_id}.txt"}
    })

    if version == 2 do
      emit!(sink, "mcp-request", %{capability_id: "tool-#{run_id}", request_id: 7}, %{
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
      name: "workspace.read",
      result: %{status: :ok, value: %{"text" => "secret-#{run_id}"}}
    })

    emit!(sink, "evaluation-source", %{evaluation_id: "eval-#{run_id}"}, %{
      environment: :mission,
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

    {:ok, records} = InspectionSink.records(sink)
    path = Path.join(directory, "#{run_id}.inspection.jsonl")
    :ok = InspectionArtifact.persist(path, records, events)
    :ok = InspectionSink.stop(sink)
  end

  defp write_incomplete_inspection(directory, run_id) do
    {:ok, sink} =
      InspectionSink.start(run_id: run_id, trace_id: "trace-#{run_id}", schema_version: 1)

    emit!(sink, "capability-input", %{capability_id: "tool-#{run_id}"}, %{
      environment: :mission,
      name: "workspace.read",
      arguments: %{"path" => "private"}
    })

    {:ok, records} = InspectionSink.records(sink)

    :ok =
      InspectionArtifact.persist(
        Path.join(directory, "#{run_id}.inspection.jsonl"),
        records,
        canonical_events(run_id)
      )

    :ok = InspectionSink.stop(sink)
  end

  defp emit!(sink, type, correlation, payload),
    do: :ok = InspectionSink.emit(sink, type, correlation, payload)

  defp canonical_events(run_id) do
    [
      event(run_id, 1, "run-started", %{
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
        "name" => "workspace.read"
      }),
      event(run_id, 4, "evaluation-started", %{
        "evaluation_id" => "eval-#{run_id}",
        "source_hash" => @source_hash,
        "source_bytes" => byte_size(@source)
      }),
      event(run_id, 5, "run-stopped", %{"outcome" => "ok"})
    ]
  end

  defp event(run_id, sequence, type, data) do
    %{
      "schema_version" => 1,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-07-26T12:00:0#{sequence}Z",
      "type" => type,
      "data" => data
    }
  end

  defp encode_jsonl(events), do: Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
end
