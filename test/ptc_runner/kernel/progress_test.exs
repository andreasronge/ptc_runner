defmodule PtcRunner.Kernel.ProgressTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.Progress
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment

  test "concurrent runs keep identity and deliver completion after trace finalization" do
    parent = self()

    tasks =
      for id <- ["progress-first", "progress-second"] do
        Task.async(fn -> run_waiting(id, parent) end)
      end

    assert_receive {:ready, "progress-first", first}, 2_000
    assert_receive {:ready, "progress-second", second}, 2_000

    assert_receive {:frame, "progress-first", "progress-first",
                    %{phase: "running", seq: first_seq}, []}

    assert_receive {:frame, "progress-second", "progress-second",
                    %{phase: "running", seq: second_seq}, []}

    send(first, :release)
    send(second, :release)
    for task <- tasks, do: assert({:ok, %{value: 42}} = Task.await(task))

    for id <- ["progress-first", "progress-second"] do
      running_seq = if id == "progress-first", do: first_seq, else: second_seq
      {trace, {:ok, %{ready?: false}}} = await_terminal(id, running_seq)
      assert List.last(trace).type == "run-stopped"
      refute_receive {:frame, ^id, ^id, %{phase: "running"}, _}
    end
  end

  test "dead and crashing sinks cannot fail a run" do
    {dead, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^dead, :normal}

    for sink <- [
          fn _, _ -> raise "sink failed" end,
          fn _, _ -> Process.exit(self(), :kill) end,
          fn _, _ -> GenServer.call(dead, :frame) end
        ] do
      {config, _events} = new_config(progress_sink: sink)

      assert {:ok, %{value: 42}} = Kernel.run("(return 42)", config)
    end
  end

  test "subordinate activity aggregates into the parent identity" do
    parent = self()
    {:ok, mission} = MissionEnvironment.new([])
    sink = fn run_id, frame -> send(parent, {:parent_frame, run_id, frame}) end

    {config, _events} =
      new_config(
        run_id: "parent-progress",
        missions: %{"default" => mission},
        progress_sink: sink
      )

    assert {:ok, _} =
             Kernel.run(
               ~S|(return (tool/kernel-eval {:mission "default" :kind :source :source "(return 42)"}))|,
               config
             )

    assert_receive {:parent_frame, "parent-progress",
                    %{phase: "ok", usage: %{subordinate_evaluations: 1}, activity: activity}}

    assert Enum.count(activity, &(&1.kind == "evaluation")) >= 4
  end

  test "instrumentation storage stays bounded when producers outrun delivery" do
    {config, _events} = new_config()

    {:ok, run_state} = RunState.start(config.limits)
    {:ok, port} = Progress.start(fn _, _ -> :ok end, config, run_state)
    table = :sys.get_state(port).observations

    for n <- 1..10_000 do
      Progress.handle_telemetry(
        [:ptc_runner, :capability, :start],
        %{},
        %{live_run: run_state.pid, name: "call-#{n}"},
        {port, run_state.pid, table}
      )
    end

    assert :ets.info(table, :size) <= 129
    assert :ok = Progress.complete(port, :ok, nil, nil)
    RunState.stop(run_state)
  end

  defp await_terminal(id, previous_seq) do
    receive do
      {:frame, ^id, ^id, %{phase: "running", seq: seq}, []} ->
        assert seq > previous_seq
        await_terminal(id, seq)

      {:frame, ^id, ^id, %{phase: "ok", seq: seq, run_id: ^id}, trace} ->
        assert seq > previous_seq
        trace
    after
      2_000 -> flunk("terminal progress was not delivered")
    end
  end

  defp run_waiting(id, parent) do
    {:ok, capability} =
      Capability.new(
        name: "wait",
        input_schema: %{"type" => "object"},
        callback: fn _ ->
          send(parent, {:ready, id, self()})
          receive do: (:release -> {:ok, 42})
        end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [capability])
    {config, events} = new_config(workflow: workflow, run_id: id)

    sink = fn run_id, frame ->
      trace =
        if frame.phase != "running",
          do: {EventSink.events(events), EventSink.session_contract(events)},
          else: []

      send(parent, {:frame, id, run_id, frame, trace})
    end

    Kernel.run(~S|(return (get (tool/wait {}) "value"))|, %{config | progress_sink: sink})
  end

  defp new_config(opts \\ []) do
    {:ok, empty_workflow} = WorkflowEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, events} = EventSink.start(:normal, limits, Keyword.take(opts, [:run_id]))

    {:ok, config} =
      RunConfig.new(
        workflow_environment: Keyword.get(opts, :workflow, empty_workflow),
        missions: Keyword.get(opts, :missions, %{}),
        input: %{},
        limits: limits,
        event_sink: events,
        progress_sink: Keyword.get(opts, :progress_sink)
      )

    {config, events}
  end
end
