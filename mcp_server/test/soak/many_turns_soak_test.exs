defmodule PtcRunnerMcp.ManyTurnsSoakTest do
  @moduledoc """
  Soak test: a single MCP PTC-Lisp session driven through many turns
  must not grow without bound.

  Each turn commits a candidate state delta into the session
  (`Projection`). The session's `user` namespace and execution history
  are the long-lived state on the BEAM side; the test verifies that
  unbounded accumulation in that state is bounded by the Projection
  layer's trimming / cap logic — or, if no cap exists, surfaces the
  growth so we can decide where to add one.

  Two scenarios:

    1. **Stateless turns** — each turn returns a small constant
       value. State should NOT grow turn-over-turn beyond a small
       per-turn metadata overhead.

    2. **State-accumulating turns** — each turn appends a small map
       into the session's user namespace via `(def! key val)`-style
       writes. The per-session GenServer process memory growth IS
       expected here; we assert it stays linear in the number of
       written keys (not, e.g., quadratic in turn count).

  ## Run

      MIX_ENV=test mix test --only soak \\
        test/soak/many_turns_soak_test.exs --color

      PTC_SOAK_ITERATIONS=2000 \\
        MIX_ENV=test mix test --only soak \\
        test/soak/many_turns_soak_test.exs
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Sessions.Registry, as: SessionsRegistry
  alias PtcRunnerMcp.TestSupport.MemorySoak
  alias PtcRunnerMcp.TestSupport.SoakHelpers

  @moduletag :soak
  @moduletag timeout: :infinity

  setup do
    iters = MemorySoak.iteration_count()

    SoakHelpers.setup_sessions(%{
      enabled: true,
      max_session_bindings: iters + 100,
      max_session_memory_bytes: 64 * 1024 * 1024,
      max_session_binding_bytes: 16 * 1024 * 1024
    })

    {:ok, iters: iters}
  end

  test "stateless turns don't grow the session GenServer", %{iters: iters} do
    session_id = SoakHelpers.start_session()
    session_pid = session_pid!(session_id)

    before_session = process_memory(session_pid)
    before = MemorySoak.snapshot()
    IO.puts("BEFORE (stateless turns, n=#{iters}):\n#{MemorySoak.format(before)}")

    MemorySoak.loop(iters, fn _phase ->
      SoakHelpers.eval_ok!(session_id, "(+ 1 2)")
    end)

    after_session = process_memory(session_pid)
    aft = MemorySoak.snapshot()

    IO.puts(
      "AFTER  (stateless turns, n=#{iters}):\n#{MemorySoak.format(aft)}\n" <>
        "Session GenServer: #{before_session} → #{after_session} bytes"
    )

    # Per-turn metadata is recorded in the session's projection state
    # (turn counter, last-eval timestamp, etc.). That's bounded, so the
    # GenServer should grow modestly.
    assert after_session - before_session < 5_000_000,
           "Session GenServer grew by #{after_session - before_session} bytes — " <>
             "expected sub-5MB for stateless turns."

    MemorySoak.assert_flat!(before, aft, :binary, tolerance_pct: 100)
    MemorySoak.assert_atoms_per_iter!(before, aft, iters)

    SoakHelpers.close_session!(session_id)
  end

  test "writes that accumulate user-namespace state grow linearly", %{iters: iters} do
    session_id = SoakHelpers.start_session()
    session_pid = session_pid!(session_id)

    before_session = process_memory(session_pid)
    before = MemorySoak.snapshot()
    IO.puts("BEFORE (accumulating turns, n=#{iters}):\n#{MemorySoak.format(before)}")

    # Each turn defines a fresh user-namespace var. With N turns this
    # should leave N entries in the session's `user` namespace and the
    # GenServer state grows roughly linearly with N (~hundreds of bytes
    # per entry, give or take).
    MemorySoak.loop(iters, fn {_phase, i} ->
      program = "(def x_#{i} (str \"value-\" #{i}))"
      SoakHelpers.eval_ok!(session_id, program)
    end)

    after_session = process_memory(session_pid)
    aft = MemorySoak.snapshot()

    growth_per_turn = (after_session - before_session) / max(iters, 1)

    IO.puts(
      "AFTER  (accumulating, n=#{iters}):\n#{MemorySoak.format(aft)}\n" <>
        "Session GenServer: #{before_session} → #{after_session} bytes " <>
        "(~#{Float.round(growth_per_turn, 1)} bytes/turn)"
    )

    # Linear is expected here. Quadratic would mean ~iters^2 bytes —
    # tens of MB by 5k turns. Cap at 50 KB/turn which is generous for
    # a 10-char binding.
    assert growth_per_turn < 50_000,
           "Per-turn growth #{Float.round(growth_per_turn, 1)} B/turn looks super-linear."

    # Atoms must NOT grow — `def x_N` is a string binding, not an atom.
    # If this ever bumps, someone introduced `String.to_atom/1` on user
    # input somewhere in the eval path.
    MemorySoak.assert_atoms_per_iter!(before, aft, iters)

    SoakHelpers.close_session!(session_id)
  end

  defp session_pid!(session_id) do
    {:ok, %{pid: pid}} = SessionsRegistry.lookup(session_id)
    pid
  end

  defp process_memory(pid) do
    case Process.info(pid, :memory) do
      {:memory, m} -> m
      nil -> 0
    end
  end
end
