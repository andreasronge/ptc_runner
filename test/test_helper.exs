# Suppress sandbox process crash reports during tests
# Set OTP logger level to :critical to hide spawned process exceptions
# (these are expected in property tests and error handling tests)
Logger.configure(level: :warning)
:logger.set_primary_config(:level, :critical)

if System.get_env("CI") do
  Application.put_env(:stream_data, :max_runs, 300)
end

# Build exclusion list based on tags
# - :skip tests are temporarily disabled (must reference a GH issue)
# - :e2e tests require API keys and are excluded by default
# - :clojure tests require Babashka and are excluded by default, run with --include clojure
# - :soak tests are long-running memory soak tests, excluded by default.
#   Run with: `mix test --only soak` (see test/soak/README.md)
exclusions = [:skip, :e2e, :clojure, :soak]

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
