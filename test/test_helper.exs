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
exclusions = [:skip, :e2e, :clojure]

# Run clojure conformance tests: mix test --include clojure
ExUnit.configure(exclude: exclusions)
ExUnit.start()
