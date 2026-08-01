defmodule PtcRunner.Kernel.TraceCapabilityTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.TraceCapability
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment

  test "log.core requires source-scoped query capabilities" do
    assert {:ok, component} = Library.component("log.core")
    assert component.dependencies == ["cap"]

    assert {:error, %{id: "log.core", reason: :missing_component_dependency}} =
             Kernel.compile_bundle([component])

    assert {:ok, components} = Library.resolve_components([{:library, "log.core"}])
    assert Enum.map(components, & &1.id) == ["cap", "log.core"]
    assert {:ok, bundle} = Kernel.compile_bundle(components)

    assert {:error,
            {:missing_capability_requirement,
             ["trace-counters", "trace-get-run", "trace-list-runs", "trace-list-turns"]}} =
             MissionEnvironment.new(bundle: bundle)
  end

  test "an in-memory grant exposes canonical metadata, turns, counters, and stable pages" do
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "visible", trace_id: "trace-visible")
    run_kernel(sink, limits)

    assert {:ok, capabilities} = TraceCapability.new(source: sink, max_result_bytes: 100_000)

    assert Enum.all?(capabilities, fn capability ->
             match?(
               %{
                 effect: :read,
                 input_schema: %{"additionalProperties" => true},
                 output_schema: %{"additionalProperties" => true}
               },
               Capability.metadata(capability)
             )
           end)

    callbacks = Map.new(capabilities, &{&1.name, &1.callback})

    assert {:ok, first_page} = callbacks["trace-list-runs"].(%{"limit" => 1})
    assert [%{"run_id" => "visible"} = metadata] = first_page["items"]
    assert metadata["trace_id"] == "trace-visible"
    assert metadata["status"] == "ok"
    assert metadata["complete"]
    assert metadata["subordinate_evaluations"] == 0
    assert metadata["workflow_capability_calls"] == 0
    assert metadata["mission_capability_calls"] == 0
    assert metadata["error_count"] == 0
    assert is_integer(metadata["duration_ms"])

    assert metadata["workflow_prelude"] ==
             %{"component_ids" => [], "dependency_indices" => [], "hash" => nil}

    assert metadata["mission_prelude"] ==
             %{"component_ids" => [], "dependency_indices" => [], "hash" => nil}

    assert metadata["mission_inventory_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    assert is_integer(metadata["mission_inventory_bytes"])
    assert metadata["connector_snapshots"] == []
    assert first_page["next_cursor"] == nil

    assert {:ok, turns} =
             callbacks["trace-list-turns"].(%{
               "run_id" => "visible",
               "status" => "ok",
               "limit" => 10
             })

    assert Enum.map(turns["items"], & &1["type"]) == ["evaluation-stopped", "run-stopped"]

    assert {:ok,
            %{
              "events" => 4,
              "runs" => 1,
              "errors" => 0,
              "evaluations" => 1,
              "workflow_capability_calls" => 0,
              "mission_capability_calls" => 0
            }} = callbacks["trace-counters"].(%{"run_id" => "visible"})

    assert {:error, %{kind: :invalid_request}} =
             callbacks["trace-list-runs"].(%{"cursor" => 1})
  end

  test "a trace grant never discovers runs in another sink" do
    {:ok, limits} = Limits.new()
    {:ok, visible} = EventSink.start(:normal, limits, run_id: "visible")
    {:ok, hidden} = EventSink.start(:normal, limits, run_id: "hidden")
    run_kernel(visible, limits)
    run_kernel(hidden, limits)

    {:ok, capabilities} = TraceCapability.new(source: visible)
    list_runs = Enum.find(capabilities, &(&1.name == "trace-list-runs"))

    assert {:ok, %{"items" => [%{"run_id" => "visible"}]}} = list_runs.callback.(%{})
  end

  test "private memory traces require a distinct explicit grant" do
    {:ok, limits} = Limits.new()
    {:ok, private_sink} = EventSink.start(:private, limits, run_id: "private")
    run_kernel(private_sink, limits)

    assert {:error, :invalid_trace_capability} = TraceCapability.new(source: private_sink)
    assert {:ok, capabilities} = TraceCapability.new(source: {:private, private_sink})
    list_runs = Enum.find(capabilities, &(&1.name == "trace-list-runs"))

    assert {:ok, %{"items" => [%{"source" => "private"}]}} = list_runs.callback.(%{})
  end

  test "log.core queries the granted source from a mission without workflow inheritance" do
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)
    {:ok, source_sink} = EventSink.start(:normal, limits, run_id: "source-run")
    run_kernel(source_sink, limits)

    {:ok, trace_capabilities} = TraceCapability.new(source: source_sink)
    {:ok, kernel_component} = Library.component("kernel")
    {:ok, workflow_bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, log_components} = Library.resolve_components([{:library, "log.core"}])
    {:ok, mission_bundle} = Kernel.compile_bundle(log_components)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: workflow_bundle)

    {:ok, mission} =
      MissionEnvironment.new(bundle: mission_bundle, capabilities: trace_capabilities)

    {:ok, run_sink} = EventSink.start(:normal, limits, run_id: "query-run")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: run_sink
      )

    assert {:ok, %{value: %{outcome: :returned, value: %{"items" => [metadata]}}}} =
             Kernel.run(
               "(return (kernel/eval (program (return (log/runs {\"limit\" 1})))))",
               config
             )

    assert metadata["run_id"] == "source-run"

    {:ok, workflow_only_sink} =
      EventSink.start(:normal, limits, run_id: "query-run-workflow-only")

    {:ok, workflow_only_config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: workflow_only_sink
      )

    assert {:error, %{kind: :workflow_failed}} =
             Kernel.run("(return (tool/trace-list-runs {}))", workflow_only_config)
  end

  @tag :tmp_dir
  test "run summaries pass prelude dependency projections through verbatim", %{
    tmp_dir: directory
  } do
    v2_prelude = %{
      "component_ids" => ["kernel", "llm", "agent.core"],
      "dependency_indices" => [[], [], [0, 1]],
      "hash" => "abc"
    }

    legacy_prelude = %{"component_ids" => ["kernel"], "hash" => "def"}

    path = Path.join(directory, "trace.jsonl")

    component_override = %{
      "component_id" => "agent.core",
      "base_source_hash" => "sha256:" <> String.duplicate("a", 64),
      "source_hash" => "sha256:" <> String.duplicate("b", 64)
    }

    events = [
      decoded_event("v2-run", 1, "run-started", %{
        "workflow_prelude" => v2_prelude,
        "component_overrides" => [component_override]
      }),
      decoded_event("v2-run", 2, "run-stopped", %{"outcome" => "ok"}),
      decoded_event("legacy-run", 1, "run-started", %{"workflow_prelude" => legacy_prelude}),
      decoded_event("legacy-run", 2, "run-stopped", %{"outcome" => "ok"})
    ]

    assert :ok = TraceLog.append_jsonl(path, events)
    assert {:ok, trace_log} = TraceLog.new(source: {:file, path})
    assert {:ok, %{"items" => items}} = TraceLog.query(trace_log, :list_runs, %{})

    summaries = Map.new(items, &{&1["run_id"], &1})

    # The complete nested projection survives, and a legacy payload without
    # dependency_indices is never backfilled with invented edges.
    assert summaries["v2-run"]["workflow_prelude"] == v2_prelude
    assert summaries["legacy-run"]["workflow_prelude"] == legacy_prelude
    assert summaries["v2-run"]["component_overrides"] == [component_override]
    assert summaries["v2-run"]["positions"] == [1]
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
    private_path = Path.join(directory, "secret.private.jsonl")
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
    path = Path.join(directory, "run.inspection.jsonl")
    File.write!(path, jsonl_event("inspection", 1, "run-started"))

    assert {:error, :invalid_trace_log} = TraceLog.new(source: {:file, path})
    assert {:error, :invalid_trace_log} = TraceLog.new(source: {:private_file, path})

    assert {:ok, normal_log} = TraceLog.new(source: {:directory, directory})
    assert {:ok, private_log} = TraceLog.new(source: {:private_directory, directory})
    assert {:ok, %{"items" => []}} = TraceLog.query(normal_log, :list_runs, %{})
    assert {:ok, %{"items" => []}} = TraceLog.query(private_log, :list_runs, %{})
  end

  @tag :tmp_dir
  test "file and directory grants reject malformed, duplicate, changed, and oversized sources", %{
    tmp_dir: directory
  } do
    first = Path.join(directory, "a.jsonl")
    second = Path.join(directory, "b.jsonl")
    malformed = Path.join(directory, "c.jsonl")

    File.write!(first, jsonl_event("first", 1, "run-started"))
    File.write!(second, jsonl_event("second", 1, "run-started"))

    {:ok, capabilities} = TraceCapability.new(source: {:directory, directory})
    list_runs = Enum.find(capabilities, &(&1.name == "trace-list-runs"))

    assert {:ok, %{"items" => items}} = list_runs.callback.(%{"limit" => 1})
    assert length(items) == 1

    assert {:ok, %{"next_cursor" => cursor}} = list_runs.callback.(%{"limit" => 1})
    assert is_binary(cursor)

    File.write!(second, jsonl_event("changed", 1, "run-started"))

    assert {:error, %{kind: :invalid_request, details: "trace source changed"}} =
             list_runs.callback.(%{"limit" => 1, "cursor" => cursor})

    File.write!(malformed, ~s({"schema_version":1,"schema_version":1}\n))

    assert {:error, %{kind: :invalid_request, details: "malformed trace source"}} =
             list_runs.callback.(%{})

    assert {:ok, file_capabilities} =
             TraceCapability.new(source: {:file, first}, max_source_bytes: 1)

    file_runs = Enum.find(file_capabilities, &(&1.name == "trace-list-runs"))

    assert {:error, %{kind: :invalid_request, details: "trace source limit exceeded"}} =
             file_runs.callback.(%{})
  end

  @tag :tmp_dir
  test "cursors are bound to their operation and filters", %{tmp_dir: directory} do
    File.write!(Path.join(directory, "a.jsonl"), jsonl_event("first", 1, "run-started"))
    File.write!(Path.join(directory, "b.jsonl"), jsonl_event("second", 1, "run-started"))

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
    unsupported = Map.put(decoded_event("version", 1, "run-started"), "schema_version", 2)
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
  test "timestamp filters compare instants rather than timestamp spelling", %{tmp_dir: directory} do
    path = Path.join(directory, "timestamp.jsonl")
    event = %{decoded_event("time", 1, "run-started") | "timestamp" => "2026-07-12T12:00:00.1Z"}
    File.write!(path, Jason.encode!(event) <> "\n")
    {:ok, trace_log} = TraceLog.new(source: {:file, path})

    assert {:ok, %{"items" => [%{"run_id" => "time"}]}} =
             TraceLog.query(trace_log, :list_runs, %{"to" => "2026-07-12T12:00:00.10Z"})
  end

  defp run_kernel(sink, limits) do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, _result} = Kernel.run("(return 42)", config)
  end

  defp jsonl_event(run_id, sequence, type) do
    Jason.encode!(decoded_event(run_id, sequence, type)) <> "\n"
  end

  defp directory_identity(directory) do
    stat = File.stat!(directory)
    {stat.major_device, stat.minor_device, stat.inode}
  end

  defp decoded_event(run_id, sequence, type, data \\ %{}) do
    %{
      "schema_version" => 1,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-07-12T12:00:00Z",
      "type" => type,
      "data" => data
    }
  end
end
