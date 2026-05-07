import Config

# In tests, the application supervisor must NOT attach to :stdio —
# tests start `PtcRunnerMcp.Stdio` themselves with an in-memory IO
# device.
config :ptc_runner_mcp, attach_stdio: false
