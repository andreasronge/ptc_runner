if System.get_env("CI") do
  Application.put_env(:stream_data, :max_runs, 300)
end

# Build exclusion list based on tags
# - :e2e tests require API keys and are excluded by default
# - :clojure tests run if Babashka is installed, can be excluded with --exclude clojure
exclusions = [:e2e]

# Check if user explicitly wants to skip clojure tests
# This allows: mix test --exclude clojure
ExUnit.configure(exclude: exclusions)
ExUnit.start()
