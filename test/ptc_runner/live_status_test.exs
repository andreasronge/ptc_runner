defmodule PtcRunner.LiveStatusTest do
  # async: false — mutates the PTC_VIEWER_URL environment variable.
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.LLMRouter
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.LiveStatus.Reporter
  alias PtcRunner.LiveStatus.Target

  @moduletag :capture_log

  test "telemetry delivery is isolated to its correlated run" do
    run_ref = self()
    other_run_ref = spawn(fn -> :ok end)
    handler_config = {self(), run_ref}

    assert :ok =
             Reporter.handle_telemetry(
               [:ptc_runner, :capability, :start],
               %{},
               %{live_run: other_run_ref},
               handler_config
             )

    refute_receive {:live_telemetry, _, _, _}

    assert :ok =
             Reporter.handle_telemetry(
               [:ptc_runner, :capability, :start],
               %{},
               %{live_run: run_ref},
               handler_config
             )

    assert_receive {:live_telemetry, [:ptc_runner, :capability, :start], %{}, %{}}
  end

  test "the reporter stops when the run owner dies" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, limits} = Limits.new()
        {:ok, sink} = EventSink.start(:normal, limits, run_id: "owner-bound-live-status")
        {:ok, config} = run_config(limits, sink, %{})
        {:ok, run_state} = RunState.start(limits)
        {:ok, target} = Target.new(fn _run_id, _frame -> :ok end)
        {:ok, reporter} = Reporter.start(target, config, run_state)
        send(parent, {:reporter, reporter})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:reporter, reporter}
    reporter_ref = Process.monitor(reporter)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^reporter_ref, :process, ^reporter, _reason}, 2_000
  end

  test "a blocked target cannot delay run completion and its worker is terminated" do
    test_process = self()

    {:ok, target} =
      Target.new(fn _run_id, frame ->
        send(test_process, {:blocked_delivery, self(), frame.phase})

        receive do
          :never -> :ok
        end
      end)

    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "blocked-live-target")
    {:ok, config} = run_config(limits, sink, %{})
    {:ok, run_state} = RunState.start(limits)
    {:ok, reporter} = Reporter.start(target, config, run_state)

    assert_receive {:blocked_delivery, delivery, "running"}, 1_000
    delivery_ref = Process.monitor(delivery)

    started = System.monotonic_time(:millisecond)
    assert :ok = Reporter.complete(reporter, :ok, nil, nil)
    assert System.monotonic_time(:millisecond) - started < 500
    assert :ok = Reporter.stop(reporter)

    assert_receive {:DOWN, ^delivery_ref, :process, ^delivery, :killed}, 2_000
    reporter_ref = Process.monitor(reporter)
    assert_receive {:DOWN, ^reporter_ref, :process, ^reporter, :normal}, 2_000
    assert :ok = RunState.stop(run_state)
  end

  test "an exiting execution owner does not cancel its terminal frame" do
    test_process = self()

    {:ok, target} =
      Target.new(fn _run_id, frame ->
        send(test_process, {:owner_delivery, self(), frame.phase})

        if frame.phase != "running" do
          receive do
            :release_terminal -> send(test_process, {:terminal_delivered, frame.phase})
          end
        end

        :ok
      end)

    owner =
      spawn(fn ->
        {:ok, limits} = Limits.new()
        {:ok, sink} = EventSink.start(:normal, limits, run_id: "owner-terminal-frame")
        {:ok, config} = run_config(limits, sink, %{})
        {:ok, run_state} = RunState.start(limits)
        {:ok, reporter} = Reporter.start(target, config, run_state)
        send(test_process, {:owner_reporter, reporter, run_state})

        receive do
          :complete -> Reporter.complete(reporter, :ok, nil, nil)
        end
      end)

    owner_ref = Process.monitor(owner)
    assert_receive {:owner_reporter, reporter, run_state}
    assert_receive {:owner_delivery, _running_delivery, "running"}
    send(owner, :complete)

    assert_receive {:owner_delivery, terminal_delivery, "ok"}
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert Process.alive?(reporter)

    reporter_ref = Process.monitor(reporter)
    send(terminal_delivery, :release_terminal)
    assert_receive {:terminal_delivered, "ok"}
    assert_receive {:DOWN, ^reporter_ref, :process, ^reporter, :normal}
    refute Process.alive?(run_state.pid)
  end

  test "OTP status redacts private input and the HTTP bearer token" do
    token = "PRIVATE_VIEWER_BEARER_TOKEN_1234567890"
    previous = System.get_env("PTC_VIEWER_TOKEN")
    System.put_env("PTC_VIEWER_TOKEN", token)

    on_exit(fn ->
      if previous,
        do: System.put_env("PTC_VIEWER_TOKEN", previous),
        else: System.delete_env("PTC_VIEWER_TOKEN")
    end)

    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "private-status")
    {:ok, config} = run_config(limits, sink, %{"secret" => "PRIVATE_LIVE_INPUT_MARKER"})
    {:ok, run_state} = RunState.start(limits)
    {:ok, reporter} = Reporter.start("http://127.0.0.1:1", config, run_state)

    status = inspect(:sys.get_status(reporter), limit: :infinity, printable_limit: :infinity)
    refute status =~ "PRIVATE_LIVE_INPUT_MARKER"
    refute status =~ token

    assert :ok = Reporter.stop(reporter)
    assert :ok = RunState.stop(run_state)
  end

  test "the HTTP reporter percent-encodes the complete run id as one path segment" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
        send(parent, {:http_request, request})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        :ok = :gen_tcp.close(socket)
      end)

    server_ref = Process.monitor(server)

    run_id = "run /?# café"
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)
    {:ok, config} = run_config(limits, sink, %{})
    {:ok, run_state} = RunState.start(limits)
    {:ok, reporter} = Reporter.start("http://127.0.0.1:#{port}", config, run_state)

    assert_receive {:http_request, request}, 2_000
    assert request =~ "POST /api/live/runs/run%20%2F%3F%23%20caf%C3%A9 HTTP/1.1"

    assert :ok = Reporter.stop(reporter)
    assert :ok = RunState.stop(run_state)
    :ok = :gen_tcp.close(listener)
    assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}
  end

  test "the terminal frame keeps spend recorded before capability telemetry" do
    parent = self()
    {:ok, target} = Target.new(fn _run_id, frame -> send(parent, {:live_frame, frame}) end)
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "live-spend-before-telemetry")
    {:ok, config} = run_config(limits, sink, %{})
    {:ok, run_state} = RunState.start(limits)
    {:ok, reporter} = Reporter.start(target, config, run_state)

    assert_receive {:live_frame, %{phase: "running"}}, 1_000

    assert :ok =
             RunState.record_llm_usage(run_state, "writer", "stable-v1", :ok, %{
               "input" => 3,
               "output" => 2,
               "total_cost" => 0.25
             })

    gate = make_ref()

    late =
      Task.async(fn ->
        receive do
          ^gate -> :ok
        after
          2_000 -> flunk("late telemetry was never released")
        end

        Reporter.handle_telemetry(
          [:ptc_runner, :capability, :stop],
          %{duration_ms: 12},
          %{
            name: "llm-request",
            environment: :workflow,
            capability_id: "cap-late",
            status: :ok,
            live_run: run_state.pid
          },
          {reporter, run_state.pid}
        )
      end)

    assert :ok = Reporter.complete(reporter, :ok, nil, nil)
    assert_receive {:live_frame, %{phase: "ok"} = frame}, 2_000

    assert frame.usage.llm_spend == %{
             "state" => "available",
             "input" => 3,
             "output" => 2,
             "total_cost" => %{"currency" => "USD", "microunits" => 250_000}
           }

    send(late.pid, gate)
    _ = Task.await(late)
    assert :ok = Reporter.stop(reporter)
    assert :ok = RunState.stop(run_state)
  end

  test "capability-stop telemetry does not own the live spend total" do
    parent = self()
    {:ok, target} = Target.new(fn _run_id, frame -> send(parent, {:live_frame, frame}) end)
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "live-spend-telemetry-does-not-own")
    {:ok, config} = run_config(limits, sink, %{})
    {:ok, run_state} = RunState.start(limits)
    {:ok, reporter} = Reporter.start(target, config, run_state)

    assert_receive {:live_frame, %{phase: "running"}}, 1_000

    assert :ok =
             Reporter.handle_telemetry(
               [:ptc_runner, :capability, :stop],
               %{duration_ms: 12},
               %{
                 name: "llm-request",
                 environment: :workflow,
                 capability_id: "cap-unowned",
                 status: :ok,
                 live_run: run_state.pid
               },
               {reporter, run_state.pid}
             )

    assert :ok = Reporter.complete(reporter, :ok, nil, nil)
    assert_receive {:live_frame, %{phase: "ok"} = frame}, 2_000
    assert frame.usage.llm_spend == %{"state" => "empty"}

    assert :ok = Reporter.stop(reporter)
    assert :ok = RunState.stop(run_state)
  end

  test "a priced LLM call reaches the terminal live frame as available spend" do
    parent = self()
    {:ok, target} = Target.new(fn _run_id, frame -> send(parent, {:live_frame, frame}) end)

    {:ok, leaf} =
      LLMCapability.new(
        requester: fn _request ->
          {:ok, %{content: "ok", tokens: %{input: 3, output: 2, total_cost: 0.25}}}
        end
      )

    {:ok, router} =
      LLMRouter.new([
        %{
          alias: "writer",
          source: "llm",
          installation_revision: "stable-v1",
          default?: true,
          capability: leaf,
          max_calls: nil,
          output_tokens: 4_096,
          reservation_bound: fn _request, _tariff ->
            {:ok, %{total_tokens: 4_096, cost: nil}}
          end
        }
      ])

    {:ok, components} = Library.resolve_components([{:library, "llm"}, {:library, "cap"}])
    {:ok, bundle} = Kernel.compile_bundle(components)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [router])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "live-spend-priced-llm")
    {:ok, config} = run_config(limits, sink, %{}, workflow, mission)

    assert {:ok, _} =
             PtcRunner.LiveStatus.with_target(target, fn ->
               Kernel.run(~S|(return (llm/request {"messages" []}))|, config)
             end)

    assert_receive {:live_frame, %{phase: "ok"} = frame}, 2_000

    assert frame.usage.llm_spend == %{
             "state" => "available",
             "input" => 3,
             "output" => 2,
             "total_cost" => %{"currency" => "USD", "microunits" => 250_000}
           }
  end

  test "live timeout formatting names the run-duration limit" do
    assert {:ok,
            "run_duration_ms limit 200 ms was exceeded during execution; raise limits.run_duration_ms in the manifest, and the installed host ceiling if it is lower"} =
             RuntimeLimitDiagnostic.live_timeout_message(
               :run_duration_ms,
               200,
               :execution
             )
  end

  test "a run succeeds unchanged when the configured viewer is unreachable" do
    # Grab a port that is guaranteed closed by binding and releasing it.
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    System.put_env("PTC_VIEWER_URL", "http://127.0.0.1:#{port}")
    on_exit(fn -> System.delete_env("PTC_VIEWER_URL") end)

    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "live-status-dead-viewer")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: 42}} = Kernel.run("(return 42)", config)
  end

  test "the terminal frame names the timeout limit that actually fired" do
    parent = self()
    {:ok, target} = Target.new(fn _run_id, frame -> send(parent, {:live_frame, frame}) end)
    park = park_capability()
    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [park])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, limits} =
      Limits.new(
        run_duration_ms: 10_000,
        workflow_timeout_ms: 5_000,
        parallel_timeout_ms: 200
      )

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "live-parallel-timeout")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:error, %{kind: :limit_exceeded}} =
             PtcRunner.LiveStatus.with_target(target, fn ->
               Kernel.run(~S[(return (pcalls #(tool/park {})))], config)
             end)

    assert_receive {:live_frame,
                    %{
                      phase: "error",
                      outcome_reason:
                        "parallel_timeout_ms limit 200 ms was exceeded during execution; raise limits.parallel_timeout_ms in the manifest, and the installed host ceiling if it is lower"
                    }},
                   2_000
  end

  # The card used to show a bare `runtime_limit_exceeded` for every ceiling that
  # is not a timeout, and the browser decided "is this a limit?" from a
  # three-name prefix list. The frame now names the setting itself.
  test "a breached agent turn limit reaches the card as a named limit" do
    parent = self()
    {:ok, target} = Target.new(fn _run_id, frame -> send(parent, {:live_frame, frame}) end)
    # A program that defines something and never returns keeps the loop working,
    # so a one-turn budget ends on the turn limit rather than on a result.
    working = %{
      content: nil,
      tool_calls: [
        %{id: "call-1", name: "run_ptc_lisp", args: %{"program" => "(def pending 1)"}}
      ]
    }

    {:ok, llm} = LLMCapability.new(requester: fn _request -> {:ok, working} end)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: agent_bundle(), capabilities: [llm])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "live-agent-turn-limit")
    {:ok, config} = run_config(limits, sink, %{}, workflow, mission)

    assert {:error, _error} =
             PtcRunner.LiveStatus.with_target(target, fn ->
               Kernel.run(~S|(agent.core/run "Work" {"max_turns" 1})|, config)
             end)

    assert_receive {:live_frame, %{phase: "error", outcome_limit: "max_turns"} = frame}, 5_000

    assert frame.outcome_reason =~ "agent turn limit 1 was exceeded"
    assert RuntimeLimitDiagnostic.agent_turns_message?(frame.outcome_reason)
  end

  test "a workflow heap kill reaches the card as a named limit" do
    parent = self()
    {:ok, target} = Target.new(fn _run_id, frame -> send(parent, {:live_frame, frame}) end)
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(workflow_heap_words: 400_000)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "live-heap-kill")
    {:ok, config} = run_config(limits, sink, %{}, workflow, mission)

    assert {:error, %{kind: :limit_exceeded, reason: :memory_exceeded}} =
             PtcRunner.LiveStatus.with_target(target, fn ->
               Kernel.run(~S[(return (count (vec (range 2000000))))], config)
             end)

    assert_receive {:live_frame, %{phase: "error", outcome_limit: "workflow_heap_words"} = frame},
                   5_000

    assert {:ok, expected} = RuntimeLimitDiagnostic.heap_words_message(400_000)
    assert frame.outcome_reason == expected
  end

  test "an evaluator failure reaches the card with typed last_evaluation_error" do
    parent = self()
    {:ok, target} = Target.new(fn _run_id, frame -> send(parent, {:live_frame, frame}) end)
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "live-eval-div-zero")
    {:ok, config} = run_config(limits, sink, %{}, workflow, mission)

    assert {:error, %{kind: :evaluation_failed, reason: :arithmetic_error}} =
             PtcRunner.LiveStatus.with_target(target, fn ->
               Kernel.run(~S[(return (/ 1 0))], config)
             end)

    assert_receive {:live_frame,
                    %{
                      phase: "error",
                      last_evaluation_error: %{
                        "kind" => "arithmetic_error",
                        "message" => "division by zero"
                      }
                    }},
                   2_000
  end

  test "a private evaluator failure keeps last_evaluation_error null on the live frame" do
    parent = self()
    {:ok, target} = Target.new(fn _run_id, frame -> send(parent, {:live_frame, frame}) end)
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:private, limits, run_id: "live-eval-private")
    {:ok, config} = run_config(limits, sink, %{}, workflow, mission)

    assert {:error, %{kind: :workflow_failed, details: %{message: "private workflow failed"}}} =
             PtcRunner.LiveStatus.with_target(target, fn ->
               Kernel.run(~S[(return (/ 1 0))], config)
             end)

    assert_receive {:live_frame, %{phase: "error", last_evaluation_error: nil} = frame}, 2_000
    assert frame.outcome_reason == "private workflow failed"
    refute inspect(frame) =~ "arithmetic_error"
    refute inspect(frame) =~ "division by zero"
  end

  test "a real run deadline reports the configured run-duration ceiling" do
    parent = self()
    {:ok, target} = Target.new(fn _run_id, frame -> send(parent, {:live_frame, frame}) end)
    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [park_capability(parent)])
    {:ok, mission} = MissionEnvironment.new([])

    # 200 ms used to be eaten by Kernel.run setup under a loaded 4-scheduler
    # suite, so pcalls returned a recoverable provider_timeout instead of the
    # run-duration abort. Stay well below the 5 s parallel/workflow ceilings.
    {:ok, limits} =
      Limits.new(
        run_duration_ms: 2_000,
        workflow_timeout_ms: 5_000,
        parallel_timeout_ms: 5_000
      )

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "live-run-duration-timeout")
    {:ok, config} = run_config(limits, sink, %{}, workflow, mission)

    run =
      Task.async(fn ->
        PtcRunner.LiveStatus.with_target(target, fn ->
          Kernel.run(~S[(return (pcalls #(tool/park {})))], config)
        end)
      end)

    assert_receive {:parked, _callback}

    assert {:error, %{kind: :limit_exceeded, details: details}} = Task.await(run, 5_000)

    assert details.limit == :run_duration_ms
    assert details.limit_ms == 2_000

    assert_receive {:live_frame,
                    %{
                      phase: "error",
                      outcome_reason:
                        "run_duration_ms limit 2000 ms was exceeded during execution; raise limits.run_duration_ms in the manifest, and the installed host ceiling if it is lower"
                    }},
                   2_000
  end

  defp run_config(limits, sink, input) do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    run_config(limits, sink, input, workflow, mission)
  end

  defp run_config(limits, sink, input, workflow, mission) do
    RunConfig.new(
      workflow_environment: workflow,
      missions: %{"default" => mission},
      input: input,
      limits: limits,
      event_sink: sink
    )
  end

  # `kernel-runtime-limit-failure` is granted only to a bundle that ships
  # `agent.core`, so the smallest way to reach the turn-limit shape is to ship it.
  defp agent_bundle do
    {:ok, components} =
      Library.components(~w(agent.core agent.feedback agent.native agent.prompt agent.retry
           kernel llm result workflow.event))

    {:ok, bundle} = Kernel.compile_bundle(components)
    bundle
  end

  defp park_capability(notify \\ nil) do
    {:ok, capability} =
      Capability.new(
        name: "park",
        description: "Park until the parallel operation times out.",
        input_schema: %{"type" => "object"},
        callback: fn _arguments ->
          if is_pid(notify), do: send(notify, {:parked, self()})

          receive do
            :never -> {:ok, %{}}
          after
            10_000 -> {:ok, %{}}
          end
        end
      )

    capability
  end
end
