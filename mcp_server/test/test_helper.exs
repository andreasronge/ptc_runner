# Phase 6 integration tests live under `test/integration/` and are
# tagged `:integration` (often with a sub-tag like `:release`,
# `:inspector`, or `:cross_language`). They drive the built release
# binary as an external subprocess and require
# `MIX_ENV=prod mix release --overwrite` to have run first. They are
# excluded from the default `mix test` run; opt in with
# `mix test --only integration` or `--include integration`.
ExUnit.start(exclude: [:integration])

# Default tests to a quiet logger; individual tests that exercise
# stderr emission can `PtcRunnerMcp.Log.set_level/1` themselves.
PtcRunnerMcp.Log.set_level(:error)
