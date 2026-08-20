# Suppress sandbox process crash reports during tests
# Set OTP logger level to :critical to hide spawned process exceptions
# (these are expected in property tests and error handling tests)
Logger.configure(level: :critical)

if System.get_env("CI") do
  Application.put_env(:stream_data, :max_runs, 300)
end

# Build exclusion list based on tags
# - :skip tests are temporarily disabled (must reference a GH issue)
# - :e2e tests require API keys and are excluded by default
# - :scheduled_e2e tests require API keys and run only in scheduled or manually
#   dispatched Integration workflows, not as pull-request gates
# - :clojure tests require Babashka and are excluded by default, run with --include clojure
# - :soak tests are long-running memory soak tests, excluded by default.
#   Run with: `mix test --only soak` (see test/soak/README.md)
# - :nightly tests are excluded by default and run only in the `Nightly`
#   workflow via `mix nightly`. Reserve the tag for operator-path Mix/OS
#   subprocesses and intentional multi-second waits: the downstream-consumer
#   build (61.1 s cold), the benchmark task (25.5 s), example `mix ptc run`
#   walks, Mix-process CLI wrappers, the 5.5 s parallel-ceiling park, and
#   tests that `:sys.suspend` a GenServer and wait its ~5 s call budget.
#   In-process unit tests that happen to take 100–400 ms stay on the PR
#   suite — including CommandEngine dispatch, HostConfig schema mirroring,
#   cross-runtime append leases, and the pre-push hook's own classification
#   tests.
#
#   `:nightly` is deliberately NOT `:slow`. `:slow` means only "skip on the
#   fast pre-commit path" and is consumed solely by `.githooks/pre-commit`;
#   those tests still run in pre-push and CI. Excluding `:slow`
#   globally removed ten correctness tests -- cross-runtime append leases,
#   hard-link lease aliasing, concurrent same-path appends, input-size
#   bounding, and the pre-push gate's own tests -- from every PR gate to save
#   14.2 s in total. That is the wrong trade, and it is why the two tags are
#   separate: a tag that means "expensive" must not silently also mean
#   "unverified on pull requests".
#
#   Set PTC_PROFILE_SLOW=1 to write every test >= 0.1 s to
#   PTC_PROFILE_SLOW_OUT (default: $TMPDIR/ptc-slow-tests.txt). Do not add
#   `--slowest` to a gate: it implies `--trace` and pins `--max-cases` to 1.
exclusions = [:skip, :e2e, :scheduled_e2e, :clojure, :soak, :nightly]

# Run clojure conformance tests: mix test --include clojure
#
# `max_cases` defaults to `System.schedulers_online() * 2`, which on a
# 10-core machine schedules 20 tests in parallel. Tests that spawn a
# `PtcRunner.Sandbox.execute/3` child (1 s wall-clock cap) can be
# starved of scheduler time under that load, surfacing as flaky
# `{:error, ...}` returns from `Lisp.run/2` calls that should always
# succeed. Capping at `schedulers_online()` halves the contention while
# preserving parallelism.
# `assert_receive`'s 100ms default is a failure deadline, not a wait: a
# message that arrives returns immediately, so raising it costs a passing
# suite nothing (the same argument as test/support/eventually.ex) while a
# saturated CI runner gets real margin. Many of these windows bound a whole
# spawned operation — fsync, dispatch, discovery — not just message delivery,
# which is how 100ms flaked in CI. `refute_receive_timeout` is deliberately
# left at its default: refute_receive always waits its full window, so
# raising it would slow every passing run.
exunit_opts = [
  exclude: exclusions,
  max_cases: System.schedulers_online(),
  assert_receive_timeout: 5_000
]

exunit_opts =
  if System.get_env("PTC_PROFILE_SLOW") do
    Keyword.put(exunit_opts, :formatters, [
      ExUnit.CLIFormatter,
      PtcRunner.TestSupport.SlowTestProfiler
    ])
  else
    exunit_opts
  end

ExUnit.configure(exunit_opts)

ExUnit.start()
