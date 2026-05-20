# PtcRunner MCP Aggregator — State Snapshot

| Field | Value |
|---|---|
| Snapshot date | 2026-05-09 (refreshed after json-support shipped) |
| `main` HEAD | `eea8323` |
| Status | Feature-complete through Phase 4 + json-support all three phases. Live and connected to Claude Code. JSON ergonomics validated end-to-end against `mem.read_graph` (Phase B path) and a fake JSON-with-mimeType upstream (Phase C path). |

This doc is the "pick up where we left off" handoff. The
authoritative spec is still `Plans/ptc-runner-mcp-aggregator.md`
(read §16 for open items, §17 for history); this is the meta-state
that doesn't fit there.

## What shipped

| Phase | SHA | What it did |
|---|---|---|
| 0 | `775f8fc` | v1 seams (profile-aware description / outputSchema, `:tools` opt threading, telemetry profile, program-limit flags) |
| 1a | `2afc971` | `Upstream` behaviour + `Upstream.Fake` + integration (per-program ETS leader/follower lock + `:atomics` cap) |
| 1b | `eaaccdc` | Per-name `Upstream.Connection` workers + `Upstream.Stdio` (subprocess + MCP handshake) |
| 2.1 | `6d70e32` | Phase 1b polish — `Upstream.Supervisor :rest_for_one` cascade + `Registry` `:noproc` rescue |
| 2.2 | `bbfaada` | Real filesystem-MCP integration test (opt-in via `MCP_REAL_UPSTREAM=1`); bundled Phase 1a name de-flake |
| 2.3 | `25b6479` | Decision-point benchmark — measured 11.6× token saving + 2.84× pmap speedup; recommendation = continue to Phase 3 |
| 3 | `d93c88f` | Inline upstream catalog (frozen at boot via `:persistent_term`) + ergonomics + `docs/aggregator-mode.md` |
| 4 | `e1c151f` | Public `Stdio` `:binary` mode + `isError: true` normalization to `nil` (resolves §16's high+medium bugs from real-client probing) |
| de-flake | `e94e19a` | Two parallel-load test races resolved (cancellation EOF monitor + supervisor cascade TOCTOU) |
| JSON spec | `aecdb91` | `Plans/json-support.md` — drafted, 6 codex rounds, ready to implement |
| JSON Phase A | `8da57a2` | `(json/parse-string s)` + `(json/generate-string v)` PTC-Lisp builtins; analyzer/registry/docs/prompt wiring; `:json` + `:mcp` namespaces forward-compat'd. +53 tests. |
| JSON Phase B | `69b73c3` | `(mcp/text r)` + `(mcp/json r)` unwrap helpers in `:ptc_runner`; authoring cards extended; §5.2 `structuredContent`-first precedence. +45 tests. |
| Spec fix | `6852ca4` | `Plans/json-support.md` §5.2 reworded: key-presence semantics (not truthiness), `false`/`0`/`""`/`[]` carve-out. Doc-only; Phase B implementation already correct. |
| JSON Phase C | `eea8323` | Aggregator auto-decode of JSON-as-text upstreams when `mimeType: application/json` or `+json` suffix. Additive (preserves `content[]`); `:decode_failed` is silent for the program. New telemetry event `[:ptc_runner_mcp, :upstream, :auto_decode, :stop]`. +17 tests. |

mcp_server tests: 418 passing, 0 failures, 13 excluded (`:integration`, `:real_upstream`, `:clojure`).
Parent project: 4822 tests + 357 doctests + 3 properties, 0 failures.

## Live wiring

`claude mcp list` shows `ptc-runner` connected to
`~/ptc-mcp-sandbox/run.sh`. The launcher does
`cd mcp_server && mix run --no-halt --no-compile --
--upstreams-config ~/ptc-mcp-sandbox/upstreams.json`. Stderr →
`~/ptc-mcp-sandbox/server.stderr.log` so the JSON-RPC stream stays
clean on stdout.

Configured upstreams:

- `fs` = `@modelcontextprotocol/server-filesystem@2026.1.14`,
  sandboxed to `~/ptc-mcp-sandbox/`
- `mem` = `@modelcontextprotocol/server-memory` (in-memory
  knowledge graph, ephemeral per process; natively populates
  `structuredContent` on `read_graph` — exercises Phase B's
  `mcp/json` precedence)
- `fakejson` = `python3 ~/ptc-mcp-sandbox/fake_json_upstream.py`
  (one-tool fake: `get_payload` returns a fixed JSON document as
  text with `mimeType: application/json`; exercises Phase C's
  aggregator auto-decode promotion). Source: `fake_json_upstream.py`
  in the sandbox dir. Keep around as a Phase C regression target.

To re-test, open a fresh `claude` session and ask the LLM to use
`lisp_eval` against the sandbox.

### Sandbox fixtures

- `notes.txt` — 11 lines, project-status format
- `todo.md` — 10 lines
- `readme.txt` — 8 lines
- `empty.txt` — 0 bytes (`:json-null` / empty-content probes)
- `big.txt` — 3 MB of `x` (`response_too_large` and Latin1 probes —
  Phase 4 fixed the latter)

### Probe recipe

```bash
claude -p \
  --allowedTools "mcp__ptc-runner__lisp_eval" \
  --effort medium \
  "<task description>"
```

`--allowedTools` prevents the LLM from shortcutting via Bash / Read.
This forces the aggregator path and is the cleanest way to validate
LLM authoring quality against catalog-driven shapes.

## Open work, ranked

### 1. ~~Implement `Plans/json-support.md`~~ — DONE

Shipped across three phases (`8da57a2` / `69b73c3` / `eea8323`)
with one post-impl spec correction (`6852ca4`). OQ-5 resolved as
option (a) per-namespace lookup tables, materialized at compile
time from `Env.initial()` to dodge a load-order race the engineer
caught (atom interning vs `String.to_existing_atom/1`). All four
gates passed clean codex review. Live-validated:

- **Phase B path** (`mem.read_graph`): `mcp/json` correctly preferred
  the natively-populated `structuredContent` over `content[0].text`.
  Original regex-workaround obsolete.
- **Phase C path** (`fakejson.get_payload`): aggregator auto-decode
  fired (mimeType=`application/json` matched §6.1 condition 3),
  produced additive `structuredContent` alongside preserved
  `content[]`. Wire-amplification ~2× as specified.

Surprise worth flagging for future readers: on `mem.read_graph` the
regex-workaround was technically *unnecessary even pre-Phase-B* —
`mem` already populated `structuredContent`. The LLM didn't know to
look there. The actual user-visible win is the authoring-card
update advertising `mcp/json`, which steers the LLM to the typed
channel. Phase B/C plumbing makes the helper robust against the
variation in real upstreams (some populate `structuredContent`
natively, others emit JSON-as-text with mimeType, others emit
JSON-as-text without mimeType — only the third remains friction).

### 2. Phase 5 hardening — remaining §16 items

In rough priority order:

- **Stdio shutdown propagation during hung handshake.** Architectural
  — needs async `Connection.ensure_started` so Connection can
  `receive` the supervisor's `:shutdown` while waiting on Stdio.
  Already deferred from Phase 2.1. Real impact: shutdown hygiene
  during a hung-initialize upstream; not data correctness.
- **Phase 3 false-const corner case.** One-line fix in
  `mcp_server/lib/ptc_runner_mcp/upstream/catalog.ex` —
  `Map.has_key?` instead of truthiness in the const branch of
  `render_type/1`. Affects `{"const": false}` schemas only.
- **Phase 2.2 Windows path escaping.** One-line fix in
  `mcp_server/test/integration/real_filesystem_test.exs` —
  `Jason.encode!(file_path)` instead of bare interpolation. Doesn't
  affect macOS/Linux runs.
- **Decomposed cold-start telemetry.** Split `ensure_duration` and
  `call_duration` into separate metadata fields on
  `[:ptc_runner_mcp, :upstream, :call, :stop]` so operators can
  attribute cold-start cost vs steady-state cost. Both values
  already exist in the closure's local scope.

### 3. Possible Phase 5 enhancement — response-shape hints in catalog

Real-client probing showed LLMs reliably author correct
`(tool/mcp-call ...)` shapes from the input-schema catalog, but
crash-and-recover on response shapes that aren't documented. Adding
a one-line response hint per tool would close the loop:

```
read_text_file(path: string) - Read file contents. [→ {content: [{text}]}]
```

Not blocking; would meaningfully reduce first-attempt program crashes.

## Soft knowledge worth preserving

### LLM authoring quirks

- **`get-in` keyword↔string coercion.** PTC-Lisp's `get-in` accepts
  keyword OR string keys interchangeably against maps with the
  other key type. Three independent LLM probes naturally reached
  for `(get-in result [:content 0 :text])` against string-keyed
  upstream JSON envelopes and it worked. Worth treating as
  intended behavior; documented in spec §17.
- **Catalog covers inputs, not outputs.** LLMs use the catalog
  flawlessly for argument shapes but discover response shapes by
  trial. Recovery is fast (one wrong destructure → fix → retry)
  but it's a real friction point. See §3 above.
- **`isError: true` envelopes used to leak.** Pre-Phase-4, a
  nonexistent file via `fs.read_text_file` returned a non-`nil` map
  with `isError: true` instead of `nil`. The spec promised
  *world-fault → nil*; the implementation didn't. Phase 4 fixed
  this — but if other MCP shapes surface that aren't covered (e.g.,
  some upstreams return errors in `content[0].text` without
  `isError: true`), document them as world-faults too.

### Codex review rhythm

For specs (like `json-support.md`): 5-6 rounds is the diminishing-
returns threshold. After round 4, findings become taste-level
(wording consistency, redundancy). Stop iterating around round 6
unless a [P1] correctness issue surfaces.

For code (like a phase commit): 4-6 rounds is normal. Each round
usually finds one real bug that probe-testing wouldn't catch.
Memorable: the `:counters` cap rejecting all callers under `pmap`
(Phase 1a round 4) and the UTF-8 codepoint-boundary truncation
(Phase 4 round 2 — codex caught a regression in Phase 4's own fix).

### Trust-but-verify

Engineer reports "fix lands". Always run codex on the diff anyway.
Codex caught real regressions in engineer-side fixes more than once
during this project. The pattern is worth keeping for any
non-trivial change.

## Re-onboarding paths

**5 minutes**: spec §17 last 10 entries → spec §16 → `Plans/json-support.md` §4.4 four-step checklist.

**30 minutes**: + `Plans/phase2-decision-point-results.md` (§14
benchmark numbers) → `mcp_server/README.md` "Aggregator mode"
section (user-facing) → `docs/aggregator-mode.md` (programmer
reference).

**Full re-onboarding**: read the entire `Plans/ptc-runner-mcp-aggregator.md`
spec — it's 1500 lines but every section is load-bearing and the
history (§17) is the project narrative.

## Quick-reference SHAs

```
e94e19a  test(mcp): de-flake two parallel-load races
aecdb91  plan(json): JSON support spec
f3b04a9  plan(aggregator): close Phase 4 §16 entries
e1c151f  phase4(mcp): public stdio :binary + isError normalization
dc7461d  docs(aggregator): probe findings + README aggregator section
d93c88f  phase3(mcp): inline catalog + ergonomics
25b6479  phase2.3(mcp): decision-point benchmark
bbfaada  phase2.2(mcp): real filesystem-MCP integration test + de-flake
6d70e32  phase2.1(mcp): supervisor cascade + Registry rescue
eaaccdc  phase1b(mcp): Connection workers + Stdio
2afc971  phase1a(mcp): aggregator integration with Fake upstream
775f8fc  phase0(mcp): v1 seams for aggregator
989f93d  plan(aggregator): pin Phase 0/1a impl contract
```
