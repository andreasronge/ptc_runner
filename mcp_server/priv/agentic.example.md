# Agentic SubAgent Config

Use this JSON file with `--agentic-subagent-config` or
`PTC_RUNNER_MCP_AGENTIC_SUBAGENT_CONFIG`.

Allowed top-level keys:

- `max_turns`: positive integer. Defaults to `1`.
- `retry_turns`: non-negative integer. Defaults to `0`.
- `system_prompt`: optional object with `prefix` and `suffix` string slots.

The `system_prompt.prefix` and `system_prompt.suffix` slots are each
capped at 4096 bytes. They are inserted into the MCP-owned system prompt;
they do not replace the terminal contract, tool surface, catalog, or final
MCP recap.

Reserved or unsupported keys fail boot. This includes `tools`, `signature`,
`output`, `ptc_transport`, `completion_mode`, `trace_context`, any key that
starts with `_`, and deferred keys such as `cache`, `thinking`, and
`mission_timeout_ms`.

Related runtime flags:

- `--agentic-max-turns` / `PTC_RUNNER_MCP_AGENTIC_MAX_TURNS`
- `--agentic-retry-turns` / `PTC_RUNNER_MCP_AGENTIC_RETRY_TURNS`
- `--agentic-allow-writes` / `PTC_RUNNER_MCP_AGENTIC_ALLOW_WRITES`
- `--agentic-capability-summary-max-bytes` /
  `PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY_MAX_BYTES`
- `--agentic-capability-summary` /
  `PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY`

Precedence for turn settings is CLI/env, then this JSON file, then the MCP
built-in defaults.
