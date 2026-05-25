# Changelog

All notable changes to `ptc_runner_mcp` are documented here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this package adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
See `Plans/ptc-runner-mcp-server.md` § 7.3 for the versioning
policy that governs MCP `protocolVersion` floor and primary
revisions.

## Unreleased

Initial standalone MCP server release candidate.

### Added

- Standalone `ptc_runner_mcp` Mix release for stdio JSON-RPC clients.
- Stateless `lisp_eval` and stateful `lisp_session_*` tools.
- Aggregator mode for calling configured upstream MCP servers from PTC-Lisp.
- PTC-Lisp catalog discovery helpers and REPL discovery forms for upstream
  tools.
- Agentic `lisp_task` planner mode plus benchmark and real-provider eval
  scripts.
- Response profiles: `slim` (default), `structured`, and `debug`.
- Opt-in `lisp_debug` diagnostics with `stats`, `recent`, and `get`.
- Payload-reduction metrics for aggregator-mode and `lisp_task` responses.
- JSON-as-text auto-decode for successful upstream tool results, with telemetry
  for decode outcomes.
- Upstream metadata fields, catalog tuning flags, and clearer upstream result
  contracts.
- Release dry-run task: `mix mcp.release_dry_run`.

### Defaults And Compatibility

- The server advertises the `ptc_lisp` identity and supports MCP protocol
  versions `2025-11-25` and `2025-06-18`.
- Eval tools default to concise `slim` responses. Use `--response-profile
  structured` or `debug` when a client needs `structuredContent`.
- Return validation uses `output_schema`; the old MCP-facing `signature`
  argument is not part of the public tool contract.
- Stateless `lisp_eval` is one-shot and does not expose memory metadata. Use
  session tools for stateful evals.

### Packaging

- Initial release target is `ptc_runner_mcp-darwin-arm64.tar.gz`.
- The distributable archive contains the full Mix release directory, including
  `bin`, `erts-*`, `lib`, and `releases`.
- Release validation builds the archive, verifies `SHA256SUMS`, extracts it,
  and smoke-tests the extracted binary.
