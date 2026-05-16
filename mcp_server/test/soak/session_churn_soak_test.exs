defmodule PtcRunnerMcp.SessionChurnSoakTest do
  @moduledoc """
  Soak test: starting and closing many MCP PTC-Lisp sessions in
  sequence must not leak processes, ETS rows, or memory.

  The MCP server's `Sessions.Registry` GenServer + `Sessions.Supervisor`
  DynamicSupervisor are the main long-lived state. If `close_session`
  ever leaves an orphaned `Sessions.Session` GenServer alive, the
  process count climbs forever; if it forgets to clear a Registry
  entry, the GenServer's state grows.

  Each iteration:
    1. `ptc_session_start` (create supervised Session GenServer)
    2. one `ptc_session_eval` (commits state, exercises the snapshot
       reserve/commit flow)
    3. `ptc_session_close` (Registry.mark_closed + child termination)

  Assertions:
    * Process count returns to baseline (±tolerance).
    * Total memory grows < 30%.
    * Atom count is exactly stable.
    * `:erlang.memory(:binary)` grows < 50%.

  ## Run

      MIX_ENV=test mix test --only soak \\
        test/soak/session_churn_soak_test.exs --color

      PTC_SOAK_ITERATIONS=5000 \\
        MIX_ENV=test mix test --only soak \\
        test/soak/session_churn_soak_test.exs
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Sessions.Registry, as: SessionsRegistry
  alias PtcRunnerMcp.TestSupport.MemorySoak
  alias PtcRunnerMcp.TestSupport.SoakHelpers

  @moduletag :soak
  @moduletag timeout: :infinity

  setup do
    SoakHelpers.setup_sessions(%{enabled: true, max_sessions: 10_000})
    {:ok, iters: MemorySoak.iteration_count()}
  end

  test "start → eval → close churn returns to baseline", %{iters: iters} do
    before = MemorySoak.snapshot()
    IO.puts("BEFORE (churn, n=#{iters}):\n#{MemorySoak.format(before)}")

    MemorySoak.loop(iters, fn _phase ->
      session_id = SoakHelpers.start_session()
      SoakHelpers.eval_ok!(session_id, "(+ 1 2 3)")
      SoakHelpers.close_session!(session_id)
    end)

    flush_registry()

    aft = MemorySoak.snapshot()
    IO.puts("AFTER  (churn, n=#{iters}):\n#{MemorySoak.format(aft)}")

    MemorySoak.assert_procs_stable!(before, aft, tolerance: 10)
    MemorySoak.assert_flat!(before, aft, :total, tolerance_pct: 30)
    MemorySoak.assert_flat!(before, aft, :binary, tolerance_pct: 50)
    MemorySoak.assert_atoms_per_iter!(before, aft, iters)
  end

  # `ptc_session_close` makes the Session GenServer reply then `:stop`
  # itself, and casts `mark_closed` to the Registry. The Session pid is
  # dead by the time `Tools.call` returns, but the Registry's pending
  # `:mark_closed` cast may still be in flight. `:sys.get_state/1` issues
  # a synchronous `:system` message that drains all preceding casts,
  # which is what we actually want — no `Process.sleep` poll loop.
  defp flush_registry do
    case Process.whereis(SessionsRegistry) do
      nil -> :ok
      pid -> _ = :sys.get_state(pid, 5_000)
    end

    :ok
  end
end
