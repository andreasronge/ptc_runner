# MCP 2026-07-28 gateway conformance inventory

The gateway gate uses `@modelcontextprotocol/conformance@0.2.0-alpha.11`, the
package containing the frozen 2026-07-28 requirements, and selects the named
scenarios with `--spec-version 2026-07-28`. It runs these scenarios:

- `server-stateless`: discovery, request metadata, version/header, capability
  consistency, unsupported-method, and correlated-error checks run. The
  checked-in baseline excludes only optional server identity, diagnostic
  `tools/call`, independent response-stream, and logging-tool checks.
- `tools-list`: all checks run.
- `dns-rebinding-protection`: all checks run through the proxy with the
  caller's Origin preserved and Host rewritten to the configured authority.
- `caching`: `tools/list` checks run. Prompt, resource, and resource-template
  checks are excluded because those feature families are unsupported.

The exact excluded check IDs and reasons are:

| Scenario/check ID | Reason |
| --- | --- |
| `server-stateless:sep-2575-server-identifies-in-result-meta` | Optional server identity is not published by this milestone. |
| `server-stateless:sep-2575-server-rejects-undeclared-capability` | Requires the `test_missing_capability` diagnostic tool and `tools/call` from #1922. |
| `server-stateless:sep-2575-missing-capability-http-400` | Same #1922 diagnostic-tool dependency. |
| `server-stateless:sep-2575-http-server-no-independent-requests-on-stream` | Requires the unsupported response-stream surface. |
| `server-stateless:sep-2575-server-no-log-without-loglevel` | Requires the unsupported logging diagnostic tool. |
| `caching:sep-2549-prompts-list-caching-hints` | Prompts are outside this tools-only profile. |
| `caching:sep-2549-resources-list-caching-hints` | Resources are outside this tools-only profile. |
| `caching:sep-2549-resources-templates-list-caching-hints` | Resource templates are outside this tools-only profile. |

`http-header-validation` is deferred in full to #1922:
the alpha.11 scenario reuses check IDs across `Mcp-Method` and the unsupported
`tools/call`/`Mcp-Name` cases, so it cannot be partially baselined. This issue's
raw HTTP tests independently cover method-header presence, mismatch, casing,
OWS, duplication, and all eight critical-header duplicate cases.

`http-custom-header-server-validation` is deferred to #1922 because it requires
callable `x-mcp-header` tools. All other frozen server scenarios exercise
unsupported tools/call, prompts, resources, completion, sessions/streams,
server requests, tasks, or subscriptions and are outside this tools-only
discovery/list milestone.
