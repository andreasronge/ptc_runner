# Text Mode + PTC-Lisp Compute (Combined Mode)

This guide covers **combined mode** — text agents that opt into the
internal `ptc_lisp_execute` tool so the LLM can escalate to deterministic
PTC-Lisp computation when a result is too large to feed into the chat
context. It is the `output: :text, ptc_transport: :tool_call` shape.

For the pure transports, see [Text Mode](subagent-text-mode.md) and
[PTC-Lisp Transport](subagent-ptc-transport.md). Combined mode is
orthogonal to both: text agents that want optional escalation paths.

## What is combined mode?

Combined mode is a normal text agent with one extra provider-native tool
exposed: `ptc_lisp_execute`. The LLM answers chat-shaped turns directly
when it can; when it needs deterministic compute, multi-tool
orchestration, or filtering over a large result, it calls
`ptc_lisp_execute` with a small PTC-Lisp program that runs in PtcRunner's
sandbox.

```elixir
agent =
  PtcRunner.SubAgent.new(
    prompt: "You are a support assistant.",
    output: :text,
    ptc_transport: :tool_call,
    tools: %{
      "search_logs" =>
        {&MyApp.Logs.search/1,
         signature: "(query :string) -> [:any]",
         description: "Search log events.",
         expose: :both,
         cache: true,
         native_result: [preview: :metadata]}
    },
    max_turns: 6
  )
```

The provider sees `search_logs` (because `expose: :both`) **and**
`ptc_lisp_execute`. PTC-Lisp programs see `search_logs` because the same
`:both` setting puts it on the program-callable side. Whichever layer
calls the tool first seeds a shared cache; the other layer reuses the
result.

Combined mode is a strict superset of pure text mode in feature surface,
not a replacement. Pure `output: :text` (without `ptc_transport`) stays
unchanged.

## When to use it

Reach for combined mode when:

- A native tool returns large results (logs, query rows, scrape dumps)
  that would otherwise blow the chat context.
- The LLM may need to filter, aggregate, or join across multiple tool
  results within one user turn.
- You want a chat-shaped agent UX but with an escape hatch for
  deterministic compute on demand.
- You want to share results between a native tool call and a follow-up
  PTC-Lisp program without re-running the upstream call.

It is **not** the right fit when:

- The agent is pure chat with small tool results — overhead from the
  compact reference card and `ptc_lisp_execute` schema isn't worth it.
- You already need structured output from a single program — use
  `output: :ptc_lisp, ptc_transport: :tool_call` instead. That mode
  short-circuits on `(return v)` matching the signature; combined mode
  does not (see "Final-output semantics" below).

## Tool exposure policy

Each tool declares which layer can call it via the `expose:` option.

| Value        | Provider-native? | Inside `ptc_lisp_execute` programs? |
|--------------|------------------|-------------------------------------|
| `:native`    | yes              | no — `(tool/name ...)` rejected at parse time |
| `:ptc_lisp`  | no               | yes — only as `(tool/name ...)` |
| `:both`      | yes              | yes |

Per-mode defaults when `expose:` is omitted:

| `output:`   | `ptc_transport:`         | Default `expose:` |
|-------------|--------------------------|-------------------|
| `:text`     | not `:tool_call`         | `:native`         |
| `:text`     | `:tool_call` (combined)  | `:native`         |
| `:ptc_lisp` | any                      | `:ptc_lisp`       |

**The intentional gotcha.** Combined mode defaults to `:native`. An
agent that opts into combined mode but tags zero tools as `:both` or
`:ptc_lisp` still gets a working `ptc_lisp_execute` — useful for pure
deterministic computation, math, or transforming data passed via
`context`. But `(tool/foo ...)` calls inside programs will be rejected
**at parse time** with a clear error. This is by design: combined mode
forces deliberate exposure decisions rather than auto-promoting every
tool. Tag tools `:both` (or `:ptc_lisp`) explicitly to make them
program-callable.

The compact PTC-Lisp reference card is appended to the system prompt
even when zero tools are exposed to programs (see "`ptc_reference:`
option" below) — `ptc_lisp_execute` itself is still useful, and omitting
the card produces agents that don't know how to use it.

## The cache bridge

When a tool is `expose: :both, cache: true`, native and PTC-Lisp layers
share one cache entry per `(tool_name, canonical_args)` pair. The
canonical end-to-end transcript:

```
;; Turn 1 — User question
USER: "How many errors with code 42 last hour?"

;; Turn 2 — LLM calls native search_logs
ASSISTANT (tool_calls): [
  {id: "call_1", name: "search_logs", args: {"query": "error code 42"}}
]

;; Runtime executes search_logs/1 (1842 rows). Stores the full result
;; in tool_cache under canonical key {"search_logs", %{"query" => ...}}.
;; Returns a metadata-only preview to the LLM:

TOOL (tool_call_id: "call_1"): {
  "status": "ok",
  "result_count": 1842,
  "schema": {"type": "array", "items": {"type": "object",
              "properties": {"id": "integer",
                              "timestamp": "string",
                              "message": "string"}}},
  "sample_keys": ["id", "message", "timestamp"],
  "full_result_cached": true,
  "cache_hint": "Call ptc_lisp_execute and then call (tool/search_logs {:query \"error code 42\"}) to process the full cached result."
}

;; Turn 3 — LLM escalates to ptc_lisp_execute
ASSISTANT (tool_calls): [
  {id: "call_2",
   name: "ptc_lisp_execute",
   args: {"program": "(def rows (tool/search_logs {:query \"error code 42\"}))\n(return {:total (count rows)})"}}
]

;; Runtime hits the same canonical cache key — search_logs/1 is NOT
;; re-executed. Program runs over the cached rows. (return ...) produces
;; a successful tool result via PtcToolProtocol.render_success/2.

TOOL (tool_call_id: "call_2"): {
  "status": "ok",
  "result": "user=> {:total 1842}",
  "prints": [],
  ...
}

;; Turn 4 — LLM composes the final answer
ASSISTANT (content): "There were 1842 errors with code 42 in the queried window."
```

Two things make this work:

1. **`cache: true`** on the tool definition tells PtcRunner that
   results are safe to reuse for identical canonical args. This is the
   same `cache:` field PTC-Lisp tools have always had — combined mode
   reuses it rather than introducing a parallel `cacheable:` flag.
2. **Canonical cache key.** `PtcRunner.SubAgent.KeyNormalizer.canonical_cache_key/2`
   normalizes args before hashing: atom and string keys converge,
   nested map ordering is stabilized, and integer-equal floats collapse
   to integers. Native and PTC-Lisp callers always agree on the key
   regardless of how args arrived.

**Cache-key migration wart (deliberate).** In v1, the existing PTC-Lisp
cache path was migrated to `canonical_cache_key/2`. Most callers see no
difference, but a few previously-distinct keys now converge:

| Before | After |
|--------|-------|
| `%{"a" => 1}` and `%{a: 1}` were distinct entries | Same entry |
| `%{a: 1, b: 2}` and `%{b: 2, a: 1}` could miss each other | Same entry |
| `1` and `1.0` were distinct entries | Same entry (collapses to `1`) |

This is widening, not narrowing — fewer cache misses, never more. If a
test previously relied on a miss between (say) `1` and `1.0`, update it.
See the CHANGELOG for the migration note.

## Final-output semantics

Inside combined-mode `ptc_lisp_execute`, the program's terminating
expression — whether `(return v)`, `(fail v)`, or a normal final
expression — produces a **tool result**, not the run's final answer.
The LLM gets one more turn to compose the final answer (which is then
the agent's final answer).

| `output:` | `signature:`              | Final answer source |
|-----------|---------------------------|---------------------|
| `:text`   | none                      | LLM's final text response (raw) |
| `:text`   | `:string` / `:any`        | LLM's final text response (raw) |
| `:text`   | `{:map, ...}` / `{:list, ...}` | LLM's final text response, parsed as JSON, validated against the signature |
| `:text`   | `:int` / `:float` / `:bool` / `:datetime` | LLM's final text response, coerced to the scalar type |

**`(return v)` does not short-circuit.** The program terminates with `v`
as its final value, the runtime emits a success tool-result, and the LLM
gets one more turn to respond (budget permitting; see below). This is
identical to how every other tool call works in `:text` mode.

**`(fail v)` does not abort the run.** The program terminates with an
error tool-result (`reason: "fail"`, `result` field carrying `v`). The
LLM gets one more turn to react — apologize, retry with different args,
fall back to a textual answer.

If you want short-circuit semantics where `(return v)` matching the
signature *is* the final answer, use `output: :ptc_lisp,
ptc_transport: :tool_call` instead. That mode exists for exactly this
purpose. Combined mode is deliberately the more permissive shape.

## Turn budget guidance

`ptc_lisp_execute` consumes one `max_turns` slot like any other tool
call. The "LLM gets one more turn to respond" guarantee above is
**conditional on turn budget remaining** — it is not a reserved slot.

**Size `max_turns` with at least one slot of headroom** beyond your
worst-case `ptc_lisp_execute` count. If `max_turns` is exhausted by the
program call (so the paired `role: :tool` message is the last thing the
loop emits), the run terminates via TextMode's existing
`max_turns_exceeded` path. The `tool_call_id` is paired before
termination (universal pairing rule), but no follow-up text turn
happens, and `step.return` carries whatever max-turns handling produces
— not the program's `v`.

**`ptc_lisp_execute` itself is exempt from `max_tool_calls`.** Only
native app-tool calls count against the tool-call budget. An agent with
`max_tool_calls: 1` may still invoke `ptc_lisp_execute` repeatedly,
bounded only by `max_turns`.

## `native_result` options

For `expose: :both, cache: true` tools, `native_result:` controls the
preview shape returned to the LLM (the full result lives in the cache
regardless).

| `preview:` | What the LLM sees |
|------------|-------------------|
| `:metadata` (default) | `result_count`, JSON-Schema-ish `schema`, `sample_keys`. No row values. |
| `:rows` (with `limit:`, default 20) | First `limit` rows verbatim, plus `result_count` and `schema`. |
| 1-arity function | Whatever the function returns, merged with the universal cache fields. |

`:metadata` is safe-by-default for compliance-sensitive workloads:
nothing from the result body crosses the LLM boundary, only its shape.

```elixir
# Verbatim row preview, capped at 5
native_result: [preview: :rows, limit: 5]

# Custom preview
native_result: [preview: fn full_result ->
  %{"top_scores" => Enum.take(full_result, 3) |> Enum.map(& &1.score)}
end]
```

**Custom preview function contract.** The function receives **only
`full_result`** (not args, not tool name — capture them in a closure if
needed). It MUST return a map that `Jason.encode!/1` accepts. If the
function raises, returns a non-map, or returns a non-encodable value,
the runtime falls back to the metadata preview and emits a
`Logger.warning/1` tagged with the tool name and failure category
(`raised`, `non_map`, `non_encodable`). The tool's actual return value
is unaffected — only the preview is replaced.

The validator rejects `native_result:` unless the tool also has
`expose: :both` and `cache: true`. The combination is meaningful only
when both layers can see the tool *and* a cache exists for the layers
to share.

## `ptc_reference:` option

Combined-mode agents need at least a compact PTC-Lisp reference in the
system prompt so the LLM knows how to use `ptc_lisp_execute`. The
`ptc_reference:` option pins this:

```elixir
PtcRunner.SubAgent.new(
  prompt: "...",
  output: :text,
  ptc_transport: :tool_call,
  ptc_reference: :compact   # default; only valid value in v1
)
```

Only `:compact` is accepted in v1. The compact card is appended to the
combined-mode system prompt at runtime — roughly 270 tokens of static
content (forms, cache-reuse paragraph, one example) plus a dynamic
inventory of `:both` and `:ptc_lisp`-exposed tools.

The card source lives at
`priv/prompts/ptc_text_mode_compact_reference.md`.

Setting `ptc_reference: :full` raises `ArgumentError` — it is deferred
to a follow-up. Setting `false` or any other value also raises. Users
who don't want the prompt overhead should not opt into combined mode.

## `chat/3` interaction

Combined mode is supported in `PtcRunner.SubAgent.chat/3`. Each
`chat/3` call behaves like a fresh combined-mode run over the provided
messages. The validator does not reject combined mode at the `chat/3`
boundary.

**Cross-call state does NOT persist.** `tool_cache`, `journal`,
`turn_history`, and retained child-execution state do not survive
across `chat/3` turns. Cross-turn threading is fully deferred to a
future `ChatState` API.

**Known wart (accepted, not fixed in v1).** A previous turn's
`full_result_cached: true` + `cache_hint` references a cache key that
no longer exists on the next `chat/3` call. The LLM following the hint
causes a tool re-run — correct behavior (the upstream tool fires
again), but wasteful. The native preview renderer does not branch on
chat-vs-run mode in v1; this is documented honestly rather than
papered over. Workaround: keep cache-sensitive workflows inside one
`PtcRunner.SubAgent.run/2` invocation.

## Telemetry

Every tool-call telemetry event in combined mode carries an
`exposure_layer` field:

- `exposure_layer: :native` — the call came in via the provider's
  native tool calling.
- `exposure_layer: :ptc_lisp` — the call came from inside a
  `ptc_lisp_execute` program (a `(tool/name ...)` invocation).

Use `exposure_layer` to debug cache reuse and budget consumption — it
is the field that tells "tool was called from chat" apart from "tool
was called from inside a program." Other useful fields on the same
events: `cached`, `result_preview_truncated`, `full_result_cached`,
`cache_key_hash`, `retained_bytes`.

See [Observability](subagent-observability.md) for the broader
telemetry surface.

## Resource policy and memory risk

Concrete v1 invariants for retained native results:

- `tool_cache` lives for the duration of one
  `PtcRunner.SubAgent.run/2` call.
- **No cross-run persistence.** `tool_cache` does not survive across
  `chat/3` turns in v1.
- **No eviction during a run.** Full results stay in `tool_cache` until
  the run terminates. There is no LRU, no size-based eviction, no TTL.

Very large retained results consume runtime memory for the entire run.
Mitigation:

- Filter eagerly inside `ptc_lisp_execute` and return only the
  projection your program needs. The full result remains cached for
  later programs in the same run, but the program's own variables are
  scoped — keep them small.
- Don't cache tools that return arbitrarily large blobs unless callers
  will actually reuse the result.
- Use `preview: :metadata` (the default) so previews don't carry rows
  themselves.

Configurable resource limits (`tool_cache_limit`, per-tool
`max_cached_bytes`, eviction strategies, memory accounting) are
deferred to follow-up work — see "Known limitations" below.

## Known limitations / deferred

The following behaviors are deferred from v1 and documented for honesty:

- **No `*1`/`*2`/`*3` integration with native tool results.** Only
  successful non-terminal `ptc_lisp_execute` programs advance
  `turn_history`. Native call results don't feed `*1` references.
- **No richer `ChatState` API.** `tool_cache`, `journal`,
  `turn_history`, retained child-execution state do not thread across
  `chat/3` turns.
- **No cross-`chat/3`-turn compaction.**
- **No automatic journal breadcrumbs** for native large-result tool
  calls. The cache hint in the tool-result content is the only
  cross-turn signal.
- **No configurable resource limits** (`tool_cache_limit`,
  per-tool `max_cached_bytes`, eviction).
- **No short-circuit on `(return v)` matching a signature** — combined
  mode is deliberately the permissive shape; use `output: :ptc_lisp,
  ptc_transport: :tool_call` for short-circuit semantics.
- **`ptc_reference: :full`** raises `ArgumentError` in v1.

Edge cases pinned for transparency (most users won't hit these):

- **`-0.0` collapses to `0`** in canonical cache keys. Harmless for
  cache identity, diverges from JSON's strict equality.
- **NaN / Infinity floats** pass through cache keys unchanged. BEAM
  arithmetic doesn't produce them; foreign NIFs could.
- **Charlist (`'abc'`) vs binary (`"abc"`)** cache identity is not
  unified — they hash to different keys.
- **Atom + string key collision in the same map** silently overwrites
  during preview rendering. Avoid mixing key types in tool results.
- **Decimal/DateTime values inside cache key args** are not fully
  canonicalized; they pass through the catch-all clause.
- **`false` values in metadata previews** can collapse to `null` via a
  `||` short-circuit in the preview builder. Affects display only —
  cache identity is unaffected.

## Migration / breaking changes

Combined mode is **opt-in**. No defaults flipped. Pure `output: :text`
behavior is unchanged. Pure `output: :ptc_lisp` (any `ptc_transport`)
is unchanged. The validator continues to reject
`output: :text, ptc_transport: :content` (nonsensical: text mode has
no fenced PTC-Lisp parsing path).

The one thing existing PTC-Lisp users may notice is the deliberate
cache-key widening from the `KeyNormalizer.canonical_cache_key/2`
migration — see "The cache bridge → Cache-key migration wart" above
and the CHANGELOG.

## See also

- [Getting Started](subagent-getting-started.md) — basic SubAgent usage
- [Text Mode](subagent-text-mode.md) — pure `output: :text` (no
  combined mode)
- [PTC-Lisp Transport](subagent-ptc-transport.md) —
  `output: :ptc_lisp` with `:content` vs `:tool_call`
- [Observability](subagent-observability.md) — telemetry surface
  including `exposure_layer`
- [PTC-Lisp Specification](../ptc-lisp-specification.md) — language
  reference for programs run inside `ptc_lisp_execute`
- `PtcRunner.SubAgent.new/1` — full agent options reference
- `PtcRunner.SubAgent.run/2` — runtime options
- `PtcRunner.PtcToolProtocol` — `ptc_lisp_execute` description and
  response renderers
- `PtcRunner.SubAgent.Exposure` — exposure resolution and filtering
  helpers
- `PtcRunner.SubAgent.Loop.NativePreview` — native result preview
  builder
