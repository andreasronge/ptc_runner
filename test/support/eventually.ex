defmodule PtcRunner.TestSupport.Eventually do
  @moduledoc """
  Polls a predicate until it holds, bounded by wall clock rather than attempts.

  Five test files each carried their own `assert_eventually/2`, and the five
  disagreed about what the bound meant: 100, 1_000, 1_500, 10_000, and 50_000
  attempts, backed by no delay, `receive after 0`, `:erlang.yield/0`, or
  `receive after 10`. An attempt count is not a budget — 100 undelayed attempts
  expire in microseconds while 1_500 attempts at 10 ms cover fifteen seconds —
  so the copies that spun without delay gave up almost immediately and reported
  it as `condition did not become true`.

  Two of them also spun a scheduler flat while waiting. `test/test_helper.exs`
  caps `max_cases` at `System.schedulers_online()` precisely because sandbox
  children starve under scheduler pressure, so a busy-wait here does not merely
  burn its own core: it steals runtime from the tests running beside it and
  makes *their* timing assertions flake.

  The bound is therefore a duration, and the wait backs off in two phases. Note
  that the timeout is spent only when the predicate never holds — a condition
  that becomes true immediately returns immediately — so a generous default
  costs a passing suite nothing and buys a wide margin against a loaded runner.

  ## Why the first phase yields instead of sleeping

  Some of these predicates are edge-triggered, not level-triggered. The
  lifecycle tests watch for a committed closer on a session that then exits,
  so the state they assert on exists for a moment and is gone; polling every
  few milliseconds walks straight past it and then raises from `:sys.get_state`
  against a dead pid. Their original loop caught it by polling as fast as the
  scheduler allowed, which is why replacing that with a plain sleep broke them.

  So the opening stretch polls continuously via `:erlang.yield/0`, which is
  tight enough for an edge and still hands the scheduler to everything else,
  and only after that does the wait become a real sleep. That bounds the busy
  phase — the previous copies had no bound on theirs — while keeping the long
  tail free.

  This is a polling helper, not a substitute for synchronisation. Where a test
  can observe the transition directly, a monitor or a message from the process
  under test remains the better assertion; this exists for the cases that can
  only be observed by looking again.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  # Covers the worst scheduling case rather than the median. The transport
  # tests documented needing well past three seconds on a saturated runner,
  # and being generous here is free unless the assertion is already failing.
  @default_timeout_ms 15_000

  # How long to poll continuously before backing off. Long enough to cover an
  # edge-triggered predicate on a loaded machine, short enough that a genuinely
  # absent condition stops burning runtime almost immediately.
  @yield_phase_ms 100

  # Long enough that polling costs nothing measurable, short enough that it
  # does not add visible latency to a condition that resolves late.
  @poll_interval_ms 5

  @doc """
  Asserts `predicate` returns a truthy value within the module's budget.

  Returns `:ok` as soon as it holds. Fails the test if the deadline passes
  first, naming the budget that was spent. The budget is deliberately not a
  parameter: every call site wants "as long as a loaded runner might need",
  and no caller has yet wanted anything else.
  """
  @spec assert_eventually((-> as_boolean(term()))) :: :ok
  def assert_eventually(predicate) when is_function(predicate, 0) do
    started_at_ms = System.monotonic_time(:millisecond)
    poll(predicate, started_at_ms + @default_timeout_ms, started_at_ms + @yield_phase_ms)
  end

  defp poll(predicate, deadline_ms, yield_until_ms) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk("condition did not become true within #{@default_timeout_ms}ms")

      System.monotonic_time(:millisecond) < yield_until_ms ->
        :erlang.yield()
        poll(predicate, deadline_ms, yield_until_ms)

      true ->
        receive do
        after
          @poll_interval_ms -> poll(predicate, deadline_ms, yield_until_ms)
        end
    end
  end
end
