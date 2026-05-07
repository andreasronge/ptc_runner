import Config

# Production configuration for the `:ptc_runner_mcp` Mix release.
#
# Per `Plans/ptc-runner-mcp-server.md` § 15 Phase 5, the release
# attaches its stdio reader on boot and reads runtime configuration
# from CLI flags / environment variables (see `PtcRunnerMcp.Application`
# moduledoc for the full list).
config :ptc_runner_mcp, attach_stdio: true

# Keep Logger out of stdout — the wire protocol owns that channel.
# The server emits its own structured JSON-Lines logs to stderr via
# `PtcRunnerMcp.Log`.
config :logger, :default_handler, false
