defmodule PtcRunner.Kernel.TraceLogTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.TestSupport.TestHelpers

  test "analysis facts count only workflow llm-request exchanges" do
    events = [
      decoded_event("model-facts", 1, "run-started"),
      decoded_event("model-facts", 2, "capability-started", %{
        "capability_id" => "workflow-model",
        "environment" => "workflow",
        "name" => "llm-request"
      }),
      decoded_event("model-facts", 3, "capability-started", %{
        "capability_id" => "mission-collision",
        "environment" => "mission",
        "mission_name" => "default",
        "name" => "llm-request"
      }),
      decoded_event("model-facts", 4, "evaluation-started", %{
        "evaluation_id" => "mission-eval",
        "parent_evaluation_id" => "workflow-eval",
        "environment" => "mission"
      }),
      decoded_event("model-facts", 5, "evaluation-stopped", %{
        "evaluation_id" => "mission-eval",
        "parent_evaluation_id" => "workflow-eval",
        "environment" => "mission",
        "status" => "returned"
      }),
      decoded_event("model-facts", 6, "run-stopped", %{"outcome" => "ok"})
    ]

    assert %{
             facts_by_run_id: %{
               "model-facts" => %{
                 "evaluation_statuses" => %{"mission-eval" => "returned"},
                 "expected_model_exchange_ids" => ["workflow-model"]
               }
             }
           } = TraceLog.compile_analysis(events, :private)
  end

  @tag :tmp_dir
  test "run-result hashes are projected only from valid successful canonical completion", %{
    tmp_dir: directory
  } do
    query = fn events, name ->
      path = Path.join(directory, "result-hash-#{name}.jsonl")
      File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
      {:ok, log} = TraceLog.new(source: {:file, path})
      TraceLog.query(log, :get_run, %{"run_id" => name})
    end

    hash = result_hash(%{"answer" => 42})

    valid = [
      decoded_event("valid", 1, "run-started"),
      decoded_event("valid", 2, "run-stopped", %{
        "outcome" => "ok",
        "result_hash" => hash
      })
    ]

    assert {:ok, %{"result_hash" => ^hash}} = query.(valid, "valid")

    invalid_hash =
      put_in(valid, [Access.at(1), "data", "result_hash"], "sha256:" <> String.duplicate("A", 64))

    failed_with_hash = put_in(valid, [Access.at(1), "data", "outcome"], "error")
    unsupported = put_in(valid, [Access.at(0), "schema_version"], 3)

    assert {:error, :malformed_source} = query.(invalid_hash, "invalid-hash")
    assert {:error, :malformed_source} = query.(failed_with_hash, "failed-with-hash")
    assert {:error, :unsupported_version} = query.(unsupported, "unsupported")
  end

  @tag :tmp_dir
  test "run summaries pass prelude dependency projections through verbatim", %{
    tmp_dir: directory
  } do
    complete_prelude = %{
      "component_ids" => ["kernel", "llm", "agent.core"],
      "dependency_indices" => [[], [], [0, 1]],
      "hash" => String.duplicate("a", 64)
    }

    minimal_prelude = %{
      "component_ids" => ["kernel"],
      "dependency_indices" => [[]],
      "hash" => String.duplicate("d", 64)
    }

    path = Path.join(directory, "trace.jsonl")

    component_override = %{
      "component_id" => "agent.core",
      "base_source_hash" => "sha256:" <> String.duplicate("a", 64),
      "source_hash" => "sha256:" <> String.duplicate("b", 64)
    }

    events = [
      decoded_event("complete-run", 1, "run-started", %{
        "workflow_prelude" => complete_prelude,
        "component_overrides" => [component_override]
      }),
      decoded_event("complete-run", 2, "run-stopped", %{"outcome" => "ok"}),
      decoded_event("minimal-run", 1, "run-started", %{"workflow_prelude" => minimal_prelude}),
      decoded_event("minimal-run", 2, "run-stopped", %{"outcome" => "ok"})
    ]

    assert :ok = TraceLog.append_jsonl(path, events)
    assert {:ok, trace_log} = TraceLog.new(source: {:file, path})
    assert {:ok, %{"items" => items}} = TraceLog.query(trace_log, :list_runs, %{})

    summaries = Map.new(items, &{&1["run_id"], &1})

    # Dependency indices are passed through rather than invented.
    assert summaries["complete-run"]["workflow_prelude"] == complete_prelude
    assert summaries["minimal-run"]["workflow_prelude"] == minimal_prelude
    assert summaries["complete-run"]["component_overrides"] == [component_override]
    assert summaries["complete-run"]["positions"] == [1]
  end

  @tag :tmp_dir
  test "prelude projections load only at producer grade", %{tmp_dir: directory} do
    hash = String.duplicate("a", 64)

    valid = %{
      "component_ids" => ["kernel", "llm", "agent.core"],
      "dependency_indices" => [[], [], [0, 1]],
      "hash" => hash
    }

    # Written directly, because appending an invalid projection already fails
    # closed on the producer side; loading must not be the weaker gate.
    load = fn prelude, run_id ->
      path = Path.join(directory, "#{run_id}.jsonl")

      events = [
        decoded_event(run_id, 1, "run-started", %{"workflow_prelude" => prelude}),
        decoded_event(run_id, 2, "run-stopped", %{"outcome" => "ok"})
      ]

      File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))

      with {:ok, trace_log} <- TraceLog.new(source: {:file, path}),
           do: TraceLog.query(trace_log, :list_runs, %{})
    end

    assert {:ok, _page} = load.(valid, "valid")
    assert {:ok, _page} = load.(%{"component_ids" => [], "dependency_indices" => []}, "no-bundle")

    # A bundle that compiled no component still commits to an identity.
    assert {:ok, _page} =
             load.(
               %{"component_ids" => [], "dependency_indices" => [], "hash" => hash},
               "empty-bundle"
             )

    rejected = %{
      "duplicate-ids" => %{valid | "component_ids" => ["kernel", "kernel", "agent.core"]},
      "absent-indices" => Map.delete(valid, "dependency_indices"),
      "short-indices" => %{valid | "dependency_indices" => [[], []]},
      "forward-reference" => %{valid | "dependency_indices" => [[], [2], [0, 1]]},
      "self-reference" => %{valid | "dependency_indices" => [[], [], [2]]},
      "unsorted-indices" => %{valid | "dependency_indices" => [[], [], [1, 0]]},
      "duplicate-indices" => %{valid | "dependency_indices" => [[], [], [0, 0]]},
      "prefixed-hash" => %{valid | "hash" => "sha256:" <> hash},
      "uppercase-hash" => %{valid | "hash" => String.upcase(hash)},
      "absent-hash" => Map.delete(valid, "hash"),
      "components-without-hash" => %{valid | "hash" => nil},
      "hash-without-projection" => %{
        "component_ids" => ["kernel"],
        "dependency_indices" => [[]]
      }
    }

    for {run_id, prelude} <- rejected do
      assert {:error, :malformed_source} = load.(prelude, run_id),
             "expected #{run_id} to fail closed"
    end

    assert {:error, :malformed_source} =
             TraceLog.append_jsonl(
               Path.join(directory, "appended.jsonl"),
               [
                 decoded_event("appended", 1, "run-started", %{
                   "workflow_prelude" => rejected["absent-indices"]
                 })
               ]
             )
  end

  @tag :tmp_dir
  test "mission prelude projections are validated like the workflow projection", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "trace.jsonl")

    events = [
      decoded_event("mission-run", 1, "run-started", %{
        "missions" => %{
          "default" => %{
            "prelude" => %{
              "component_ids" => ["kernel"],
              "dependency_indices" => [[0]],
              "hash" => String.duplicate("a", 64)
            }
          }
        }
      }),
      decoded_event("mission-run", 2, "run-stopped", %{"outcome" => "ok"})
    ]

    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
    assert {:ok, trace_log} = TraceLog.new(source: {:file, path})
    assert {:error, :malformed_source} = TraceLog.query(trace_log, :list_runs, %{})
  end

  @tag :tmp_dir
  test "run summaries expose total evaluations and filter by workflow bundle", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "trace.jsonl")
    bundle_a = String.duplicate("a", 64)
    bundle_b = String.duplicate("b", 64)

    events = [
      decoded_event("bundle-a-run", 1, "run-started", %{
        "labels" => %{"name" => "sha256:same-name"},
        "workflow_prelude" => %{
          "component_ids" => ["kernel"],
          "dependency_indices" => [[]],
          "hash" => bundle_a
        }
      }),
      decoded_event("bundle-a-run", 2, "evaluation-started", %{
        "environment" => "workflow",
        "evaluation_id" => "workflow-evaluation"
      }),
      decoded_event("bundle-a-run", 3, "evaluation-stopped", %{
        "environment" => "workflow",
        "evaluation_id" => "workflow-evaluation",
        "status" => "ok"
      }),
      decoded_event("bundle-a-run", 4, "run-stopped", %{"outcome" => "ok"}),
      decoded_event("bundle-b-run", 1, "run-started", %{
        "labels" => %{"name" => "sha256:same-name"},
        "workflow_prelude" => %{
          "component_ids" => ["kernel"],
          "dependency_indices" => [[]],
          "hash" => bundle_b
        }
      }),
      decoded_event("bundle-b-run", 2, "run-stopped", %{"outcome" => "ok"})
    ]

    assert :ok = TraceLog.append_jsonl(path, events)
    assert {:ok, trace_log} = TraceLog.new(source: {:file, path})

    assert {:ok,
            %{
              "items" => [
                %{
                  "run_id" => "bundle-a-run",
                  "evaluations" => 1,
                  "subordinate_evaluations" => 0
                }
              ]
            }} = TraceLog.query(trace_log, :list_runs, %{"bundle" => bundle_a})

    assert {:ok, %{"items" => [%{"run_id" => "bundle-b-run"}]}} =
             TraceLog.query(trace_log, :list_runs, %{"bundle" => bundle_b})

    assert {:ok, %{"runs" => 1, "evaluations" => 1}} =
             TraceLog.query(trace_log, :counters, %{"bundle" => bundle_a})

    assert {:error, :invalid_query} =
             TraceLog.query(trace_log, :list_runs, %{"bundle_hash" => bundle_a})
  end

  @tag :tmp_dir
  test "the run error count is the errored rows, not every event carrying one", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "error-count.jsonl")

    events = [
      decoded_event("errored-run", 1, "run-started", %{}),
      decoded_event("errored-run", 2, "evaluation-started", %{
        "environment" => "workflow",
        "evaluation_id" => "workflow-evaluation"
      }),
      decoded_event("errored-run", 3, "capability-started", %{
        "environment" => "workflow",
        "capability_id" => "capability-1",
        "name" => "kernel-mission-model-context"
      }),
      decoded_event("errored-run", 4, "capability-stopped", %{
        "environment" => "workflow",
        "capability_id" => "capability-1",
        "name" => "kernel-mission-model-context",
        "status" => "error"
      }),
      decoded_event("errored-run", 5, "evaluation-stopped", %{
        "environment" => "workflow",
        "evaluation_id" => "workflow-evaluation",
        "status" => "error"
      }),
      decoded_event("errored-run", 6, "run-stopped", %{
        "outcome" => "error",
        "reason" => "explicit_failure",
        "failure_kind" => "mission-unavailable"
      })
    ]

    assert :ok = TraceLog.append_jsonl(path, events)
    assert {:ok, trace_log} = TraceLog.new(source: {:file, path})

    # One errored evaluation and one errored capability call are the two rows a
    # reader can open. The run's own outcome is its status, not a third error.
    assert {:ok, %{"items" => [%{"error_count" => 2, "status" => "error"}]}} =
             TraceLog.query(trace_log, :list_runs, %{})
  end

  @tag :tmp_dir
  test "canonical validation rejects malformed workflow prelude metadata", %{tmp_dir: directory} do
    path = Path.join(directory, "malformed-workflow-prelude.jsonl")

    events = [
      decoded_event("malformed-workflow-prelude", 1, "run-started", %{
        "workflow_prelude" => "not-a-prelude-projection"
      })
    ]

    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
    assert {:ok, trace_log} = TraceLog.new(source: {:file, path})

    assert {:error, :malformed_source} =
             TraceLog.query(trace_log, :list_runs, %{"bundle" => "bundle-a"})
  end

  @tag :tmp_dir
  test "canonical JSONL append and reload preserves event order", %{tmp_dir: directory} do
    path = Path.join(directory, "trace.jsonl")
    first = decoded_event("append", 1, "run-started")
    second = decoded_event("append", 2, "run-stopped", %{"outcome" => "ok"})

    assert :ok = TraceLog.append_jsonl(path, [first])
    assert :ok = TraceLog.append_jsonl(path, [second])
    assert {:ok, trace_log} = TraceLog.new(source: {:file, path})

    assert {:ok, %{"items" => [%{"run_id" => "append", "complete" => true}]}} =
             TraceLog.query(trace_log, :list_runs, %{})
  end

  @tag :tmp_dir
  test "trace publication preserves symlink-sensitive parent components", %{tmp_dir: directory} do
    physical_parent = Path.join(directory, "physical")
    nested = Path.join(physical_parent, "nested")
    alias_path = Path.join(directory, "alias")
    File.mkdir_p!(nested)
    File.ln_s!(nested, alias_path)

    event = decoded_event("component-path", 1, "run-started")
    append_path = Path.join([alias_path, "..", "append.jsonl"])
    publish_path = Path.join([alias_path, "..", "publish.jsonl"])

    assert :ok = TraceLog.append_jsonl(append_path, [event])
    assert File.regular?(Path.join(physical_parent, "append.jsonl"))
    refute File.exists?(Path.join(directory, "append.jsonl"))

    assert :ok = TraceLog.publish_jsonl(publish_path, [event])
    assert File.regular?(Path.join(physical_parent, "publish.jsonl"))
    refute File.exists?(Path.join(directory, "publish.jsonl"))
  end

  @tag :tmp_dir
  test "trace append follows a direct symlink to its physical parent", %{tmp_dir: directory} do
    physical_parent = Path.join(directory, "physical-parent")
    alias_parent = Path.join(directory, "alias-parent")
    File.mkdir!(physical_parent)
    File.ln_s!(physical_parent, alias_parent)

    event = decoded_event("direct-parent-link", 1, "run-started")
    path = Path.join(alias_parent, "trace.jsonl")

    assert :ok = TraceLog.append_jsonl(path, [event])
    assert File.regular?(Path.join(physical_parent, "trace.jsonl"))
  end

  @tag :tmp_dir
  test "missing case-fold aliases share one append-lock identity", %{tmp_dir: directory} do
    upper = Path.join(directory, "Run.jsonl")
    lower = Path.join(directory, "run.jsonl")
    sigma = Path.join(directory, "σ.jsonl")
    final_sigma = Path.join(directory, "ς.jsonl")

    assert {:ok, identity} = TraceLog.append_lock_identity(upper)
    assert {:ok, ^identity} = TraceLog.append_lock_identity(lower)

    assert {:ok, sigma_identity} = TraceLog.append_lock_identity(sigma)
    assert {:ok, ^sigma_identity} = TraceLog.append_lock_identity(final_sigma)
  end

  @tag :tmp_dir
  @tag :slow
  test "a first-file append retains one cross-runtime lease after creation", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "first-file.jsonl")
    first = decoded_event("first-runtime", 1, "run-started")
    second = decoded_event("second-runtime", 1, "run-started")
    port = start_paused_append_runtime(path, first)

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
    end)

    assert_receive {^port, {:data, {:eol, "APPEND_READY"}}}, 10_000

    second_append = Task.async(fn -> TraceLog.append_jsonl(path, [second]) end)
    assert Task.yield(second_append, 250) == nil

    assert true = Port.command(port, "X\n")
    assert_receive {^port, {:data, {:eol, "APPEND_RESULT=:ok"}}}, 10_000
    assert_receive {^port, {:exit_status, 0}}, 10_000
    assert Task.await(second_append, 10_000) == :ok

    assert {:ok, trace_log} = TraceLog.new(source: {:file, path})
    assert {:ok, %{"items" => runs}} = TraceLog.query(trace_log, :list_runs, %{"limit" => 100})
    assert Enum.sort(Enum.map(runs, & &1["run_id"])) == ["first-runtime", "second-runtime"]
  end

  @tag :tmp_dir
  @tag :slow
  test "concurrent same-path appends retain every canonical batch", %{tmp_dir: directory} do
    path = Path.join(directory, "concurrent.jsonl")
    parent = self()

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          send(parent, {:append_ready, self()})

          receive do
            :append ->
              event =
                decoded_event("concurrent-#{index}", 1, "run-started", %{
                  "padding" => String.duplicate("x", 4_096)
                })

              TraceLog.append_jsonl(path, [event])
          end
        end)
      end

    Enum.each(tasks, fn _task ->
      assert_receive {:append_ready, task_pid}
      assert Enum.any?(tasks, &(&1.pid == task_pid))
    end)

    Enum.each(tasks, &send(&1.pid, :append))
    assert Enum.all?(Task.await_many(tasks, 30_000), &(&1 == :ok))

    assert {:ok, trace_log} = TraceLog.new(source: {:file, path})
    assert {:ok, %{"items" => runs}} = TraceLog.query(trace_log, :list_runs, %{"limit" => 100})
    assert length(runs) == 8
  end

  @tag :tmp_dir
  @tag :slow
  test "hard-link aliases share the same cross-runtime append lease", %{tmp_dir: directory} do
    path = Path.join(directory, "aliased.jsonl")
    alias_path = Path.join(directory, "aliased-hard-link.jsonl")
    File.write!(path, "")
    File.ln!(path, alias_path)
    parent = self()

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          send(parent, {:aliased_append_ready, self()})

          receive do
            :append ->
              selected_path = if rem(index, 2) == 0, do: alias_path, else: path

              event =
                decoded_event("aliased-#{index}", 1, "run-started", %{
                  "padding" => String.duplicate("x", 4_096)
                })

              TraceLog.append_jsonl(selected_path, [event])
          end
        end)
      end

    Enum.each(tasks, fn _task -> assert_receive {:aliased_append_ready, _pid} end)
    Enum.each(tasks, &send(&1.pid, :append))
    assert Enum.all?(Task.await_many(tasks, 30_000), &(&1 == :ok))

    assert {:ok, trace_log} = TraceLog.new(source: {:file, path})
    assert {:ok, %{"items" => runs}} = TraceLog.query(trace_log, :list_runs, %{"limit" => 100})
    assert length(runs) == 8
  end

  @tag :tmp_dir
  test "successful appends consume their helper exit messages", %{tmp_dir: directory} do
    path = Path.join(directory, "mailbox.jsonl")
    event = decoded_event("mailbox", 1, "run-started")

    assert :ok = TraceLog.append_jsonl(path, [event])
    refute_receive {_port, {:exit_status, _status}}, 100
  end

  defp start_paused_append_runtime(path, event) do
    executable = System.find_executable("elixir") || flunk("elixir is required for this test")

    code =
      """
      path = #{inspect(path)}
      [event] = :erlang.binary_to_term(Base.decode64!(#{inspect(encode_term([event]))}))
      hook = fn :after_file_ready ->
        IO.puts("APPEND_READY")
        "X\\n" = IO.gets("")
        :ok
      end
      result =
        PtcRunner.Kernel.TraceLog.append_jsonl(path, [event], append_hook: hook)
      IO.puts("APPEND_RESULT=" <> inspect(result))
      """

    code_paths =
      :code.get_path()
      |> Enum.flat_map(fn path -> ["-pa", List.to_string(path)] end)

    args = Enum.concat(code_paths, ["-e", code])

    Port.open(
      {:spawn_executable, executable},
      [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 1_024},
        args: args
      ]
    )
  end

  defp encode_term(term), do: term |> :erlang.term_to_binary() |> Base.encode64()

  @tag :tmp_dir
  test "atomic publication is no-clobber, retry-safe, and cleans partial temporaries", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "publication.jsonl")
    events = [decoded_event("publication", 1, "run-started")]

    assert :ok = TraceLog.publish_jsonl(path, events)
    first = File.read!(path)
    assert :ok = TraceLog.publish_jsonl(path, events)
    assert File.read!(path) == first

    parent = self()

    replacement =
      Task.async(fn ->
        TraceLog.publish_jsonl(path, events,
          fault_hook: fn
            :before_publication_read ->
              send(parent, {:publication_read_ready, self()})

              receive do
                :continue_publication_read -> :ok
              end

            _stage ->
              :ok
          end
        )
      end)

    assert_receive {:publication_read_ready, publisher}, 1_000
    oversized = Path.join(directory, "oversized-replacement")
    File.write!(oversized, String.duplicate("x", byte_size(first) + 1))
    File.rm!(path)
    File.ln_s!(oversized, path)
    send(publisher, :continue_publication_read)
    assert {:error, :trace_collision} = Task.await(replacement)
    File.rm!(path)
    File.rm!(oversized)
    File.write!(path, first)

    different = [decoded_event("different", 1, "run-started")]
    assert {:error, :trace_collision} = TraceLog.publish_jsonl(path, different)
    assert File.read!(path) == first

    replaced_temporary_path = Path.join(directory, "replaced-temporary.jsonl")

    replaced_temporary =
      Task.async(fn ->
        TraceLog.publish_jsonl(replaced_temporary_path, events,
          fault_hook: fn
            :after_sync ->
              send(parent, {:temporary_synced, self()})

              receive do
                :continue_temporary_publication -> :ok
              end

            _stage ->
              :ok
          end
        )
      end)

    assert_receive {:temporary_synced, temporary_publisher}, 1_000

    [temporary] =
      directory
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "replaced-temporary.jsonl.ptc-tmp-"))

    temporary = Path.join(directory, temporary)
    File.rm!(temporary)
    File.write!(temporary, "attacker-controlled replacement")
    send(temporary_publisher, :continue_temporary_publication)

    assert {:error, :trace_collision} = Task.await(replaced_temporary)

    if File.exists?(replaced_temporary_path),
      do: assert(File.read!(replaced_temporary_path) != first)

    refute Enum.any?(File.ls!(directory), &String.contains?(&1, ".ptc-tmp-"))

    partial_path = Path.join(directory, "partial.jsonl")

    assert {:error, :trace_persistence_failed} =
             TraceLog.publish_jsonl(partial_path, events,
               fault_hook: fn
                 :during_write -> {:error, :partial_write}
                 _stage -> :ok
               end
             )

    refute File.exists?(partial_path)
    refute Enum.any?(File.ls!(directory), &String.contains?(&1, ".ptc-tmp-"))

    before_write_path = Path.join(directory, "before-write.jsonl")

    assert {:error, :trace_persistence_failed} =
             TraceLog.publish_jsonl(before_write_path, events,
               fault_hook: fn
                 :before_write -> {:error, :injected}
                 _stage -> :ok
               end
             )

    refute File.exists?(before_write_path)

    published_path = Path.join(directory, "published-before-ack.jsonl")
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    hook = fn
      :after_publish ->
        Agent.get_and_update(attempts, fn
          0 -> {{:error, :injected}, 1}
          count -> {:ok, count + 1}
        end)

      _stage ->
        :ok
    end

    assert {:error, :trace_persistence_failed} =
             TraceLog.publish_jsonl(published_path, events, fault_hook: hook)

    assert File.regular?(published_path)
    assert :ok = TraceLog.publish_jsonl(published_path, events, fault_hook: hook)
    refute Enum.any?(File.ls!(directory), &String.contains?(&1, ".ptc-tmp-"))

    cleanup_path = Path.join(directory, "cleanup-fault.jsonl")

    assert {:error, :trace_persistence_failed} =
             TraceLog.publish_jsonl(cleanup_path, events,
               fault_hook: fn
                 :cleanup -> {:error, :injected}
                 _stage -> :ok
               end
             )

    assert File.regular?(cleanup_path)
    refute Enum.any?(File.ls!(directory), &String.contains?(&1, ".ptc-tmp-"))
    assert :ok = TraceLog.publish_jsonl(cleanup_path, events)
  end

  @tag :tmp_dir
  test "atomic publication rejects a replaced destination directory identity", %{
    tmp_dir: directory
  } do
    destination = Path.join(directory, "destination")
    displaced = Path.join(directory, "displaced")
    File.mkdir!(destination)
    expected_identity = directory_identity(destination)
    File.rename!(destination, displaced)
    File.mkdir!(destination)
    path = Path.join(destination, "identity.jsonl")
    events = [decoded_event("identity", 1, "run-started")]

    assert {:error, :trace_persistence_failed} =
             TraceLog.publish_jsonl(path, events, expected_parent_identity: expected_identity)

    refute File.exists?(path)
    assert File.ls!(destination) == []
  end

  @tag :tmp_dir
  test "identity-bound publication cannot write through a replaced parent path", %{
    tmp_dir: directory
  } do
    destination = Path.join(directory, "destination")
    displaced = Path.join(directory, "displaced")
    File.mkdir!(destination)
    expected_identity = directory_identity(destination)
    path = Path.join(destination, "bound.jsonl")
    events = [decoded_event("bound", 1, "run-started")]

    hook = fn
      :before_write ->
        File.rename!(destination, displaced)
        File.mkdir!(destination)
        :ok

      _stage ->
        :ok
    end

    assert {:error, :trace_persistence_failed} =
             TraceLog.publish_jsonl(path, events,
               expected_parent_identity: expected_identity,
               fault_hook: hook
             )

    assert File.ls!(destination) == []
    assert File.regular?(Path.join(displaced, "bound.jsonl"))
  end

  @tag :tmp_dir
  test "private JSONL sources require reserved names and explicit grants", %{tmp_dir: directory} do
    normal_path = Path.join(directory, "normal.jsonl")
    private_path = Path.join(directory, "private.private.jsonl")
    normal_event = decoded_event("normal", 1, "run-started")
    private_event = decoded_event("private", 1, "run-started")

    assert :ok = TraceLog.append_jsonl(normal_path, [normal_event])
    assert :ok = TraceLog.append_jsonl(private_path, [private_event], private: true)

    assert {:error, :invalid_trace_log} =
             TraceLog.append_jsonl(normal_path, [private_event], private: true)

    assert {:error, :invalid_trace_log} = TraceLog.append_jsonl(private_path, [normal_event])
    assert {:error, :invalid_trace_log} = TraceLog.new(source: {:file, private_path})
    assert {:ok, private_log} = TraceLog.new(source: {:private_file, private_path})
    assert {:ok, normal_log} = TraceLog.new(source: {:directory, directory})

    assert {:ok, private_directory_log} =
             TraceLog.new(source: {:private_directory, directory})

    assert {:ok, %{"items" => [%{"run_id" => "normal", "source" => "sanitized"}]}} =
             TraceLog.query(normal_log, :list_runs, %{})

    assert {:ok, %{"items" => [%{"run_id" => "private", "source" => "private"}]}} =
             TraceLog.query(private_log, :list_runs, %{})

    assert {:ok, %{"items" => [%{"run_id" => "private", "source" => "private"}]}} =
             TraceLog.query(private_directory_log, :list_runs, %{})
  end

  @tag :tmp_dir
  test "run listings report the trace files their source kind refused to read", %{
    tmp_dir: directory
  } do
    File.write!(Path.join(directory, "normal.jsonl"), jsonl_event("normal", 1, "run-started"))

    File.write!(
      Path.join(directory, "run.ptcins"),
      jsonl_event("inspection", 1, "run-started")
    )

    assert :ok =
             TraceLog.append_jsonl(
               Path.join(directory, "private.private.jsonl"),
               [decoded_event("private", 1, "run-started")],
               private: true
             )

    assert {:ok, sanitized_log} = TraceLog.new(source: {:directory, directory})
    assert {:ok, private_log} = TraceLog.new(source: {:private_directory, directory})

    assert {:ok, %{"items" => [%{"run_id" => "normal"}]} = page} =
             TraceLog.query(sanitized_log, :list_runs, %{})

    assert page["excluded_private_trace_files"] == 1
    refute Map.has_key?(page, "excluded_sanitized_trace_files")

    # Exclusion and pagination are different numbers. Nothing was truncated
    # here, and the field that reports truncation must keep saying so.
    assert page["omitted_count"] == 0

    assert {:ok, %{"excluded_private_trace_files" => 1}} =
             TraceLog.query(sanitized_log, :counters, %{})

    # A run-scoped answer would attach a directory-wide exclusion to one run,
    # where it states nothing true about that run.
    assert {:ok, run} = TraceLog.query(sanitized_log, :get_run, %{"run_id" => "normal"})
    refute Map.has_key?(run, "excluded_private_trace_files")

    assert {:ok, %{"items" => [%{"run_id" => "private"}]} = private_page} =
             TraceLog.query(private_log, :list_runs, %{})

    assert private_page["excluded_sanitized_trace_files"] == 1
  end

  @tag :tmp_dir
  test "a run listing with nothing excluded reports no exclusion at all", %{tmp_dir: directory} do
    File.write!(Path.join(directory, "normal.jsonl"), jsonl_event("normal", 1, "run-started"))

    assert {:ok, sanitized_log} = TraceLog.new(source: {:directory, directory})
    assert {:ok, page} = TraceLog.query(sanitized_log, :list_runs, %{})

    refute Map.has_key?(page, "excluded_private_trace_files")
    refute Map.has_key?(page, "excluded_sanitized_trace_files")
  end

  @tag :tmp_dir
  test "private trace creation reports chmod failures without raising", %{tmp_dir: directory} do
    path = Path.join(directory, "chmod-failure.private.jsonl")
    event = decoded_event("private-chmod", 1, "run-started")

    hook = fn
      :before_private_chmod -> {:error, :simulated_chmod_failure}
      _stage -> :ok
    end

    assert {:error, :source_unavailable} =
             TraceLog.append_jsonl(path, [event], private: true, append_hook: hook)

    refute File.exists?(path)
  end

  @tag :tmp_dir
  test "private appends reject a replaceable parent directory", %{tmp_dir: directory} do
    replaceable = Path.join(directory, "replaceable")
    File.mkdir!(replaceable)
    File.chmod!(replaceable, 0o777)

    path = Path.join(replaceable, "secret.private.jsonl")
    event = decoded_event("private-parent", 1, "run-started")

    assert {:error, :source_unavailable} =
             TraceLog.append_jsonl(path, [event], private: true)

    refute File.exists?(path)
  end

  @tag :tmp_dir
  test "private appends reject an existing file that is not already owner-only", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "wide.private.jsonl")
    File.write!(path, "")
    File.chmod!(path, 0o644)
    event = decoded_event("private-mode", 1, "run-started")

    assert {:error, :source_unavailable} =
             TraceLog.append_jsonl(path, [event], private: true)

    assert File.read!(path) == ""
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o644
  end

  @tag :tmp_dir
  test "inspection artifacts are never accepted as canonical or private trace sources", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "run.ptcins")
    File.write!(path, jsonl_event("inspection", 1, "run-started"))

    assert {:error, :invalid_trace_log} = TraceLog.new(source: {:file, path})
    assert {:error, :invalid_trace_log} = TraceLog.new(source: {:private_file, path})

    assert {:ok, normal_log} = TraceLog.new(source: {:directory, directory})
    assert {:ok, private_log} = TraceLog.new(source: {:private_directory, directory})
    assert {:ok, %{"items" => []}} = TraceLog.query(normal_log, :list_runs, %{})
    assert {:ok, %{"items" => []}} = TraceLog.query(private_log, :list_runs, %{})
  end

  @tag :tmp_dir
  test "cursors are bound to their operation and filters", %{tmp_dir: directory} do
    File.write!(Path.join(directory, "first.jsonl"), jsonl_event("first", 1, "run-started"))
    File.write!(Path.join(directory, "second.jsonl"), jsonl_event("second", 1, "run-started"))

    {:ok, trace_log} = TraceLog.new(source: {:directory, directory})

    assert {:ok, %{"next_cursor" => cursor}} =
             TraceLog.query(trace_log, :list_runs, %{"limit" => 1})

    assert {:error, :invalid_query} =
             TraceLog.query(trace_log, :list_runs, %{
               "limit" => 1,
               "status" => "ok",
               "cursor" => cursor
             })

    assert {:error, :invalid_query} =
             TraceLog.query(trace_log, :list_turns, %{
               "run_id" => "first",
               "cursor" => cursor
             })
  end

  @tag :tmp_dir
  test "canonical validation preserves version failures and rejects mixed run identity", %{
    tmp_dir: directory
  } do
    version_path = Path.join(directory, "version.jsonl")
    mixed_path = Path.join(directory, "mixed.jsonl")
    shared_trace_path = Path.join(directory, "shared-trace.jsonl")
    stopped_only_path = Path.join(directory, "stopped-only.jsonl")
    stopped_before_start_path = Path.join(directory, "stopped-before-start.jsonl")
    event_after_stop_path = Path.join(directory, "event-after-stop.jsonl")
    unsupported = Map.put(decoded_event("version", 1, "run-started"), "schema_version", 3)
    mixed = [decoded_event("same", 1, "run-started"), decoded_event("same", 1, "run-stopped")]
    mixed = put_in(mixed, [Access.at(1), "trace_id"], "different-trace")

    shared_trace = [
      decoded_event("first", 1, "run-started"),
      decoded_event("second", 2, "run-started")
    ]

    shared_trace = put_in(shared_trace, [Access.at(1), "trace_id"], "trace-first")
    File.write!(version_path, Jason.encode!(unsupported) <> "\n")
    File.write!(mixed_path, Enum.map_join(mixed, "", &(Jason.encode!(&1) <> "\n")))
    File.write!(shared_trace_path, Enum.map_join(shared_trace, "", &(Jason.encode!(&1) <> "\n")))

    File.write!(
      stopped_only_path,
      Jason.encode!(decoded_event("stopped", 1, "run-stopped")) <> "\n"
    )

    stopped_before_start = [
      decoded_event("reversed", 1, "run-stopped"),
      decoded_event("reversed", 2, "run-started")
    ]

    event_after_stop = [
      decoded_event("post-stop", 1, "run-started"),
      decoded_event("post-stop", 2, "run-stopped"),
      decoded_event("post-stop", 3, "workflow-annotation")
    ]

    File.write!(
      stopped_before_start_path,
      Enum.map_join(stopped_before_start, "", &(Jason.encode!(&1) <> "\n"))
    )

    File.write!(
      event_after_stop_path,
      Enum.map_join(event_after_stop, "", &(Jason.encode!(&1) <> "\n"))
    )

    {:ok, version_log} = TraceLog.new(source: {:file, version_path})
    {:ok, mixed_log} = TraceLog.new(source: {:file, mixed_path})
    {:ok, shared_trace_log} = TraceLog.new(source: {:file, shared_trace_path})
    {:ok, stopped_only_log} = TraceLog.new(source: {:file, stopped_only_path})
    {:ok, stopped_before_start_log} = TraceLog.new(source: {:file, stopped_before_start_path})
    {:ok, event_after_stop_log} = TraceLog.new(source: {:file, event_after_stop_path})
    assert {:error, :unsupported_version} = TraceLog.query(version_log, :list_runs, %{})
    assert {:error, :malformed_source} = TraceLog.query(mixed_log, :list_runs, %{})
    assert {:error, :malformed_source} = TraceLog.query(shared_trace_log, :list_runs, %{})
    assert {:error, :malformed_source} = TraceLog.query(stopped_only_log, :list_runs, %{})
    assert {:error, :malformed_source} = TraceLog.query(stopped_before_start_log, :list_runs, %{})
    assert {:error, :malformed_source} = TraceLog.query(event_after_stop_log, :list_runs, %{})
  end

  @tag :tmp_dir
  test "current validation rejects missing or misplaced mission attribution", %{
    tmp_dir: directory
  } do
    query = fn events, name ->
      path = Path.join(directory, "#{name}.jsonl")
      File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
      {:ok, log} = TraceLog.new(source: {:file, path})
      TraceLog.query(log, :list_runs, %{})
    end

    valid = [
      decoded_event("current", 1, "run-started", %{"missions" => %{}}),
      decoded_event("current", 2, "evaluation-started", %{
        "environment" => "mission",
        "mission_name" => "reader",
        "evaluation_id" => "e1"
      }),
      decoded_event("current", 3, "run-stopped", %{"outcome" => "ok"})
    ]

    assert {:ok, _result} = query.(valid, "valid")

    missing = update_in(valid, [Access.at(1), "data"], &Map.delete(&1, "mission_name"))

    misplaced =
      put_in(valid, [Access.at(1), "data"], %{
        "environment" => "workflow",
        "mission_name" => "reader"
      })

    singular_start =
      put_in(valid, [Access.at(0), "data"], %{
        "mission_prelude" => %{},
        "missions" => %{}
      })

    for {label, events} <- [
          missing: missing,
          misplaced: misplaced,
          singular_start: singular_start
        ] do
      case query.(events, "invalid-#{label}") do
        {:error, :malformed_source} -> :ok
        other -> flunk("accepted invalid #{label} trace: #{inspect(other)}")
      end
    end
  end

  @tag :tmp_dir
  test "current validation rejects unproven parent evaluation edges", %{tmp_dir: directory} do
    query = fn events, name ->
      path = Path.join(directory, "parent-edge-#{name}.jsonl")
      File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
      {:ok, log} = TraceLog.new(source: {:file, path})
      TraceLog.query(log, :list_runs, %{})
    end

    valid = [
      decoded_event("parent-edge", 1, "run-started", %{"missions" => %{}}),
      decoded_event("parent-edge", 2, "evaluation-started", %{
        "environment" => "workflow",
        "evaluation_id" => "workflow-eval"
      }),
      decoded_event("parent-edge", 3, "evaluation-started", %{
        "environment" => "mission",
        "mission_name" => "reader",
        "evaluation_id" => "mission-eval",
        "parent_evaluation_id" => "workflow-eval"
      }),
      decoded_event("parent-edge", 4, "evaluation-stopped", %{
        "environment" => "mission",
        "mission_name" => "reader",
        "evaluation_id" => "mission-eval",
        "parent_evaluation_id" => "workflow-eval",
        "status" => "ok"
      }),
      decoded_event("parent-edge", 5, "evaluation-stopped", %{
        "environment" => "workflow",
        "evaluation_id" => "workflow-eval",
        "status" => "ok"
      }),
      decoded_event("parent-edge", 6, "run-stopped", %{"outcome" => "ok"})
    ]

    assert {:ok, _result} = query.(valid, "valid")

    orphaned =
      put_in(valid, [Access.at(2), "data", "parent_evaluation_id"], "missing-eval")

    wrong_parent_environment =
      put_in(valid, [Access.at(1), "data", "environment"], "mission")
      |> put_in([Access.at(1), "data", "mission_name"], "reader")

    parent_on_workflow =
      put_in(valid, [Access.at(1), "data", "parent_evaluation_id"], "workflow-eval")

    mismatched_stop =
      put_in(valid, [Access.at(3), "data", "parent_evaluation_id"], "other-eval")

    missing_stop_parent =
      update_in(valid, [Access.at(3), "data"], &Map.delete(&1, "parent_evaluation_id"))

    for {label, events} <- [
          orphaned: orphaned,
          wrong_parent_environment: wrong_parent_environment,
          parent_on_workflow: parent_on_workflow,
          mismatched_stop: mismatched_stop,
          missing_stop_parent: missing_stop_parent
        ] do
      assert {:error, :malformed_source} = query.(events, "invalid-#{label}")
    end
  end

  test "mission filters narrow counters by explicit identity" do
    events = [
      decoded_event("mission-filter", 1, "run-started", %{"missions" => %{}}),
      decoded_event("mission-filter", 2, "evaluation-started", %{
        "environment" => "mission",
        "mission_name" => "reader",
        "evaluation_id" => "reader-eval"
      }),
      decoded_event("mission-filter", 3, "capability-started", %{
        "environment" => "mission",
        "mission_name" => "reader",
        "capability_id" => "reader-call",
        "name" => "read"
      }),
      decoded_event("mission-filter", 4, "evaluation-started", %{
        "environment" => "mission",
        "mission_name" => "writer",
        "evaluation_id" => "writer-eval"
      }),
      decoded_event("mission-filter", 5, "run-stopped", %{"outcome" => "ok"})
    ]

    assert {:ok, counters} =
             TraceLog.query_loaded(
               events,
               "mission-filter",
               :counters,
               %{"mission_name" => "reader"},
               100_000,
               :sanitized
             )

    assert counters["events"] == 2
    assert counters["runs"] == 1
    assert counters["evaluations"] == 1
    assert counters["evaluations_by_mission"] == %{"reader" => 1}
    assert counters["mission_capability_calls"] == 1
    assert counters["workflow_capability_calls"] == 0
    assert counters["llm_usage"] == []
    assert counters["llm_usage_by_model"] == []
    assert counters["unattributed_model_calls"] == 0
  end

  test "counters group eligible LLM usage by each run's validated resolved model" do
    first = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:vendor/model-a")
    second = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:vendor/model-b")
    reviewer = TestHelpers.llm_snapshot("reviewer", "review-v2", "openrouter:vendor/model-a")

    events =
      llm_counter_run("first", first, "ok", %{"input" => 3, "output" => 2}) ++
        llm_counter_run("second", second, "ok", %{"input" => 5}) ++
        llm_counter_run("review", reviewer, "ok", %{"input" => 7}, "reviewer", "review-v2") ++
        llm_counter_run("private", nil, "error", nil)

    assert {:ok, counters} =
             TraceLog.query_loaded(events, "models", :counters, %{}, 100_000, :sanitized)

    assert counters["llm_usage"] == [
             %{
               "alias" => "reviewer",
               "installation_revision" => "review-v2",
               "calls" => 1,
               "successful_calls" => 1,
               "usage_calls" => 1,
               "missing_usage_calls" => 0,
               "usage_overflow" => false,
               "usage" => %{"input" => 7}
             },
             %{
               "alias" => "writer",
               "installation_revision" => "stable-v1",
               "calls" => 3,
               "successful_calls" => 2,
               "usage_calls" => 2,
               "missing_usage_calls" => 0,
               "usage_overflow" => false,
               "usage" => %{"input" => 8, "output" => 2}
             }
           ]

    assert counters["llm_usage_by_model"] == [
             %{
               "resolved_model" => "openrouter:vendor/model-a",
               "calls" => 2,
               "successful_calls" => 2,
               "usage_calls" => 2,
               "missing_usage_calls" => 0,
               "usage_overflow" => false,
               "usage" => %{"input" => 10, "output" => 2}
             },
             %{
               "resolved_model" => "openrouter:vendor/model-b",
               "calls" => 1,
               "successful_calls" => 1,
               "usage_calls" => 1,
               "missing_usage_calls" => 0,
               "usage_overflow" => false,
               "usage" => %{"input" => 5}
             }
           ]

    assert counters["unattributed_model_calls"] == 1

    assert Enum.sum(Enum.map(counters["llm_usage_by_model"], & &1["calls"])) +
             counters["unattributed_model_calls"] ==
             Enum.sum(Enum.map(counters["llm_usage"], & &1["calls"]))

    assert {:ok, filtered} =
             TraceLog.query_loaded(
               events,
               "models",
               :counters,
               %{"run_id" => "second"},
               100_000,
               :sanitized
             )

    assert Enum.map(filtered["llm_usage_by_model"], & &1["resolved_model"]) == [
             "openrouter:vendor/model-b"
           ]

    assert {:error, :result_limit_exceeded} =
             TraceLog.query_loaded(events, "models", :counters, %{}, 100, :sanitized)
  end

  test "run summaries expose the canonical terminal LLM spend projection" do
    events = [
      decoded_event("usage-total", 1, "run-started"),
      decoded_event("usage-total", 2, "capability-stopped", %{
        "environment" => "workflow",
        "name" => "llm-request",
        "alias" => "writer",
        "installation_revision" => "stable-v1",
        "status" => "ok",
        "usage" => %{
          "input" => 120,
          "output" => 30,
          "total_cost" => %{"currency" => "USD", "microunits" => 4_200}
        }
      }),
      decoded_event("usage-total", 3, "run-stopped", %{
        "outcome" => "ok",
        "usage" => %{
          "llm_budget" => %{
            "total_tokens" => %{
              "state" => "available",
              "limit" => 1_000,
              "reserved" => 0,
              "charged" => 150,
              "remaining" => 850,
              "refused" => 0
            },
            "cost" => %{
              "state" => "available",
              "currency" => "USD",
              "limit_microusd" => 10_000,
              "reserved_microusd" => 0,
              "charged_microusd" => 4_200,
              "remaining_microusd" => 5_800,
              "refused" => 0
            }
          },
          "llm_spend" => %{
            "state" => "available",
            "input" => 120,
            "output" => 30,
            "total_cost" => %{"currency" => "USD", "microunits" => 4_200}
          }
        }
      })
    ]

    assert {:ok, %{"items" => [run]}} =
             TraceLog.query_loaded(
               events,
               "usage-total",
               :list_runs,
               %{},
               100_000,
               :sanitized
             )

    assert run["llm_spend"] == %{
             "state" => "available",
             "input" => 120,
             "output" => 30,
             "total_cost" => %{"currency" => "USD", "microunits" => 4_200}
           }

    assert run["llm_budget"]["total_tokens"]["charged"] == 150
    assert run["llm_budget"]["cost"]["charged_microusd"] == 4_200
  end

  test "invalid or ambiguous LLM snapshots make calls unattributed without failing counters" do
    valid = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:vendor/model-a")
    tampered = put_in(valid, ["acquisition", "resolved_model"], "openrouter:vendor/model-b")

    for {label, snapshots} <- [
          duplicate: [valid, valid],
          tampered: [tampered],
          legacy: [Map.delete(valid, "snapshot_hash")],
          missing: []
        ] do
      events = llm_counter_run(to_string(label), snapshots, "ok", %{"input" => 1})

      assert {:ok,
              %{
                "llm_usage_by_model" => [],
                "unattributed_model_calls" => 1,
                "llm_usage" => [%{"calls" => 1}]
              }} =
               TraceLog.query_loaded(
                 events,
                 to_string(label),
                 :counters,
                 %{},
                 100_000,
                 :sanitized
               )
    end
  end

  @tag :tmp_dir
  test "canonical validation rejects malformed source-check usage counts", %{
    tmp_dir: directory
  } do
    invalid_usages = [
      "invalid",
      [],
      %{"subordinate_source_checks" => -1},
      %{"subordinate_source_checks" => "1"}
    ]

    for {usage, index} <- Enum.with_index(invalid_usages) do
      path = Path.join(directory, "invalid-usage-#{index}.jsonl")

      events = [
        decoded_event("invalid-usage-#{index}", 1, "run-started"),
        decoded_event("invalid-usage-#{index}", 2, "run-stopped", %{"usage" => usage})
      ]

      File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
      {:ok, trace_log} = TraceLog.new(source: {:file, path})

      assert {:error, :malformed_source} = TraceLog.query(trace_log, :list_runs, %{})
    end
  end

  @tag :tmp_dir
  test "canonical validation rejects terminal events without usage", %{tmp_dir: directory} do
    path = Path.join(directory, "missing-terminal-usage.jsonl")

    stopped =
      "missing-terminal-usage"
      |> decoded_event(2, "run-stopped", %{"outcome" => "ok"})
      |> update_in(["data"], &Map.delete(&1, "usage"))

    events = [decoded_event("missing-terminal-usage", 1, "run-started"), stopped]
    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
    {:ok, trace_log} = TraceLog.new(source: {:file, path})

    assert {:error, :malformed_source} = TraceLog.query(trace_log, :list_runs, %{})
  end

  @tag :tmp_dir
  test "canonical validation rejects malformed terminal LLM spend", %{tmp_dir: directory} do
    path = Path.join(directory, "invalid-llm-spend.jsonl")

    events = [
      decoded_event("invalid-llm-spend", 1, "run-started"),
      decoded_event("invalid-llm-spend", 2, "run-stopped", %{
        "usage" => %{
          "llm_spend" => %{"state" => "available", "input" => 1, "output" => 2}
        }
      })
    ]

    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
    {:ok, trace_log} = TraceLog.new(source: {:file, path})

    assert {:error, :malformed_source} = TraceLog.query(trace_log, :list_runs, %{})
  end

  @tag :tmp_dir
  test "timestamp filters compare instants rather than timestamp spelling", %{tmp_dir: directory} do
    path = Path.join(directory, "timestamp.jsonl")
    event = %{decoded_event("time", 1, "run-started") | "timestamp" => "2026-07-12T12:00:00.1Z"}
    File.write!(path, Jason.encode!(event) <> "\n")
    {:ok, trace_log} = TraceLog.new(source: {:file, path})

    assert {:ok, %{"items" => [%{"run_id" => "time"}]}} =
             TraceLog.query(trace_log, :list_runs, %{"to" => "2026-07-12T12:00:00.10Z"})
  end

  defp jsonl_event(run_id, sequence, type) do
    Jason.encode!(decoded_event(run_id, sequence, type)) <> "\n"
  end

  defp directory_identity(directory) do
    stat = File.stat!(directory)
    {stat.major_device, stat.minor_device, stat.inode}
  end

  defp decoded_event(run_id, sequence, type, data \\ %{}) do
    data =
      case {type, data["environment"]} do
        {"run-started", _environment} ->
          Map.put_new(data, "missions", %{})

        {"run-stopped", _environment} ->
          Map.put_new(data, "usage", %{
            "llm_budget" => %{"total_tokens" => nil, "cost" => nil}
          })

        {_type, "mission"} ->
          Map.put_new(data, "mission_name", "default")

        _other ->
          data
      end

    %{
      "schema_version" => 2,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-07-12T12:00:00Z",
      "type" => type,
      "data" => data
    }
  end

  defp result_hash(value) do
    {:ok, encoded} = DeterministicJSON.encode(value)
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)
  end

  defp llm_counter_run(
         run_id,
         snapshot_or_snapshots,
         status,
         usage,
         alias_name \\ "writer",
         revision \\ "stable-v1"
       ) do
    snapshots =
      case snapshot_or_snapshots do
        nil -> []
        snapshots when is_list(snapshots) -> snapshots
        snapshot -> [snapshot]
      end

    stopped_data = %{
      "environment" => "workflow",
      "name" => "llm-request",
      "alias" => alias_name,
      "installation_revision" => revision,
      "status" => status
    }

    stopped_data = if is_nil(usage), do: stopped_data, else: Map.put(stopped_data, "usage", usage)

    [
      decoded_event(run_id, 1, "run-started", %{
        "missions" => %{},
        "connector_snapshots" => snapshots
      }),
      decoded_event(run_id, 2, "capability-stopped", stopped_data),
      decoded_event(run_id, 3, "run-stopped", %{"outcome" => "ok"})
    ]
  end
end
