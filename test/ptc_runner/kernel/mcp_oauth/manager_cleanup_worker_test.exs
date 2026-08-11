defmodule PtcRunner.Kernel.MCPOAuth.ManagerCleanupWorkerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPOAuth.ManagerCleanupWorker
  alias PtcRunner.Kernel.MCPOAuth.TokenManager

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "repeated timeouts exhaust the cleanup slot budget and reclaim the manager" do
    manager = manager_replying(fn _attempt -> {:error, :timeout} end)
    manager_ref = Process.monitor(manager.pid)

    {:ok, worker} =
      ManagerCleanupWorker.start_link(manager, timeout_deadline_ms: 500)

    worker_ref = Process.monitor(worker)

    assert_receive {:close_attempt, 1}
    assert_receive {:close_attempt, 2}, 1_000

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :cleanup_timeout_exhausted},
                   1_000

    assert_receive {:DOWN, ^manager_ref, :process, _pid, :cleanup_timeout_exhausted},
                   1_000
  end

  test "a non-answering close cannot overrun the cleanup slot budget" do
    manager = non_answering_manager()
    manager_ref = Process.monitor(manager.pid)

    {:ok, worker} =
      ManagerCleanupWorker.start_link(manager, timeout_deadline_ms: 50)

    worker_ref = Process.monitor(worker)

    assert_receive {:close_attempt, 1}

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :cleanup_timeout_exhausted},
                   1_000

    assert_receive {:DOWN, ^manager_ref, :process, _pid, :cleanup_timeout_exhausted},
                   1_000
  end

  test "persistence failures keep retrying past the timeout budget" do
    manager = manager_replying(fn _attempt -> {:error, :persistence_failed} end)

    {:ok, worker} =
      ManagerCleanupWorker.start_link(manager, timeout_deadline_ms: 50)

    assert_receive {:close_attempt, 1}
    assert_receive {:close_attempt, 2}, 1_000
    assert_receive {:close_attempt, 3}, 1_000
    assert Process.alive?(worker)
    assert Process.alive?(manager.pid)

    Process.unlink(worker)
    Process.exit(worker, :shutdown)
  end

  test "a timeout followed by a successful close stops normally" do
    manager =
      manager_replying(fn attempt -> if attempt == 1, do: {:error, :timeout}, else: :ok end)

    manager_ref = Process.monitor(manager.pid)

    {:ok, worker} =
      ManagerCleanupWorker.start_link(manager, timeout_deadline_ms: 5_000)

    worker_ref = Process.monitor(worker)

    assert_receive {:close_attempt, 1}
    assert_receive {:close_attempt, 2}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 1_000
    refute_receive {:DOWN, ^manager_ref, :process, _pid, _reason}, 100

    Process.exit(manager.pid, :kill)
  end

  test "a persistence response breaks a consecutive timeout streak" do
    manager =
      manager_replying(fn
        1 -> {:error, :timeout}
        2 -> {:error, :persistence_failed}
        3 -> {:error, :timeout}
        _attempt -> :ok
      end)

    manager_ref = Process.monitor(manager.pid)

    {:ok, worker} =
      ManagerCleanupWorker.start_link(manager, timeout_deadline_ms: 1_500)

    worker_ref = Process.monitor(worker)

    for attempt <- 1..4 do
      assert_receive {:close_attempt, ^attempt}, 1_500
    end

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 1_000
    refute_receive {:DOWN, ^manager_ref, :process, _pid, _reason}, 100

    Process.exit(manager.pid, :kill)
  end

  defp manager_replying(reply_fun) do
    test = self()

    pid =
      spawn(fn ->
        reply_loop(test, reply_fun, 1)
      end)

    %TokenManager{pid: pid, resource: "https://example.test/resource"}
  end

  defp non_answering_manager do
    test = self()
    pid = spawn(fn -> non_reply_loop(test, 1) end)
    %TokenManager{pid: pid, resource: "https://example.test/resource"}
  end

  defp reply_loop(test, reply_fun, attempt) do
    receive do
      {:"$gen_call", from, :close} ->
        send(test, {:close_attempt, attempt})
        GenServer.reply(from, reply_fun.(attempt))
        reply_loop(test, reply_fun, attempt + 1)

      _message ->
        reply_loop(test, reply_fun, attempt)
    end
  end

  defp non_reply_loop(test, attempt) do
    receive do
      {:"$gen_call", _from, :close} ->
        send(test, {:close_attempt, attempt})
        non_reply_loop(test, attempt + 1)

      _message ->
        non_reply_loop(test, attempt)
    end
  end
end
