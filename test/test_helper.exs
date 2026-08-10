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
# - :clojure tests require Babashka and are excluded by default, run with --include clojure
# - :soak tests are long-running memory soak tests, excluded by default.
#   Run with: `mix test --only soak` (see test/soak/README.md)
# - :nightly tests are excluded by default and run only in the `Nightly`
#   workflow via `mix nightly`. Reserve the tag for tests whose cost is
#   measured in tens of seconds: today the downstream-consumer build (61.1 s)
#   and the benchmark task (25.5 s), which together were 40% of the CI suite's
#   177.8 s `async: false` serial floor.
#
#   `:nightly` is deliberately NOT `:slow`. `:slow` means only "skip on the
#   fast pre-commit path" and is consumed solely by `.githooks/pre-commit`;
#   those tests still run in `precommit`, pre-push, and CI. Excluding `:slow`
#   globally removed ten correctness tests -- cross-runtime append leases,
#   hard-link lease aliasing, concurrent same-path appends, input-size
#   bounding, and the pre-push gate's own tests -- from every PR gate to save
#   14.2 s in total. That is the wrong trade, and it is why the two tags are
#   separate: a tag that means "expensive" must not silently also mean
#   "unverified on pull requests".
exclusions = [:skip, :e2e, :clojure, :soak, :nightly]

# Run clojure conformance tests: mix test --include clojure
#
# `max_cases` defaults to `System.schedulers_online() * 2`, which on a
# 10-core machine schedules 20 tests in parallel. Tests that spawn a
# `PtcRunner.Sandbox.execute/3` child (1 s wall-clock cap) can be
# starved of scheduler time under that load, surfacing as flaky
# `{:error, ...}` returns from `Lisp.run/2` calls that should always
# succeed. Capping at `schedulers_online()` halves the contention while
# preserving parallelism.
ExUnit.configure(
  exclude: exclusions,
  max_cases: System.schedulers_online()
)

ExUnit.start()
