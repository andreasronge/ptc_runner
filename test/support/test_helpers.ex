defmodule PtcRunner.TestSupport.TestHelpers do
  @moduledoc """
  Shared test helper functions used across multiple test files.
  """

  @doc "Dummy tool that ignores name and args and returns :ok"
  def dummy_tool(_name, _args), do: :ok

  @doc """
  Stops a process (Agent/GenServer) started in test setup, tolerating the
  teardown race. A `start_link`-ed process dies with the test process, which can
  race `on_exit`: `if Process.alive?(pid), do: GenServer.stop(pid)` is a TOCTOU —
  the pid can read alive and then exit `:noproc` before the stop lands. This
  swallows that exit and is a no-op on an already-dead pid or non-pid value.
  """
  def stop_quietly(pid) when is_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  def stop_quietly(_), do: :ok

  @doc """
  A PTC-Lisp entry body that genuinely occupies its worker while a test
  inspects the run in flight.

  `(loop [] (recur))` reads like an infinite loop and has been used across this
  suite as one, but it is not: PTC-Lisp hard-caps `loop`/`recur` at exactly
  1_000 jumps (`PtcRunner.Lisp.Eval.Context`'s `loop_limit`, which is not
  reachable through manifest limits), and an empty body burns through that cap
  in well under a second. Any test that kills a caller, traces an owner, or
  calls `:sys.get_state/1` on a session "while the run blocks" is really racing
  that natural completion, and loses under full-suite load — surfacing as an
  `ArgumentError` or a `:noproc` exit on an already-exited process rather than
  as an obvious timeout.

  This gives each of the 1_000 iterations real work instead. `repeats` scales
  that work roughly linearly: 1 lands near 6s on a developer machine, 5 near
  30s. Callers should pick the smallest value that clears their own setup
  overhead by a wide margin — the duration is calibrated, not guaranteed, so
  the margin is what separates a real regression from hardware variance.

  Prefer a shorter body on paths that do not pass `link: true` to
  `PtcRunner.Sandbox` (notably `Runner.execute_workflow/4`): there, killing the
  caller does not tear the sandbox process down, so an early test failure
  leaves this loop running unlinked until its own deadline.
  """
  def long_running_body(repeats \\ 1) when is_integer(repeats) and repeats >= 1 do
    work =
      "(reduce + 0 (range 20000))"
      |> List.duplicate(repeats)
      |> Enum.join(" ")

    "(loop [i 0 acc 0] (if (< i 1000) (recur (inc i) (+ acc #{work})) acc))"
  end
end
