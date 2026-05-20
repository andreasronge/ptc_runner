# MCP Aggregator Codex Probe — 2026-05-10

## Scope

This note summarizes the Codex usability probes against
`ptc_runner_mcp` aggregator mode with GitHub MCP as an upstream. The
main question was whether compact authoring guidance and read-only
annotations make Codex use the aggregator cleanly for GitHub issue
search/reduction.

## Current branch changes

Uncommitted changes under `mcp_server/`:

- Aggregator authoring card now has compact "Authoring rules":
  unwrap with `(mcp/json r)` / `(mcp/text r)`, return compact
  selected fields, avoid `println` for large previews, and omit
  `signature` for exploratory aggregator calls.
- `Tools.tool_entry/0` now uses profile-specific `inputSchema`.
  Normal mode keeps the existing `signature` description; aggregator
  mode says to usually omit `signature`.
- Tests cover both the new authoring-card text and the aggregator
  profile-specific signature description.

Verification:

```bash
cd mcp_server
mix format
mix test test/ptc_runner_mcp/tools_phase3_test.exs \
  test/ptc_runner_mcp/aggregator_phase1a_test.exs
```

Result: `40 tests, 0 failures`.

## Codex probe setup

Probe used `codex exec --ephemeral` with `ptc_runner` configured as an
MCP server. The aggregator was started with:

- GitHub MCP Docker upstream: `ghcr.io/github/github-mcp-server`
- `GITHUB_READ_ONLY=1`
- `GITHUB_TOOLSETS=repos,issues,pull_requests`
- `PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY=true`
- full trace payloads written under `/tmp/ptc-mcp-codex-quality-v4`

Prompt:

> Use the MCP server named ptc_runner and its lisp_eval tool.
> Search GitHub issues in github/github-mcp-server for recent open
> issues mentioning authentication or OAuth. Use the aggregator to
> filter/reduce the upstream result before returning it. Return only a
> compact list of up to 5 items with issue number, title, state, and
> URL. Do not use shell commands for GitHub; use the ptc_runner MCP
> aggregator.

## Findings

### 1. Read-only annotations no longer block Codex

With `PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY=true`, Codex used the
aggregator. Calls were not cancelled due to safety annotations.

### 2. Signature guidance is not enough

Codex still made one first exploratory call with:

```json
{"signature": "any"}
```

That failed with `args_error` because `any` is not valid PTC
signature syntax. Codex then recovered and made subsequent calls
without `signature`.

Probe outcome:

- 1 failed MCP call: malformed `signature`
- 7 successful MCP calls
- all successful calls omitted `signature`

Interpretation: schema/card guidance helps after recovery, but does
not fully prevent the first-call `signature: "any"` habit.

### 3. Generated PTC-Lisp quality improved but is still exploratory

Codex correctly used:

- `(tool/mcp-call ...)`
- `(mcp/text r)` followed by `(json/parse-string ...)`
- map/filter/reduce-style compaction
- selected output fields

It still spent several calls discovering response shape and tuning the
GitHub search query. The final answer was semantically good, returning:

- `#2224` — external OAuth / custom authorization server validation
- `#2075` — fail-closed startup when PAT/OAuth scopes are unmet

### 4. Large-output reduction works, but final rendering can still truncate

Representative trace metrics:

- raw `search_issues` pass: `result_bytes: 51600`
- compact title-filtered search pass: `result_bytes: 763`
- final `issue_read` verification pass: `result_bytes: 306`

The final MCP result was still marked `truncated` in Codex because the
server renders string return values with the current `user=> ...`
display envelope and preview limit. The underlying program result was
already compact.

## Recommended near-term fixes

1. In aggregator mode, treat placeholder signatures like `"any"` as
   omitted, or return a targeted `args_error` that explicitly says:
   "omit `signature` for exploratory aggregator calls."
2. Add response-shape hints to catalog entries, at least for common
   upstream result envelopes such as `{content: [{text}]}` and
   `structuredContent`.
3. Add an output mode for compact string/map returns that avoids
   `user=>` preview rendering when the caller already returned a
   bounded value.
4. Add a repeatable benchmark script that records:
   successful call count, failed call count, program bytes, result
   bytes, upstream call count, and final answer quality notes.

## LLM-backed aggregator spike

The idea: add an optional planner/model inside the MCP server. The MCP
client would send plain English, and the server would translate that
into PTC-Lisp, execute upstream MCP calls, maintain short-lived state,
and return a compact result plus a short capability summary.

My take: this is worth a spike, but it is a different product mode from
the current aggregator. The current value proposition is "caller LLM
writes deterministic code; server executes without an internal model."
An LLM-backed mode becomes an agentic MCP gateway. That may improve
usability, especially for clients that are poor at PTC-Lisp, but it
also changes cost, latency, privacy, determinism, and failure modes.

The right shape is an explicit second profile, not a replacement:

- `lisp_eval`: current deterministic code mode.
- `lisp_task`: natural-language task mode backed by a cheap planner LLM.

Spike questions:

1. Can the internal model reliably generate better PTC-Lisp than the
   client model, especially with GitHub/filesystem/memory upstreams?
2. Does server-side planning reduce total tokens enough to pay for the
   internal LLM call?
3. Can memory stay bounded, auditable, and per-session rather than
   becoming hidden global state?
4. Can the server expose enough trace data to debug wrong plans?
5. Can the feature be disabled by default for users who want deterministic
   no-LLM execution?

Suggested spike implementation:

- Add an opt-in `:mcp_agentic_aggregator` profile gated by config.
- Add one MCP tool: `lisp_task`.
- Inputs: `task`, optional `context`, optional `session_id`, optional
  `constraints`.
- Server builds a compact prompt from the frozen upstream catalog,
  authoring rules, and recent session memory.
- Internal LLM returns PTC-Lisp only, plus a short rationale metadata
  field for traces.
- Server executes the generated PTC-Lisp through the existing sandbox.
- Server stores only bounded session memory: last task, generated
  program, compact result summary, upstream-call metadata, and failures.
- Return to client: compact answer, generated program, upstream calls,
  and trace id.

Success criteria for the spike:

- Same GitHub issue task completes with zero malformed `signature`
  attempts.
- Fewer total MCP round-trips than client-authored Codex mode.
- Final result bytes stay below 1 KB for list/search tasks.
- Trace contains enough data to reproduce the generated PTC-Lisp.
- No secrets appear in prompts, traces, or memory.

Risks:

- Hidden second LLM can make failures harder to reason about.
- Multi-turn server memory conflicts with the current one-shot mental
  model and needs clear session boundaries.
- Prompting the internal LLM with upstream outputs may reintroduce the
  token bloat the aggregator is meant to avoid.
- Privacy posture changes if upstream data is sent to a third-party
  model.
- The server needs cancellation, timeout, and budget controls across
  both model calls and upstream calls.

Recommendation: do the spike as an isolated experimental profile. Keep
the current code-mode path first-class and deterministic, then compare
both modes with the same trace metrics.
