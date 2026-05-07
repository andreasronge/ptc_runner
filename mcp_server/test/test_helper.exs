ExUnit.start()

# Default tests to a quiet logger; individual tests that exercise
# stderr emission can `PtcRunnerMcp.Log.set_level/1` themselves.
PtcRunnerMcp.Log.set_level(:error)
