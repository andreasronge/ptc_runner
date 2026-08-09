defmodule PtcRunner.Kernel.ProviderLifecycleTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.ReplSessionOwner
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.LLM.ReqLLMAdapter
  alias PtcRunner.TestSupport.ProviderSessionFixture
  alias ReqLLM.ToolCall

  @schema %{"type" => "object", "additionalProperties" => false}

  test "registry normalizes legacy capabilities and validates resource-bearing builds" do
    {:ok, capability} = capability("fixture")

    builders = %{
      "legacy" => fn _config, _context -> {:ok, capability} end,
      "resource" => fn _config, context ->
        assert context.owner == self()
        assert context.limits.workflow_timeout_ms > 0

        {:ok,
         %{
           capabilities: [capability],
           snapshot: %{"provider" => "resource"},
           close: fn -> :ok end
         }}
      end
    }

    {:ok, registry} = ProviderRegistry.new(builders)
    limits = limits()

    context = %{
      application_content_digest: String.duplicate("0", 64),
      destination: :workflow,
      owner: self(),
      limits: limits,
      installed_limits: limits
    }

    assert {:ok, %{capabilities: [^capability], snapshot: nil, close: nil}} =
             ProviderRegistry.build(registry, "legacy", %{}, context)

    assert {:ok,
            %{
              capabilities: [^capability],
              snapshot: %{"provider" => "resource"},
              close: close
            }} = ProviderRegistry.build(registry, "resource", %{}, context)

    assert is_function(close, 0)
  end

  test "registry rejects directory-bearing provider contexts before invoking a builder" do
    parent = self()

    builder = fn _config, _context ->
      send(parent, :provider_invoked)
      capability("fixture")
    end

    {:ok, registry} = ProviderRegistry.new(%{"fixture" => builder})
    limits = limits()

    legacy_context = %{
      directory: "/application",
      destination: :workflow,
      owner: self(),
      limits: limits,
      installed_limits: limits
    }

    assert {:error, :invalid_provider_context} =
             ProviderRegistry.build(registry, "fixture", %{}, legacy_context)

    refute_received :provider_invoked
  end

  test "registry convenience builds reject registrar-backed contexts" do
    parent = self()

    builder = fn _config, _context ->
      send(parent, :provider_invoked)
      capability("fixture")
    end

    {:ok, registry} = ProviderRegistry.new(%{"fixture" => builder})
    limits = limits()
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)

    context = %{
      application_content_digest: String.duplicate("0", 64),
      destination: :workflow,
      owner: ResourceRegistrar.owner(registrar),
      resource_registrar: registrar,
      limits: limits,
      installed_limits: limits
    }

    assert {:error, :invalid_provider_context} =
             ProviderRegistry.build(registry, "fixture", %{}, context)

    refute_received :provider_invoked
    assert :ok = ProviderSession.close(session)
  end

  @tag :tmp_dir
  test "all providers preflight before credentials resolve or any provider acquires", %{
    tmp_dir: dir
  } do
    parent = self()
    File.write!(Path.join(dir, "workflow.clj"), "(ns app) (defn run [x] (return x))")

    staged = fn %{"id" => id}, _context ->
      send(parent, {:provider_phase, :prepare, id})

      {:ok,
       %{
         credential_names: ["shared"],
         preflight: fn ->
           send(parent, {:provider_phase, :preflight, id})

           {:ok,
            fn %{"shared" => "secret"} ->
              send(parent, {:provider_phase, :acquire, id})
              {:ok, capability} = capability("provided.#{id}")
              {:ok, capability}
            end}
         end
       }}
    end

    resolver = fn ["shared"] ->
      send(parent, {:provider_phase, :resolve, "shared"})
      {:ok, %{"shared" => "secret"}}
    end

    {:ok, registry} =
      ProviderRegistry.new(%{"staged" => ProviderRegistry.staged(staged)},
        credential_resolver: resolver
      )

    manifest =
      manifest(
        dir,
        [provider("staged", %{"id" => "workflow"})],
        [provider("staged", %{"id" => "mission"})]
      )

    {:ok, request} = ApplicationPackage.request_directory(manifest, result_projection: :native)
    assert {:ok, built} = RunBuilder.build(request, registry)
    assert :ok = RunBuilder.close(built)

    assert_receive {:provider_phase, :prepare, "workflow"}
    assert_receive {:provider_phase, :prepare, "mission"}
    assert_receive {:provider_phase, :preflight, "workflow"}
    assert_receive {:provider_phase, :preflight, "mission"}
    assert_receive {:provider_phase, :resolve, "shared"}
    assert_receive {:provider_phase, :acquire, "workflow"}
    assert_receive {:provider_phase, :acquire, "mission"}
  end

  @tag :tmp_dir
  test "provider services order acquisition without changing manifest capability order", %{
    tmp_dir: dir
  } do
    parent = self()
    export = make_ref()
    File.write!(Path.join(dir, "workflow.clj"), "(ns app) (defn run [x] (return x))")

    consumer = fn %{}, _context ->
      {:ok,
       %{
         credential_names: [],
         requires: [:canonical_trace_snapshot],
         preflight: fn ->
           {:ok,
            fn %{}, %{canonical_trace_snapshot: ^export} ->
              send(parent, :consumer_acquired)
              {:ok, capability} = capability("consumer")

              {:ok,
               %{
                 capabilities: [capability],
                 close: fn ->
                   send(parent, :consumer_closed)
                   :ok
                 end
               }}
            end}
         end
       }}
    end

    producer = fn %{}, _context ->
      {:ok,
       %{
         credential_names: [],
         provides: [:canonical_trace_snapshot],
         preflight: fn ->
           {:ok,
            fn %{}, %{} ->
              send(parent, :producer_acquired)
              {:ok, capability} = capability("producer")

              {:ok,
               %{
                 capabilities: [capability],
                 exports: %{canonical_trace_snapshot: export},
                 close: fn ->
                   send(parent, :producer_closed)
                   :ok
                 end
               }}
            end}
         end
       }}
    end

    {:ok, registry} =
      ProviderRegistry.new(%{
        "consumer" => ProviderRegistry.staged(consumer),
        "producer" => ProviderRegistry.staged(producer)
      })

    path = manifest(dir, [], [provider("consumer", %{}), provider("producer", %{})])
    {:ok, built} = RunBuilder.load_and_build(path, registry)

    assert built.config.mission_environment.capabilities
           |> Map.values()
           |> Enum.map(& &1.name)
           |> Enum.sort() == ["consumer", "producer"]

    assert_receive :producer_acquired
    assert_receive :consumer_acquired

    assert :ok = RunBuilder.close(built)
    assert_receive :consumer_closed
    assert_receive :producer_closed
  end

  @tag :tmp_dir
  test "missing provider services fail before preflight and credentials", %{tmp_dir: dir} do
    parent = self()
    File.write!(Path.join(dir, "workflow.clj"), "(ns app) (defn run [x] (return x))")

    consumer = fn %{}, _context ->
      {:ok,
       %{
         credential_names: ["secret"],
         requires: [:canonical_trace_snapshot],
         preflight: fn ->
           send(parent, :dependency_preflighted)
           {:ok, fn _credentials, _services -> {:error, :unexpected_acquisition} end}
         end
       }}
    end

    resolver = fn _names ->
      send(parent, :dependency_credentials_resolved)
      {:ok, %{"secret" => "secret"}}
    end

    {:ok, registry} =
      ProviderRegistry.new(%{"consumer" => ProviderRegistry.staged(consumer)},
        credential_resolver: resolver
      )

    path = manifest(dir, [], [provider("consumer", %{})])

    assert {:error, :provider_dependency_unavailable} =
             RunBuilder.load_and_build(path, registry)

    refute_received :dependency_preflighted
    refute_received :dependency_credentials_resolved
  end

  @tag :tmp_dir
  test "preflight failure touches neither credentials nor provider acquisition", %{tmp_dir: dir} do
    parent = self()
    File.write!(Path.join(dir, "workflow.clj"), "(ns app) (defn run [x] (return x))")

    staged = fn %{"id" => id}, _context ->
      {:ok,
       %{
         credential_names: ["secret"],
         preflight: fn ->
           send(parent, {:preflight, id})

           if id == "bad" do
             {:error, :fixture_preflight_failed}
           else
             {:ok, fn _credentials -> send(parent, {:acquired, id}) end}
           end
         end
       }}
    end

    resolver = fn _names ->
      send(parent, :credentials_resolved)
      {:ok, %{"secret" => "secret"}}
    end

    {:ok, registry} =
      ProviderRegistry.new(%{"staged" => ProviderRegistry.staged(staged)},
        credential_resolver: resolver
      )

    manifest =
      manifest(
        dir,
        [provider("staged", %{"id" => "ok"})],
        [provider("staged", %{"id" => "bad"})]
      )

    {:ok, request} = ApplicationPackage.request_directory(manifest, result_projection: :native)
    assert {:error, :fixture_preflight_failed} = RunBuilder.build(request, registry)
    assert_receive {:preflight, "ok"}
    assert_receive {:preflight, "bad"}
    refute_received :credentials_resolved
    refute_received {:acquired, _id}
  end

  @tag :tmp_dir
  test "acquisition failure closes exactly the acquired prefix in reverse order", %{tmp_dir: dir} do
    parent = self()
    File.write!(Path.join(dir, "workflow.clj"), "(ns app) (defn run [x] (return x))")

    staged = fn %{"id" => id}, _context ->
      {:ok,
       %{
         credential_names: [],
         preflight: fn ->
           {:ok,
            fn %{} ->
              if id == "bad" do
                {:error, :fixture_acquisition_failed}
              else
                {:ok, capability} = capability("provided.#{id}")

                {:ok,
                 %{
                   capabilities: [capability],
                   snapshot: nil,
                   close: fn ->
                     send(parent, {:closed_after_acquisition_failure, id})
                     :ok
                   end
                 }}
              end
            end}
         end
       }}
    end

    {:ok, registry} =
      ProviderRegistry.new(%{
        "staged" => ProviderRegistry.staged(staged),
        "staged-second" => ProviderRegistry.staged(staged),
        "staged-bad" => ProviderRegistry.staged(staged)
      })

    manifest =
      manifest(
        dir,
        [
          provider("staged", %{"id" => "first"}),
          provider("staged-second", %{"id" => "second"}),
          provider("staged-bad", %{"id" => "bad"})
        ],
        []
      )

    {:ok, request} = ApplicationPackage.request_directory(manifest, result_projection: :native)
    assert {:error, :fixture_acquisition_failed} = RunBuilder.build(request, registry)
    assert_receive {:closed_after_acquisition_failure, first_closed}
    assert_receive {:closed_after_acquisition_failure, second_closed}
    assert [first_closed, second_closed] == ["second", "first"]
    refute_receive {:closed_after_acquisition_failure, _id}
  end

  @tag :tmp_dir
  test "registrar commit failure bounds an unregistered provider closer", %{tmp_dir: dir} do
    parent = self()
    File.write!(Path.join(dir, "workflow.clj"), "(ns app) (defn run [x] (return x))")
    {:ok, installed_limits} = Limits.new(provider_cleanup_timeout_ms: 200)

    staged = fn %{"id" => id}, context ->
      registrar = context.resource_registrar

      {:ok,
       %{
         credential_names: [],
         preflight: fn ->
           {:ok,
            fn %{} ->
              if id == "later" do
                assert :ok = ResourceRegistrar.abort(registrar)
              end

              {:ok, capability} = capability("provided.commit-failure.#{id}")

              {:ok,
               %{
                 capabilities: [capability],
                 close: fn ->
                   send(parent, {:commit_failure_close_started, id})

                   receive do
                     :never -> :ok
                   end
                 end
               }}
            end}
         end
       }}
    end

    {:ok, registry} =
      ProviderRegistry.new(
        %{
          "staged-earlier" => ProviderRegistry.staged(staged),
          "staged-later" => ProviderRegistry.staged(staged)
        },
        installed_limits: installed_limits
      )

    path =
      manifest(
        dir,
        [
          provider("staged-earlier", %{"id" => "earlier"}),
          provider("staged-later", %{"id" => "later"})
        ],
        []
      )

    {:ok, request} =
      ApplicationPackage.request_directory(path,
        installed_limits: installed_limits,
        result_projection: :native
      )

    build = Task.async(fn -> RunBuilder.build(request, registry) end)

    assert {:ok, {:error, :provider_cleanup_failed}} = Task.yield(build, 350)
    assert_receive {:commit_failure_close_started, "later"}
    assert_receive {:commit_failure_close_started, "earlier"}
  end

  @tag :tmp_dir
  test "a private provider makes the effective run and result class private", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "workflow.clj"), "(ns app) (defn run [x] (return x))")
    {:ok, capability} = capability("provided.private")

    staged = fn _config, _context ->
      {:ok,
       %{
         credential_names: [],
         data_class: :private_inspection,
         accepts_data: [:normal, :private_inspection],
         preflight: fn ->
           {:ok,
            fn %{} ->
              {:ok,
               %{
                 capabilities: [capability],
                 data_class: :private_inspection,
                 accepts_data: [:normal, :private_inspection]
               }}
            end}
         end
       }}
    end

    {:ok, registry} =
      ProviderRegistry.new(%{"private" => ProviderRegistry.staged(staged)})

    path = manifest(dir, [], [provider("private", %{})])
    {:ok, built} = RunBuilder.load_and_build(path, registry)

    assert built.config.event_sink.policy == :private
    assert :ok = RunBuilder.close(built)
  end

  @tag :tmp_dir
  test "effective data-class denial happens before preflight, credentials, or acquisition", %{
    tmp_dir: dir
  } do
    parent = self()
    File.write!(Path.join(dir, "workflow.clj"), "(ns app) (defn run [x] (return x))")

    staged = fn _config, _context ->
      {:ok,
       %{
         credential_names: ["secret"],
         data_class: :private_inspection,
         accepts_data: [:normal],
         preflight: fn ->
           send(parent, :provider_preflighted)
           {:ok, fn _credentials -> send(parent, :provider_acquired) end}
         end
       }}
    end

    resolver = fn _names ->
      send(parent, :credentials_resolved)
      {:ok, %{"secret" => "secret"}}
    end

    {:ok, registry} =
      ProviderRegistry.new(%{"private" => ProviderRegistry.staged(staged)},
        credential_resolver: resolver
      )

    path = manifest(dir, [], [provider("private", %{})])

    assert {:error, :provider_data_class_denied} =
             RunBuilder.load_and_build(path, registry)

    refute_received :provider_preflighted
    refute_received :credentials_resolved
    refute_received :provider_acquired
  end

  test "built-in LLM adaptation preserves provider-valid correction history" do
    request = %{
      "messages" => [
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "call-1",
              "name" => "run_ptc_lisp",
              "args" => %{"program" => "(return 42)"}
            }
          ]
        }
      ]
    }

    adapted = ProviderRegistry.adapter_request(request)

    assert [%{tool_calls: [%ToolCall{} = call]}] = ReqLLMAdapter.build_messages(adapted)
    assert call.function.name == "run_ptc_lisp"
    assert Jason.decode!(call.function.arguments) == %{"program" => "(return 42)"}
  end

  @tag :tmp_dir
  test "assembly failure closes successful providers in reverse order", %{tmp_dir: dir} do
    parent = self()
    File.write!(Path.join(dir, "workflow.clj"), "(ns app) (defn run [x] (tool/missing {}))")

    manifest =
      manifest(
        dir,
        [provider("owned", %{"id" => "workflow"})],
        [provider("owned", %{"id" => "mission"})]
      )

    {:ok, request} = ApplicationPackage.request_directory(manifest, result_projection: :native)

    builder = fn %{"id" => id}, _context ->
      {:ok, capability} = capability("provided.#{id}")

      {:ok,
       %{
         capabilities: [capability],
         snapshot: nil,
         close: fn ->
           send(parent, {:closed, id})
           :ok
         end
       }}
    end

    {:ok, registry} = ProviderRegistry.new(%{"owned" => builder})

    assert {:error, {:missing_capability_requirement, ["missing"]}} =
             RunBuilder.build(request, registry)

    assert_receive {:closed, "mission"}
    assert_receive {:closed, "workflow"}
  end

  @tag :tmp_dir
  test "normal run and REPL closure release provider resources", %{tmp_dir: dir} do
    parent = self()
    File.write!(Path.join(dir, "workflow.clj"), "(ns app) (defn run [x] (return x))")

    manifest = manifest(dir, [provider("owned", %{"id" => "run"})], [])
    {:ok, registry} = registry_with_close(parent)

    assert {:ok, _result} = RunBuilder.run(manifest, registry)
    assert_receive {:closed, "run"}

    repl_manifest = manifest(dir, [provider("owned", %{"id" => "repl"})], [])
    {:ok, built} = RunBuilder.load_and_build(repl_manifest, registry)
    {:ok, repl} = ReplSession.new(config: built.config)
    assert {:ok, _events} = ReplSession.close(repl)
    assert_receive {:closed, "repl"}

    refute Process.alive?(built.config.event_sink.pid)

    unused_manifest = manifest(dir, [provider("owned", %{"id" => "unused"})], [])
    {:ok, unused} = RunBuilder.load_and_build(unused_manifest, registry)
    assert :ok = RunBuilder.close(unused)
    assert_receive {:closed, "unused"}
    refute Process.alive?(unused.config.event_sink.pid)
  end

  @tag :tmp_dir
  test "trace preflight failure happens before provider preflight or acquisition", %{tmp_dir: dir} do
    parent = self()
    File.write!(Path.join(dir, "workflow.clj"), "(ns app) (defn run [x] (return x))")

    builder = fn %{}, _context ->
      send(parent, :trace_provider_prepared)

      {:ok,
       %{
         credential_names: [],
         preflight: fn ->
           send(parent, :trace_provider_preflighted)

           {:ok,
            fn %{} ->
              send(parent, :trace_provider_acquired)
              capability("provided.trace-preflight")
            end}
         end
       }}
    end

    {:ok, registry} =
      ProviderRegistry.new(%{"staged" => ProviderRegistry.staged(builder)})

    manifest = manifest(dir, [provider("staged", %{})], [])

    assert {:error, {:trace_preflight_failed, :normal_trace_requires_normal_suffix}} =
             RunBuilder.run(manifest, registry, trace_path: Path.join(dir, "wrong.private.jsonl"))

    refute_receive :trace_provider_prepared
    refute_receive :trace_provider_preflighted
    refute_receive :trace_provider_acquired
  end

  @tag :tmp_dir
  test "provider cleanup failure is reported by runs and explicit close", %{tmp_dir: dir} do
    parent = self()
    File.write!(Path.join(dir, "workflow.clj"), "(ns app) (defn run [x] (return x))")

    manifest = manifest(dir, [provider("cleanup-fails", %{})], [])

    builder = fn %{}, _context ->
      {:ok, capability} = capability("provided.cleanup")

      {:ok,
       %{
         capabilities: [capability],
         snapshot: nil,
         close: fn ->
           send(parent, :cleanup_attempted)
           {:error, :fixture_cleanup_failed}
         end
       }}
    end

    {:ok, registry} = ProviderRegistry.new(%{"cleanup-fails" => builder})

    assert {:error,
            %PtcRunner.Kernel.Error{
              kind: :provider_cleanup_error,
              reason: :provider_cleanup_failed
            }} = RunBuilder.run(manifest, registry)

    assert_receive :cleanup_attempted
    refute_receive :cleanup_attempted

    assert {:ok, repl_built} = RunBuilder.load_and_build(manifest, registry)
    assert {:ok, repl} = ReplSession.new(config: repl_built.config)

    assert {:error, :provider_cleanup_failed, close_events} = ReplSession.close(repl)
    assert List.last(close_events).data.reason == :provider_cleanup_failed

    trace_path = Path.join(dir, "cleanup-failure.jsonl")
    assert :ok = TraceLog.append_jsonl(trace_path, close_events)
    assert {:ok, _trace} = TraceLog.new(source: {:file, trace_path})
    assert File.read!(trace_path) =~ ~s("reason":"provider_cleanup_failed")

    assert_receive :cleanup_attempted
    refute_receive :cleanup_attempted

    assert {:ok, abort_built} = RunBuilder.load_and_build(manifest, registry)
    assert {:ok, abort_repl} = ReplSession.new(config: abort_built.config)
    sink_pid = abort_built.config.event_sink.pid
    :erlang.trace(sink_pid, true, [:receive])

    assert {:error, :provider_cleanup_failed, abort_events} =
             ReplSession.abort(abort_repl, :frontend_exit)

    assert List.last(abort_events).data.reason == :provider_cleanup_failed

    assert_receive {:trace, ^sink_pid, :receive,
                    {:"$gen_call", _from,
                     {_token,
                      {:finalize_and_events, %{outcome: :error, reason: :provider_cleanup_failed}}}}}

    assert_receive :cleanup_attempted
    refute_receive :cleanup_attempted

    assert {:ok, dead_sink_built} = RunBuilder.load_and_build(manifest, registry)
    assert {:ok, dead_sink_repl} = ReplSession.new(config: dead_sink_built.config)
    EventSink.stop(dead_sink_built.config.event_sink)

    assert {:error, :provider_cleanup_failed} = ReplSession.close(dead_sink_repl)
    assert_receive :cleanup_attempted
    refute_receive :cleanup_attempted

    assert {:ok, dead_state_built} = RunBuilder.load_and_build(manifest, registry)
    assert {:ok, dead_state_repl} = ReplSession.new(config: dead_state_built.config)
    [{_, {owner_pid, token}}] = :ets.lookup(dead_state_repl.access, dead_state_repl.id)
    assert {:ok, _config, run_state} = ReplSessionOwner.resources(owner_pid, token)
    RunState.stop(run_state)

    assert {:error, :provider_cleanup_failed} =
             ReplSession.abort(dead_state_repl, :frontend_exit)

    assert_receive :cleanup_attempted
    refute_receive :cleanup_attempted

    assert {:ok, built} = RunBuilder.load_and_build(manifest, registry)
    assert {:error, :provider_cleanup_failed} = RunBuilder.close(built)
    assert_receive :cleanup_attempted
    refute_receive :cleanup_attempted
  end

  test "provider cleanup accepts only explicit success and still attempts every resource" do
    parent = self()

    resources =
      [:error, false, nil, :unexpected]
      |> Enum.with_index()
      |> Enum.map(fn {result, index} ->
        fn ->
          send(parent, {:cleanup_attempted, index})
          result
        end
      end)

    session = ProviderSessionFixture.start(resources, limits())
    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)

    for index <- 0..3 do
      assert_receive {:cleanup_attempted, ^index}
    end
  end

  @tag :tmp_dir
  test "invalid split execution builds close every live resource and preserve cleanup failure", %{
    tmp_dir: _directory
  } do
    parent = self()

    invalid_builds = [
      fn config -> %{config: config} end,
      fn config ->
        %{entry_source: "(return 1)", config: config, publication_authority: :invalid}
      end
    ]

    for {invalid_build, index} <- Enum.with_index(invalid_builds) do
      {:ok, workflow} = WorkflowEnvironment.new([])
      {:ok, mission} = MissionEnvironment.new([])
      limits = limits()
      {:ok, sink} = EventSink.start(:normal, limits)

      {:ok, inspection} =
        InspectionSink.start(
          run_id: "invalid-built-#{index}",
          trace_id: "invalid-built-#{index}"
        )

      close = fn ->
        send(parent, {:invalid_built_resource_closed, index})
        {:error, :fixture_cleanup_failed}
      end

      session = ProviderSessionFixture.start([close], limits)

      {:ok, config} =
        RunConfig.new(
          workflow_environment: workflow,
          mission_environment: mission,
          input: %{},
          limits: limits,
          event_sink: sink,
          inspection_sink: inspection,
          provider_session: session
        )

      assert {:error, :invalid_execution_outcome} =
               config |> invalid_build.() |> RunBuilder.execute_built()

      assert {:error, :provider_cleanup_failed} = RunBuilder.close(config)

      assert_receive {:invalid_built_resource_closed, ^index}
      refute Process.alive?(session.pid)
      refute Process.alive?(sink.pid)
      refute Process.alive?(inspection.pid)
    end
  end

  test "a session terminated at its cleanup budget still loses its provider tasks" do
    # Terminating a wedged session skips `terminate/2`, so the session itself
    # can kill nothing. The external task owner it registered with observes the
    # death and kills the run's callbacks anyway.
    parent = self()
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 200)
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)
    root = start_scope_root(registrar, parent)
    assert :ok = ResourceRegistrar.commit(registrar, fn -> :ok end)

    {:ok, state} = RunState.start(limits, provider_session: session)

    assert :ok =
             ProviderSession.bind_lifecycle(session, self(), state.pid, state.provider_tracker)

    provider = start_provider_task(state, "wedged")
    provider_monitor = Process.monitor(provider)
    root_monitor = Process.monitor(root)
    session_monitor = Process.monitor(session.pid)
    assert Process.alive?(provider)

    assert :ok = :sys.suspend(session.pid)
    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)

    assert_receive {:DOWN, ^session_monitor, :process, _, :killed}
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :killed}
    assert_receive {:DOWN, ^root_monitor, :process, ^root, _reason}
    assert {:error, :closed} = RunState.attach_provider(state, spawn(fn -> :ok end))

    RunState.close(state)
    RunState.stop(state)
  end

  test "provider tasks are drained before the session runs a provider closer" do
    parent = self()
    limits = limits()
    {:ok, session} = ProviderSession.start(limits)
    {:ok, registrar} = ProviderSession.open_registrar(session)
    assert :ok = ResourceRegistrar.activate(registrar)

    {:ok, state} = RunState.start(limits, provider_session: session)

    assert :ok =
             ProviderSession.bind_lifecycle(session, self(), state.pid, state.provider_tracker)

    provider = start_provider_task(state, "drained")

    assert :ok =
             ResourceRegistrar.commit(registrar, fn ->
               # The closer observes the exact window a racing dispatch would
               # use: the session is still alive and the run is still open.
               send(parent, {:closed, Process.alive?(provider), late_attach(state)})
               :ok
             end)

    assert Process.alive?(provider)
    assert :ok = ProviderSession.close(session)

    # No callback from this run may still be live when a connector closes, and
    # the drain that proved it also seals the owner, so one that raced it is
    # refused rather than attached behind the closers.
    assert_receive {:closed, false, {{:error, :closed}, :killed}}
    refute Process.alive?(provider)

    RunState.close(state)
    RunState.stop(state)
  end

  test "successful Kernel cleanup terminates its provider session" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    limits = limits()
    {:ok, sink} = EventSink.start(:normal, limits)
    session = ProviderSessionFixture.start([fn -> :ok end], limits)
    session_monitor = Process.monitor(session.pid)

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink,
        provider_session: session
      )

    assert {:ok, _result} = PtcRunner.Kernel.run("(return 42)", config)
    assert_receive {:DOWN, ^session_monitor, :process, _, :normal}
    assert {:error, :provider_cleanup_failed} = ProviderSession.close(session)
    EventSink.stop(sink)
  end

  test "Kernel preflight failures close providers and cleanup failure takes precedence" do
    parent = self()
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(entry_source_bytes: 1)

    for {close_result, expected_kind} <- [
          {:ok, :configuration_error},
          {{:error, :fixture_cleanup_failed}, :provider_cleanup_error}
        ] do
      {:ok, sink} = EventSink.start(:normal, limits)

      close = fn ->
        send(parent, {:preflight_resource_closed, close_result})
        close_result
      end

      {:ok, config} =
        RunConfig.new(
          workflow_environment: workflow,
          mission_environment: mission,
          input: %{},
          limits: limits,
          event_sink: sink,
          provider_session: ProviderSessionFixture.start([close], limits)
        )

      assert {:error, %PtcRunner.Kernel.Error{kind: ^expected_kind}} =
               PtcRunner.Kernel.run("(return 1)", config)

      assert_receive {:preflight_resource_closed, ^close_result}
      refute_receive {:preflight_resource_closed, ^close_result}
      EventSink.stop(sink)
    end
  end

  test "cleanup failure takes precedence when the closer also stops terminal recording" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()

    {:ok, run_sink} = EventSink.start(:normal, limits)

    run_close = fn ->
      EventSink.stop(run_sink)
      {:error, :fixture_cleanup_failed}
    end

    {:ok, run_config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: run_sink,
        provider_session: ProviderSessionFixture.start([run_close], limits)
      )

    assert {:error,
            %PtcRunner.Kernel.Error{
              kind: :provider_cleanup_error,
              reason: :provider_cleanup_failed
            }} = PtcRunner.Kernel.run("(return 1)", run_config)

    {:ok, repl_sink} = EventSink.start(:normal, limits)

    repl_close = fn ->
      EventSink.stop(repl_sink)
      {:error, :fixture_cleanup_failed}
    end

    {:ok, repl_config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: repl_sink,
        provider_session: ProviderSessionFixture.start([repl_close], limits)
      )

    {:ok, repl} = ReplSession.new(config: repl_config)
    assert {:error, :provider_cleanup_failed} = ReplSession.close(repl)
  end

  test "an unavailable unclaimed event sink closes provider resources" do
    parent = self()
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits)

    close = fn ->
      send(parent, :unclaimed_sink_resource_closed)
      :ok
    end

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink,
        provider_session: ProviderSessionFixture.start([close], limits)
      )

    EventSink.stop(sink)

    assert {:error, %PtcRunner.Kernel.Error{kind: :event_sink_error}} =
             PtcRunner.Kernel.run("(return 1)", config)

    assert_receive :unclaimed_sink_resource_closed
    refute_receive :unclaimed_sink_resource_closed
  end

  test "an unavailable REPL sink closes provider resources and preserves cleanup precedence" do
    parent = self()
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()

    for {close_result, expected} <- [
          {:ok, {:error, :event_sink_error}},
          {{:error, :fixture_cleanup_failed}, {:error, :provider_cleanup_failed}}
        ] do
      {:ok, sink} = EventSink.start(:normal, limits)

      close = fn ->
        send(parent, {:unavailable_repl_resource_closed, close_result})
        close_result
      end

      {:ok, config} =
        RunConfig.new(
          workflow_environment: workflow,
          mission_environment: mission,
          input: %{},
          limits: limits,
          event_sink: sink,
          provider_session: ProviderSessionFixture.start([close], limits)
        )

      EventSink.stop(sink)

      assert ^expected = ReplSession.new(config: config)
      assert_receive {:unavailable_repl_resource_closed, ^close_result}
      refute_receive {:unavailable_repl_resource_closed, ^close_result}
    end
  end

  test "an owned REPL sink dying during setup still closes provider resources" do
    parent = self()
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits)

    close = fn ->
      send(parent, :racing_repl_resource_closed)
      :ok
    end

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink,
        provider_session: ProviderSessionFixture.start([close], limits)
      )

    :ok = :sys.suspend(sink.pid)
    sink_ref = Process.monitor(sink.pid)

    killer =
      spawn(fn ->
        receive do
          :kill -> Process.exit(sink.pid, :kill)
        end
      end)

    Process.send_after(killer, :kill, 1)

    assert {:error, :event_sink_error} = ReplSession.new(config: config)
    assert_receive {:DOWN, ^sink_ref, :process, _, :killed}
    assert_receive :racing_repl_resource_closed
    refute_receive :racing_repl_resource_closed
  end

  test "run shutdown kills and drains provider work before closing its resource" do
    parent = self()
    provider_table = :ets.new(:shutdown_provider, [:set, :public])

    callback = fn _arguments ->
      true = :ets.insert(provider_table, {:provider, self()})
      send(parent, {:provider_started, self()})

      receive do
        :never -> {:ok, %{}}
      end
    end

    {:ok, capability} =
      Capability.new(name: "slow", input_schema: @schema, callback: callback)

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, limits} = Limits.new(workflow_timeout_ms: 1_000, run_duration_ms: 2_000)

    {:ok, sink} = EventSink.start(:normal, limits)

    close = fn ->
      [{:provider, provider}] = :ets.lookup(provider_table, :provider)
      send(parent, {:resource_closed, Process.alive?(provider)})

      :ok
    end

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink,
        provider_session: ProviderSessionFixture.start([close], limits)
      )

    case PtcRunner.Kernel.run("(tool/slow {})", config) do
      {:error, %{reason: :timeout}} -> :ok
      {:ok, %{value: %{status: :error, kind: :timeout, reason: :provider_timeout}}} -> :ok
      other -> flunk("expected evaluator or provider timeout, got: #{inspect(other)}")
    end

    assert_receive {:resource_closed, false}
    EventSink.stop(sink)
  end

  test "runner death drains provider work before closing its resource" do
    parent = self()
    provider_table = :ets.new(:runner_death_provider, [:set, :public])

    callback = fn _arguments ->
      true = :ets.insert(provider_table, {:provider, self()})
      send(parent, {:runner_death_provider_started, self()})

      receive do
        :never -> {:ok, %{}}
      end
    end

    {:ok, capability} =
      Capability.new(name: "runner_death", input_schema: @schema, callback: callback)

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(workflow_timeout_ms: 30_000, run_duration_ms: 30_000)
    {:ok, sink} = EventSink.start(:normal, limits)

    close = fn ->
      [{:provider, provider}] = :ets.lookup(provider_table, :provider)
      send(parent, {:runner_death_resource_closed, Process.alive?(provider)})
      :ok
    end

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink,
        provider_session: ProviderSessionFixture.start([close], limits)
      )

    {runner, runner_ref} =
      spawn_monitor(fn -> PtcRunner.Kernel.run("(tool/runner_death {})", config) end)

    assert_receive {:runner_death_provider_started, provider}, 5_000
    Process.exit(runner, :kill)

    assert_receive {:DOWN, ^runner_ref, :process, ^runner, :killed}, 5_000
    assert_receive {:runner_death_resource_closed, false}, 5_000
    refute Process.alive?(provider)
    refute_receive {:runner_death_resource_closed, _alive?}
    EventSink.stop(sink)
  end

  test "runner still closes provider resources when run state dies" do
    parent = self()
    provider_table = :ets.new(:state_crash_provider, [:set, :public])

    callback = fn _arguments ->
      Process.flag(:trap_exit, true)
      true = :ets.insert(provider_table, {:provider, self()})
      send(parent, {:state_crash_provider_started, self()})

      receive do
        :never -> {:ok, %{}}
      end
    end

    {:ok, capability} =
      Capability.new(name: "state_crash", input_schema: @schema, callback: callback)

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(workflow_timeout_ms: 5_000, run_duration_ms: 10_000)
    {:ok, sink} = EventSink.start(:normal, limits)

    close = fn ->
      [{:provider, provider}] = :ets.lookup(provider_table, :provider)
      send(parent, {:state_crash_resource_closed, Process.alive?(provider)})
      :ok
    end

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink,
        provider_session: ProviderSessionFixture.start([close], limits)
      )

    {runner, runner_ref} =
      spawn_monitor(fn -> PtcRunner.Kernel.run("(tool/state_crash {})", config) end)

    assert_receive {:state_crash_provider_started, provider}, 5_000
    run_state = run_state_monitoring(runner)
    Process.exit(run_state, :kill)

    assert_receive {:state_crash_resource_closed, false}, 5_000
    refute Process.alive?(provider)
    assert_receive {:DOWN, ^runner_ref, :process, ^runner, _reason}, 5_000
    refute_receive {:state_crash_resource_closed, _alive?}
    EventSink.stop(sink)
  end

  test "REPL state-death races preserve provider cleanup failures" do
    parent = self()
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()

    for operation <- [:close, :abort] do
      {:ok, sink} = EventSink.start(:normal, limits)

      close = fn ->
        send(parent, {:state_race_cleanup_attempted, operation})
        {:error, :fixture_cleanup_failed}
      end

      {:ok, config} =
        RunConfig.new(
          workflow_environment: workflow,
          mission_environment: mission,
          input: %{},
          limits: limits,
          event_sink: sink,
          provider_session: ProviderSessionFixture.start([close], limits)
        )

      {:ok, repl} = ReplSession.new(config: config)
      [{_, {owner_pid, token}}] = :ets.lookup(repl.access, repl.id)
      assert {:ok, _config, run_state} = ReplSessionOwner.resources(owner_pid, token)
      :ok = :sys.suspend(run_state.pid)

      killer =
        spawn(fn ->
          receive do
            :kill -> Process.exit(run_state.pid, :kill)
          end
        end)

      Process.send_after(killer, :kill, 1)

      result =
        case operation do
          :close -> ReplSession.close(repl)
          :abort -> ReplSession.abort(repl, :frontend_exit)
        end

      assert {:error, :provider_cleanup_failed} = result
      assert_receive {:state_race_cleanup_attempted, ^operation}
      refute_receive {:state_race_cleanup_attempted, ^operation}
    end
  end

  test "REPL cleanup stops at the provider cleanup deadline" do
    parent = self()
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    # The deadline itself is what this asserts, so narrow it rather than
    # waiting out the 5 s default.
    {:ok, limits} = Limits.new(provider_cleanup_timeout_ms: 200)
    {:ok, sink} = EventSink.start(:normal, limits)

    close = fn ->
      send(parent, :delayed_cleanup_started)

      receive do
        :never -> :ok
      end
    end

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink,
        provider_session: ProviderSessionFixture.start([close], limits)
      )

    {:ok, repl} = ReplSession.new(config: config)
    assert {:error, :provider_cleanup_failed, _events} = ReplSession.close(repl)
    assert_receive :delayed_cleanup_started
  end

  test "default sink shutdown is finite and kills suspended sinks" do
    # Two separate guarantees. That the shipped default is a finite bound is a
    # property of the constant, so assert it directly instead of sleeping
    # through it; the kill behaviour it protects is then exercised against a
    # narrow deadline.
    assert is_integer(EventSink.stop_timeout_ms())
    assert is_integer(InspectionSink.stop_timeout_ms())

    {:ok, event_sink} = EventSink.start(:normal, limits())

    {:ok, inspection_sink} =
      InspectionSink.start(run_id: "finite-stop", trace_id: "finite-stop")

    true = :erlang.suspend_process(event_sink.pid)
    true = :erlang.suspend_process(inspection_sink.pid)
    event_ref = Process.monitor(event_sink.pid)
    inspection_ref = Process.monitor(inspection_sink.pid)

    event_stop = Task.async(fn -> EventSink.stop(event_sink, 200) end)
    inspection_stop = Task.async(fn -> InspectionSink.stop(inspection_sink, 200) end)

    assert :ok = Task.await(event_stop, 10_000)
    assert :ok = Task.await(inspection_stop, 10_000)
    assert_receive {:DOWN, ^event_ref, :process, _, :killed}
    assert_receive {:DOWN, ^inspection_ref, :process, _, :killed}
  end

  defp registry_with_close(parent) do
    builder = fn %{"id" => id}, _context ->
      {:ok, capability} = capability("provided.#{id}")

      {:ok,
       %{
         capabilities: [capability],
         snapshot: %{"provider" => id},
         close: fn ->
           send(parent, {:closed, id})
           :ok
         end
       }}
    end

    ProviderRegistry.new(%{"owned" => builder})
  end

  defp capability(name) do
    Capability.new(name: name, input_schema: @schema, callback: fn _arguments -> {:ok, %{}} end)
  end

  defp start_scope_root(registrar, parent) do
    root =
      spawn(fn ->
        owner = ResourceRegistrar.owner(registrar)
        owner_monitor = Process.monitor(owner)
        :ok = ResourceRegistrar.register_root(registrar)
        send(parent, {:scope_root_ready, self()})

        receive do
          {:DOWN, ^owner_monitor, :process, ^owner, _reason} -> :ok
        end
      end)

    assert_receive {:scope_root_ready, ^root}
    root
  end

  # Attaches from a separate process, since one process holds one reservation.
  # A task the sealed owner accepted is killed here so the assertion reports the
  # accepted attachment instead of timing out on a live one.
  defp late_attach(state) do
    Task.async(fn ->
      task = spawn(fn -> receive do: (:stop -> :ok) end)
      monitor = Process.monitor(task)
      :ok = RunState.reserve_capability(state, :workflow, "late")
      attached = RunState.attach_provider(state, task)
      if attached == :ok, do: Process.exit(task, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^task, reason} -> {attached, reason}
      end
    end)
    |> Task.await()
  end

  defp start_provider_task(state, name) do
    provider = spawn(fn -> receive do: (:stop -> :ok) end)
    assert :ok = RunState.reserve_capability(state, :workflow, name)
    assert :ok = RunState.attach_provider(state, provider)
    provider
  end

  defp limits do
    {:ok, limits} = Limits.new()
    limits
  end

  defp run_state_monitoring(runner) do
    {:monitored_by, monitors} = Process.info(runner, :monitored_by)

    Enum.find(monitors, fn
      pid when pid == self() ->
        false

      pid ->
        try do
          case :sys.get_state(pid, 100) do
            %{owner: ^runner, reservations: reservations} -> is_map(reservations)
            _state -> false
          end
        catch
          :exit, _reason -> false
        end
    end) || flunk("runner RunState monitor was not found")
  end

  defp provider(name, config), do: %{"name" => name, "config" => config}

  defp manifest(dir, workflow_providers, mission_providers) do
    path = Path.join(dir, "#{System.unique_integer([:positive])}.json")

    body = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{"workflow" => workflow_providers, "mission" => mission_providers}
    }

    File.write!(path, Jason.encode!(body))
    path
  end
end
