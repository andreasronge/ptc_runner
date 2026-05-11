import Config

# Disable automatic .env loading by req_llm so that command-line env vars take precedence
# This allows: PTC_TEST_MODEL=deepseek-local mix test --include e2e
config :req_llm, load_dotenv: false

# Widen the Sandbox wall-clock budget under test (prod default stays 1 s).
# The full suite spawns many `PtcRunner.Sandbox.execute/3` children that
# fight for scheduler slices; under heavy parallel load a trivially-fast,
# deterministic PTC-Lisp program can be starved past the 1 s cap and
# surface as a flaky `{:error, %Step{fail: %{reason: :timeout}}}` ("the
# sandbox-timeout flake class" — see commit ae0cb3b). No test relies on
# the 1 s default for correctness: infinite loops hit `:loop_limit_exceeded`,
# and timeout-behaviour tests pass an explicit small `timeout:`.
config :ptc_runner, default_timeout: 10_000
