# Phase 2 Decision-Point Results

| Field | Value |
|---|---|
| Status | Recorded |
| Spec | [`ptc-runner-mcp-aggregator.md`](ptc-runner-mcp-aggregator.md) §12.4.3, §14 |
| Bench script | `mcp_server/bench/aggregator_vs_native.exs` |
| Reproduce | `cd mcp_server && mix run --no-start bench/aggregator_vs_native.exs` |
| Recorded | 2026-05-09 |

This document records the §14 decision-point measurements taken at
the close of Phase 2.3, plus the recommendation for the next phase.
Numbers come from a single bench run on developer hardware (Apple
silicon, in-process Fakes, no network). One run per measurement —
this is signal, not a statistical study.

Reproduce from `mcp_server/` (not the parent repo root — the parent
Mix project does not depend on `:ptc_runner_mcp` and cannot compile
it on a clean checkout). The bench scrubs `PTC_RUNNER_MCP_UPSTREAMS`
to a non-existent path so any installed real-upstream config does
not bleed into the fake-only measurement.

## Workflow

> Read three files from a Fake filesystem-MCP, count lines in each,
> and return the file with the largest line count.

The transform is a one-line `apply max-key`; the response is a
2-field map `{:file "c.txt" :line-count 60}`. Three files of ~1KB
each (`a.txt` 20 lines, `b.txt` 40 lines, `c.txt` 60 lines) — chosen
to be representative of "non-trivial tool output the LLM would
otherwise have to wade through" without inflating the bench script.

Two scenarios:

* **A — naive multi-call**: simulates an LLM client that issues N
  separate `tools/call` requests (one per upstream tool, as if each
  upstream tool were natively exposed). Token cost is bytes-of-JSON
  / 4 across all request and response envelopes plus a small
  client-side synthesis output.
* **B — aggregator**: one `lisp_eval` request whose program
  orchestrates the same upstream calls and returns only the
  transformed value. Token cost is the bytes/4 of the single
  request (program text included) plus the single response
  envelope (transformed value + `upstream_calls` array).

## §14 Field 1 — Token comparison

| Scenario | Request tokens | Response tokens | Output tokens | **Total** |
|---|---:|---:|---:|---:|
| A — naive multi-call | 81 | 4209 | 8 | **4298** |
| B — aggregator | 165 | 205 | n/a | **370** |

* **Ratio (A / B): 11.62×**
* **Absolute delta (A − B): 3928 tokens saved by the aggregator.**

Scenario A's request side scales with N upstream calls (here, 3 small
JSON-RPC envelopes); Scenario B's response side is the transformed
value only. Most of A's cost is the response envelopes carrying the
raw file payload — exactly the cost the aggregator removes by keeping
the upstream payloads sandboxed and surfacing only the transform.

This is the headline win of the aggregator design and matches the §15
"best fit: filtering large tool outputs, reducing context pressure"
positioning. Tiny payloads (a fixture with a few hundred bytes per
file) collapse the gap or invert it; non-trivial payloads (and
production tool outputs are non-trivial) preserve it.

## §14 Field 2 — Program success rate

* **100/100** runs of the same program text returned the expected
  transform.

This measures the runtime, not the LLM. The §14 question is "can a
calling LLM reliably write correct `(tool/mcp-call ...)` programs
from the catalog?" — that requires an LLM-in-the-loop bench and is
NOT measured here. What this 100/100 result confirms is the
boring-but-load-bearing precondition: given a correct program text,
the aggregator runtime produces the correct transform deterministically
across repeated invocations. There is no flaky scheduling, no
order-dependent state leak, no resource limit triggering on the
hot path.

LLM authoring reliability is open and falls into Phase 3+ work.

## §14 Field 3 — Latency: sequential vs pmap

Each Fake upstream call sleeps 50ms (configured per-call inside the
Fake's tool fun, no Fake API change). Three calls per program.

| Mode | Wall-clock | Result |
|---|---:|---|
| Sequential `(map ...)` | 155 ms | success |
| Parallel `(pmap ...)` | 55 ms | success |

* **Speedup: 2.82×.**

Sequential lands within ~3% of the theoretical 150 ms (3 × 50 ms);
pmap lands within ~10% of the theoretical 50 ms (a single 50 ms
upstream call). Parallel orchestration is real — `pmap` actually
parallelizes the upstream calls — and the speedup tracks N for
embarrassingly-parallel cross-server fan-out.

## §14 Field 4 — Failure clarity

One Fake tool was configured to return
`{:error, :upstream_error, "synthetic-failure-reason"}`. The program
called one healthy tool then the failing one. Resulting
`upstream_calls`:

```json
{"duration_ms":1,"server":"fs","status":"ok","tool":"read_file"}
{"duration_ms":0,"error":"synthetic-failure-reason","reason":"upstream_error","server":"fs","status":"error","tool":"broken_read"}
```

Both entries carry the §8.5-required fields (`server`, `tool`,
`status`, `duration_ms`). The error entry adds `reason` (the stable
taxonomy: `upstream_error`, `timeout`, `response_too_large`,
`upstream_unavailable`, `cap_exhausted`) and `error` (the freeform
detail string, here our synthetic value).

**Judgment**: an LLM reading this envelope has enough information to
decide between retry, narrow, and surface. The reason taxonomy is
small and stable; the detail string carries upstream-specific text
verbatim. No structural redesign needed before broader rollout.

## §14 Field 5 — `:json-null` ergonomics

A Fake configured to return `{:ok, nil}` was called by a program
that branches on `(= result :json-null)`. Result:

```
{:branch "null-handled"
 :is-elixir-nil false
 :is-json-null true
 :resp :json-null}
```

Confirms §7.3 verbatim:

* `{:ok, nil}` from the upstream surfaces as the `:json-null` keyword
  sentinel inside the sandbox.
* The program distinguishes it from a world-fault (Elixir `nil`) by
  equality.
* `:json-null` is NOT itself a world-fault — `upstream_calls[0].status`
  is `"ok"`.

The keyword-sentinel mechanic works exactly as spec'd. **Caveat**:
this measures runtime correctness, not LLM ergonomics. Whether
LLM-authored programs reliably reach for the `(= result :json-null)`
guard, or default to `(when result ...)` / `(remove nil? ...)` and
silently miscount, is the §14 v1 hypothesis still under test —
also Phase 3+ work, also requires LLM-in-the-loop.

## §14 Field 6 — Client behavior

**Deferred.** This requires real MCP clients (Claude Desktop, Claude
Code, others) to verify they:

1. Accept the extended `outputSchema` carrying the `upstream_calls`
   array.
2. Render or surface the inline catalog (Phase 3) without rejecting
   the tool advertisement.

Cannot be validated from inside the bench harness. Schedule client-
side testing alongside Phase 3 catalog work.

## Decision

**Recommendation: Continue to Phase 3 (config ergonomics + catalog).**

The §14 measurements that COULD be made here support the aggregator's
core value proposition:

* The token saving is order-of-magnitude (11×, ~4000 tokens on a
  tiny 3-file workflow). Real workflows with larger payloads or more
  upstream calls multiply this.
* `pmap` actually parallelizes; cross-server fan-out gets the
  speedup the spec promises.
* The failure envelope is informative and structured.
* The runtime is deterministic at the program level.

The §14 measurements that COULD NOT be made here (program success
rate WITH the LLM in the loop, `:json-null` LLM ergonomics, client
behavior) are precisely the questions Phase 3 work will surface
naturally — Phase 3's inline catalog is the input to "can the LLM
write correct programs?" and the catalog rollout is the trigger for
real-client testing.

Pausing now would gather the same data more slowly (the LLM-in-the-
loop bench is Phase 3-adjacent; the client compatibility check
needs the catalog). Revisiting deferred features (§3 — native
exposure, `mcp/<server>` namespace, etc.) would prioritize surface
area over evidence; we have no signal those features unlock more
value than the catalog does. Continue.

This is a recommendation. The user makes the final call.

## Notes and limitations

* **Token approximation.** Bytes/4 is a coarse stand-in for a real
  tokenizer. The 11× ratio is well above any plausible
  bytes-per-token error band, so the order-of-magnitude conclusion
  is robust. Exact comparisons with a specific model would need that
  model's tokenizer.
* **Single run per measurement.** Latency in particular has natural
  noise; the 2.82× pmap speedup is one observation. Repeat runs
  before publishing a number; for a Continue/Pause decision, one is
  enough.
* **No real LLM.** Token costs are wire costs; the per-token model
  cost varies by provider. The shape of the comparison (one big
  request vs N round-trips) is what the aggregator changes.
* **In-process Fakes only.** Real upstream behavior (handshake
  jitter, partial responses, slow tools) is verified separately by
  Phase 2.2's `real_filesystem_test`; this bench's job is to compare
  orchestration shapes, not to validate the Stdio path.
