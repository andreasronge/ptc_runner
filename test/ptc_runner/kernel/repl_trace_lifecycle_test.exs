defmodule PtcRunner.Kernel.ReplTraceLifecycleTest do
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.ReplSessionOwner
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment

  @tag :tmp_dir
  test "a relative trace remains bound to the invocation directory", %{tmp_dir: directory} do
    invocation = Path.join(directory, "invocation")
    later = Path.join(directory, "later")
    File.mkdir!(invocation)
    File.mkdir!(later)

    session =
      File.cd!(invocation, fn ->
        assert {:ok, session} = ReplSession.new(trace_path: "session.jsonl")
        session
      end)

    File.cd!(later, fn ->
      assert {:ok, _events} = ReplSession.close(session)
    end)

    assert File.regular?(Path.join(invocation, "session.jsonl"))
    refute File.exists?(Path.join(later, "session.jsonl"))
  end

  @tag :tmp_dir
  test "direct caller death finalizes and persists the abandoned session", %{tmp_dir: directory} do
    trace_path = Path.join(directory, "caller-death.jsonl")
    parent = self()

    {caller, caller_ref} =
      spawn_monitor(fn ->
        {:ok, session} = ReplSession.new(trace_path: trace_path)
        [{_, {owner, _token}}] = :ets.lookup(session.access, session.id)
        send(parent, {:direct_repl_opened, owner})

        receive do
          :close -> :ok
        end
      end)

    assert_receive {:direct_repl_opened, owner}, 5_000
    owner_ref = Process.monitor(owner)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 5_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 5_000
    assert_eventually(fn -> File.exists?(trace_path) end)
    assert File.read!(trace_path) =~ "session_owner_failed"
  end

  @tag :tmp_dir
  test "abandoned sessions settle outstanding LLM reservations before persistence", %{
    tmp_dir: directory
  } do
    trace_path = Path.join(directory, "caller-death-budget.jsonl")
    parent = self()

    {caller, caller_ref} =
      spawn_monitor(fn ->
        {owner, holder} = start_budgeted_owner(trace_path, parent)

        send(parent, {:abandoned_repl_opened, owner, holder})

        receive do
          :close -> :ok
        end
      end)

    assert_receive {:abandoned_repl_opened, owner, holder}, 5_000
    assert_receive {:abandoned_budget_ready, ^holder}, 5_000
    owner_ref = Process.monitor(owner)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 5_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 5_000
    assert_eventually(fn -> File.exists?(trace_path) end)
    assert_settled_budget_trace(trace_path)
    send(holder, :done)
  end

  @tag :tmp_dir
  test "opening-process death settles LLM reservations before freezing its trace", %{
    tmp_dir: directory
  } do
    trace_path = Path.join(directory, "opening-death-budget.jsonl")
    parent = self()

    {creator, creator_ref} =
      spawn_monitor(fn ->
        {owner, holder} = start_budgeted_owner(trace_path, parent)
        opening_ref = make_ref()

        :sys.replace_state(owner, fn state -> %{state | opening_ref: opening_ref} end)
        send(parent, {:opening_budget_ready, owner, holder, opening_ref})

        receive do
          :close -> :ok
        end
      end)

    assert_receive {:abandoned_budget_ready, holder}, 5_000
    assert_receive {:opening_budget_ready, owner, ^holder, opening_ref}, 5_000
    owner_ref = Process.monitor(owner)
    send(owner, {:DOWN, opening_ref, :process, self(), :killed})
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 5_000
    assert_eventually(fn -> File.exists?(trace_path) end)
    assert_settled_budget_trace(trace_path)

    send(holder, :done)
    send(creator, :close)
    assert_receive {:DOWN, ^creator_ref, :process, ^creator, :normal}, 5_000
  end

  defp start_budgeted_owner(trace_path, parent) do
    {:ok, owner, token} = ReplSessionOwner.start_pending(self())
    {:ok, limits} = Limits.new(llm_total_tokens: 100)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "abandoned-budget")
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    :ok = EventSink.claim(sink, config.claim_id, config.run_started_metadata)
    {:ok, state} = RunState.start_repl(limits, sink, nil, owner: owner)
    :ok = EventSink.transfer_owner(sink, owner)
    config = %{config | event_sink_owner: owner}
    :ok = ReplSessionOwner.adopt_direct(owner, token, config, state, trace_path)

    holder =
      spawn(fn ->
        route = %{
          route_key: "primary",
          max_calls: 16,
          source: "llm",
          output_tokens: 20,
          total_tokens: 40,
          cost_microusd: nil
        }

        {:ok, _reservation_id} =
          RunState.reserve_capability(state, :workflow, "llm-request", nil, route)

        send(parent, {:abandoned_budget_ready, self()})
        receive do: (:done -> :ok)
      end)

    {owner, holder}
  end

  defp assert_settled_budget_trace(trace_path) do
    events =
      trace_path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    stopped = Enum.find(events, &(&1["type"] == "run-stopped"))
    assert is_map(stopped)

    assert %{
             "state" => "available",
             "reserved" => 0,
             "charged" => 0,
             "remaining" => 100
           } = get_in(stopped, ["data", "usage", "llm_budget", "total_tokens"])
  end

  @tag :tmp_dir
  test "trace persistence failure returns the frozen terminal events", %{tmp_dir: directory} do
    trace_parent = Path.join(directory, "trace-parent")
    trace_path = Path.join(trace_parent, "session.jsonl")
    File.mkdir!(trace_parent)

    assert {:ok, session} = ReplSession.new(trace_path: trace_path)
    File.rmdir!(trace_parent)

    assert {:error, :trace_persistence_failed, events} = ReplSession.close(session)
    assert List.last(events).type == "run-stopped"
  end

  @tag :tmp_dir
  test "abort trace persistence failure returns the frozen terminal events", %{tmp_dir: directory} do
    trace_parent = Path.join(directory, "abort-trace-parent")
    trace_path = Path.join(trace_parent, "session.jsonl")
    File.mkdir!(trace_parent)

    assert {:ok, session} = ReplSession.new(trace_path: trace_path)
    File.rmdir!(trace_parent)

    assert {:error, :trace_persistence_failed, events} =
             ReplSession.abort(session, :frontend_exception)

    assert List.last(events).type == "run-stopped"
  end

  test "a pending owner exits normally when its caller dies before adoption" do
    parent = self()

    {caller, caller_ref} =
      spawn_monitor(fn ->
        {:ok, pending, _token} = ReplSessionOwner.start_pending(self())
        send(parent, {:pending_owner_started, pending})

        receive do
          :close -> :ok
        end
      end)

    assert_receive {:pending_owner_started, pending}, 5_000
    pending_ref = Process.monitor(pending)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 5_000
    assert_receive {:DOWN, ^pending_ref, :process, ^pending, :normal}, 5_000
  end
end
