defmodule PtcRunner.Kernel.MCPOAuth.ManagerCleanupWorkerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPOAuth.ManagerCleanup
  alias PtcRunner.Kernel.MCPOAuth.ManagerCleanupWorker
  alias PtcRunner.Kernel.MCPOAuth.TokenManager

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "bounded cleanup" do
    test "gives up on a manager whose close never succeeds" do
      manager = stuck_manager()
      manager_ref = Process.monitor(manager.pid)

      {:ok, worker} = ManagerCleanupWorker.start_link(manager, deadline_ms: 150)
      worker_ref = Process.monitor(worker)

      assert_receive {:DOWN, ^worker_ref, :process, ^worker, reason}, 2_000

      # The exit must be abnormal: `Process.link/1` in the worker's init is the
      # reclamation mechanism, and links do not propagate normal exits. A
      # `:normal` stop here would free the cleanup slot and leave the credential
      # owner running — strictly worse than retrying forever.
      refute reason == :normal

      assert_receive {:DOWN, ^manager_ref, :process, _pid, _manager_reason}, 1_000
    end

    test "a close that succeeds before the deadline still stops normally" do
      manager = recovering_manager(2)
      manager_ref = Process.monitor(manager.pid)

      {:ok, worker} = ManagerCleanupWorker.start_link(manager, deadline_ms: 5_000)
      worker_ref = Process.monitor(worker)

      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 5_000

      # A graceful close is what revokes the remote token, so the manager must
      # not be killed on this path.
      refute_receive {:DOWN, ^manager_ref, :process, _pid, _reason}, 200
    end

    # `ManagerCleanup` is a node-global singleton started by the application, so
    # this drives the running one. Every assertion is keyed by this test's own
    # manager pid, so it does not observe or disturb concurrent adopters.
    test "the cleanup owner releases the slot once a bounded worker gives up" do
      manager = stuck_manager()

      :ok = ManagerCleanup.adopt(manager)
      assert {:ok, worker} = ManagerCleanup.adopted_worker(manager.pid)

      worker_ref = Process.monitor(worker)
      Process.exit(worker, :cleanup_deadline_exceeded)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 1_000

      assert eventually(fn -> ManagerCleanup.adopted_worker(manager.pid) == :error end)
    end
  end

  # A manager whose `:close` always answers with an error. `TokenManager.close/1`
  # returns whatever the call returns unless the process exits, so an explicit
  # error reply drives the retry loop without waiting out `@close_timeout_ms`.
  defp stuck_manager, do: manager_replying(fn _attempt -> {:error, :stuck} end)

  # Fails `failures` times, then closes cleanly.
  defp recovering_manager(failures),
    do: manager_replying(fn attempt -> if attempt > failures, do: :ok, else: {:error, :busy} end)

  defp manager_replying(reply_fun) do
    pid = spawn(fn -> reply_loop(reply_fun, 1) end)
    %TokenManager{pid: pid, resource: "https://example.test/resource"}
  end

  defp reply_loop(reply_fun, attempt) do
    receive do
      {:"$gen_call", from, :close} ->
        GenServer.reply(from, reply_fun.(attempt))
        reply_loop(reply_fun, attempt + 1)

      _other ->
        reply_loop(reply_fun, attempt)
    end
  end

  defp eventually(check, remaining \\ 50) do
    cond do
      check.() -> true
      remaining == 0 -> false
      true -> eventually(check, remaining - 1)
    end
  end
end
