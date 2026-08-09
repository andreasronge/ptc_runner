defmodule PtcRunner.Kernel.ReplTraceLifecycleTest do
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]

  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.ReplSessionOwner

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
