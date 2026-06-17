# Plan: `describe` Data Profiling and `json/parse-lines`

## Context

The PTC-session benchmark ablation showed that medium guidance improved
mechanics but not finding quality. The remaining misses were mostly
unknown-unknowns: absent fields, unexpected value types, non-empty limit
signals, and shape anomalies that a coding agent often notices with broad
file/Python inspection.

This plan adds two domain-blind language capabilities:

- `describe`: bounded data-shape profiling and drill-down.
- `json/parse-lines`: JSONL parsing helper.

The goal is not to add benchmark-specific `log/` helpers or prompt vocabulary.
The goal is to make broad structural inspection cheap inside ordinary PTC-Lisp.

## Terminology

This plan uses the benchmark shorthand from the comparison notes in
`/Users/andreasronge/ptc-bench-comparison/notes/skill-ablation-results-2026-06-11.md`:

- **W-class findings** are direct waste patterns, such as repeated upstream
  fetches, repeated schema discovery, argument-name mistakes, stringly typed
  arithmetic, and discarded printed output. Agents find these by asking
  targeted questions about known behavior.
- **F-class findings** are structural/negative-space findings, such as missing
  failure details in projected records, catalog operations not appearing in the
  same place as upstream calls, heap/limit signals hiding in broad structure,
  and unexpected key/value shapes. Agents tend to miss these unless they first
  profile the data shape broadly.

The labels are benchmark-analysis shorthand only. The proposed implementation
must stay domain-blind and should not encode W/F vocabulary in prompts or
runtime behavior.

## Goals

1. Add a generic `describe` builtin that summarizes maps, collections, scalar
   values, map-key types, nested paths, examples, and type coverage.
2. Add `json/parse-lines` for line-delimited JSON.
3. When `lisp_session_eval` truncates a result or feedback, include a short
   recovery hint pointing to `(describe *1)`.
4. Keep prompt additions short enough to satisfy existing prompt budget tests.
5. Keep all examples domain-blind.

## Non-Goals

- No observatory-specific helpers.
- No turn-log-specific helpers.
- No report-writing helper in this change.
- No automatic full `describe` execution on every truncated value.
- No prompt text that mentions benchmarks, seeds, findings, or expected answer
  patterns.

## User-Facing API

### `describe`

```clojure
(describe x)
(describe x {:depth 2})
(describe x {:paths true :depth 3})
(describe x {:sample 3})
```

Do not add a `desc` alias. `:desc` is already used as a sort-direction keyword
(`:asc` / `:desc`), and a builtin named `desc` would create avoidable LLM
confusion in sort-heavy analysis code. This is a 0.x library; ship one clear
name.

Default behavior should be small and safe:

- bounded output;
- deterministic ordering;
- no traversal of huge structures beyond configured caps;
- no exception for ordinary mixed data.

### `json/parse-lines`

```clojure
(json/parse-lines text)
```

Default behavior:

- split on newlines;
- skip blank/whitespace-only lines;
- parse each remaining line with existing `json/parse-string`;
- return a vector;
- bad lines parse to `nil`, matching `json/parse-string` behavior.

Document the ambiguity explicitly: a malformed line and a valid JSON literal
`null` line both yield `nil`. Consistency with `json/parse-string` is more
important than inventing a separate error channel for v1.

Do not add options in the first pass unless implementation makes them trivial.
The one-arity helper solves the repeated JSONL boilerplate.

## `describe` Output Shape

The exact map shape can evolve, but v1 should be stable enough for LLM use and
tests.

### Scalar

```clojure
(describe "42")
;; =>
{:type "string"
 :string {:length 2 :numeric true}
 :sample "42"}
```

### Map

```clojure
(describe {"a" 1 "b" nil})
;; =>
{:type "map"
 :count 2
 :key_types {"string" 2}
 :keys {"a" {:types {"integer" 1} :examples [1]}
        "b" {:types {"nil" 1} :examples [nil]}}}
```

For a single map, do not emit `:present 1` / `:pct 100.0` for every key. That
is degenerate noise. Reserve presence percentages for collections of maps.

### Collection of Maps

```clojure
(describe [{"event" "turn" "fail" nil}
           {"event" "turn" "fail" {"reason" "runtime_error"}}])
;; =>
{:type "vector"
 :count 2       ; real root collection size
 :scanned 2     ; number of root items profiled
 :item_types {"map" 2}
 :keys {"event" {:present 2 :pct 100.0 :types {"string" 2}
                 :distinct_count 1 :examples ["turn"]}
        "fail" {:present 2 :pct 100.0 :types {"nil" 1 "map" 1}}}
 :key_types {"string" 4}}
```

### Nested Paths

```clojure
(describe rows {:paths true :depth 3})
;; =>
{:type "vector"
 :count 56
 :scanned 56
 :paths {"data.tool_calls" {:present 56 :pct 100.0
                            :types {"vector" 56}
                            :non_empty 40}
         "data.limits_hit" {:present 56 :pct 100.0
                            :types {"vector" 56}
                            :non_empty 2}}}
```

Path summaries should include:

- `present`: number of root items where the path exists;
- `pct`: percentage of root items;
- `types`: value type histogram;
- `non_empty`: for lists/maps/sets/strings;
- `distinct_count` and small `examples` for scalar fields;
- numeric range for numbers and optionally numeric-looking strings.

Percentages are over `:scanned`, not necessarily `:count`. Always include both
when describing a collection so sampled summaries are not mistaken for global
truth.

Three output details tests will need pinned:

- Numeric range uses `:range {:min 1 :max 99}` on the field summary, for
  numeric fields and (when detected) numeric-looking strings.
- Distinct tracking is memory-capped: track at most 50 distinct values per
  field; past the cap emit `:distinct_count 50 :distinct_capped true`.
- Map keys shown in `:keys` summaries render through the same 120-char example
  formatting cap (huge string keys must not blow the envelope). Non-string key
  *types* (vectors, maps) are preserved as-is in `:key_types` — unusual key
  types are exactly what the profiler exists to surface.

## Type Names

Use simple, stable strings:

- `"nil"`
- `"boolean"`
- `"integer"`
- `"float"`
- `"string"`
- `"keyword"`
- `"vector"`
- `"list"`
- `"map"`
- `"set"`
- `"function"`
- `"nan"` and `"infinity"` for IEEE 754 specials (`:nan`, `:infinity`,
  `:negative_infinity` — see `PtcRunner.Lisp.Runtime.SpecialValues`). These
  must not classify as `"keyword"` even though they are atoms internally, and
  they are excluded from `:range`. Use `"infinity"` for both signs.
- fallback: a safe inspected type name

There is no `"error"` type. PTC-Lisp has no in-band error/signal struct:
recoverable signals are ordinary values (`nil`, `""`, `false`, empty
collections — specification rules 1 and 4), and program errors raise and
terminate the eval before `describe` could see them as input. Upstream tool
failures are plain maps (`{:ok false :message ...}`) and are profiled as
ordinary maps — no special-casing.

Numeric-string detection should be bounded. Only test strings up to 64
characters, so large blobs are not scanned as candidate numbers.

## Bounds

`describe` must be safe for untrusted/big values.

Suggested defaults:

- max root items inspected: 1,000;
- max map keys summarized per object: 100;
- max paths: 300;
- max examples per field: 3;
- max example printable chars: 120;
- default depth: 1;
- explicit max depth: 5;
- output should remain below session/profile envelope caps in normal use.

If input exceeds traversal caps, include metadata:

```clojure
{:truncated true
 :caps_hit ["max_items" "max_paths"]}
```

Use `:caps_hit`, not `:limits_hit`. `limits_hit` is already a PTC turn-log
field for sandbox/runtime limit events; reusing it inside the profiler would
confuse agents profiling PTC's own logs.

## Truncation Hint

Do not auto-run a full profile for every truncated result. That could increase
cost and surprise users.

Instead, when `lisp_session_eval` response shaping reports truncation, append a
short hint to feedback or the concise text response:

```text
Result truncated. Try `(describe *1)` or `(describe *1 {:paths true :depth 2})`.
```

This is local, domain-blind guidance triggered exactly when useful.

If implementation can cheaply derive a tiny shape without traversing the full
value, it may also include a minimal `shape` field:

```elixir
%{"shape" => %{"type" => "vector", "count" => 1000, "item_types" => %{"map" => 1000}}}
```

That `shape` field is optional for v1. The hint is required.

## Prompt Changes

Prompt budget constraints:

- `mcp_server/test/ptc_runner_mcp/prompt_files_test.exs` enforces each prompt
  file's `hard<=... bytes` metadata.
- `mcp_server/test/ptc_runner_mcp/prompt_registry_test.exs` enforces rendered
  MCP tool descriptions under 2,000 bytes.
- `mcp_server/priv/prompts/tools/lisp_session_eval.with_upstreams.md` currently
  has `hard<=2000 bytes`.

Keep prompt edits minimal. Prefer replacing existing text over adding lines.

Recommended edit in `mcp_server/priv/prompts/reference.md`:

Current:

```text
- Inspect shapes with `println`, `pr-str`, `keys`.
```

Replace with:

```text
- Inspect shapes with `describe`, `keys`, `pr-str`; JSONL: `json/parse-lines`.
```

Recommended edit in `mcp_server/priv/prompts/tools/lisp_session_eval.with_upstreams.md`:

Current:

```text
Unknown result shape: inspect `(keys (:value r))` or `(pr-str (:value r))`; use `(fail (:message r))` for unhandled faults.
```

Replace with:

```text
Unknown/truncated shape: use `(describe value)` or `(describe value {:paths true :depth 2})`; use `(fail (:message r))` for unhandled faults.
```

The same line exists in
`mcp_server/priv/prompts/tools/lisp_eval.with_upstreams.md` (line 22, the
stateless tool). Apply the same replacement there — the replacement text
already avoids `*1`, so it is valid for the stateless tool too.

If this pushes rendered descriptions over budget, remove or shorten lower-value
phrasing, e.g.:

- remove "`:raw` optional";
- shorten "Discovery inspects upstream schemas only" sentence;
- shorten `output_schema` wording.

Do not add benchmark-specific examples.

## Implementation Areas

### Runtime Builtins

Likely files:

- `lib/ptc_runner/lisp/runtime/json.ex`
- `lib/ptc_runner/lisp/runtime/builtins.ex`
- `lib/ptc_runner/lisp/builtin_names.ex`
- `priv/functions.exs`
- `docs/ptc-lisp-specification.md` (hand-edited)

Do **not** hand-edit `docs/function-reference.md` — it is generated. Add the
new entries to `priv/functions.exs`, then run `mix ptc.gen_docs` to regenerate
the function reference (and conformance index). If `mix ptc.validate_spec`
flags the specification edit, run `mix ptc.update_spec_checksums`.

Add:

- `json/parse-lines`
- `describe`

Confirm exact registration path before editing; follow existing runtime builtin
patterns.

### `describe` Implementation

Prefer a dedicated module, for example:

```text
lib/ptc_runner/lisp/runtime/describe.ex
```

Responsibilities:

- normalize options;
- classify types;
- summarize scalar/map/collection;
- traverse nested paths with caps;
- render examples using existing safe formatting utilities;
- return plain PTC data structures only.

Do not depend on MCP/session modules from core runtime.

### Session Truncation Hint

Likely area:

- `mcp_server/lib/ptc_runner_mcp/sessions/projection.ex`
- envelope/output shaping modules if truncation is handled later

Find the point where `execution.truncated` becomes true and append the hint to
feedback/text once. Avoid repeating the same line multiple times.

The hint should apply only to session evals because `*1` is a session history
feature. For stateless `lisp_eval`, either omit the hint or say only
`Use (describe value) on a smaller projection`.

## Tests

### `json/parse-lines`

Add tests for:

- multiple JSON objects;
- blank lines skipped;
- arrays/scalars are accepted per line;
- invalid line behavior matches `json/parse-string`;
- malformed line and literal `null` line both produce `nil`, and docs call out
  that ambiguity;
- one-arity only, if options are not implemented.

### `describe`

Add focused runtime tests:

- scalar summaries;
- map key type summaries;
- single-map summaries omit degenerate `:present` / `:pct`;
- vector/list of maps key coverage;
- mixed item types;
- nested `:paths true` summaries;
- collection summaries include both `:count` and `:scanned`;
- `non_empty` counts;
- numeric range and numeric-string detection bounded to strings <= 64 chars;
- examples are bounded;
- traversal caps set `:truncated` / `:caps_hit`;
- `:nan` / `:infinity` / `:negative_infinity` classify as `"nan"` /
  `"infinity"`, never `"keyword"`, and `:range` ignores non-finite values;
- no `desc` builtin or alias is registered.

### Session Hint

Add MCP/session tests for:

- a truncated `lisp_session_eval` response includes the `(describe *1)` hint;
- a non-truncated response does not include the hint;
- hint appears once even when both result and feedback truncate;
- rendered response still respects profile/envelope caps.

### Prompt Budgets

Run:

```bash
cd mcp_server
mix test test/ptc_runner_mcp/prompt_files_test.exs test/ptc_runner_mcp/prompt_registry_test.exs
```

If prompt changes are made, also recompile because prompt templates are compiled
in:

```bash
cd mcp_server
mix compile
```

## Verification

Targeted checks:

```bash
mix test test/ptc_runner_mcp/prompt_files_test.exs \
         test/ptc_runner_mcp/prompt_registry_test.exs
```

Core/runtime tests should be run from the repo root or relevant Mix project
depending on where existing Lisp runtime tests live.

Before committing, run the repo gate:

```bash
mix precommit
```

## Sequencing and Rollout Experiment

Build this capability regardless of the parity outcome. `json/parse-lines`
closes a measured JSONL boilerplate gap, and `describe` is a general
medium-parity feature with Python's `df.info()` / `df.describe()` style
inspection. The parity runs change what we expect the benchmark rollout to
show; they do not decide whether the capability belongs in the language.

Before or alongside the rollout, complete the model/medium parity cells:

| Lane | Sonnet | Opus |
|---|---|---|
| PTC guided | done | run next |
| normal file/shell tools | run next | done |

The weak-model checks sharpened this need: Haiku with Bash/Read/Write still
missed all F-class findings, and Codex mini also missed them. So broad file
affordance alone is not sufficient at weak model strength; the F-class may be
model-gated. Without the Sonnet-over-files and Opus-over-PTC cells, a null
`describe` rollout would be ambiguous.

After implementation, rerun the strict PTC guided condition without adding any
benchmark-specific prompt text:

- Sonnet guided, n=3 if budget allows;
- Opus guided, n=1-2 if budget allows;
- Haiku guided smoke, n=1;
- compare F-class movement, especially F1/F3/F4.

Expected signal:

- fewer inspect/re-fetch detours after truncation;
- reports mention shape/absence findings with measured evidence;
- F-class hit rate improves if missing structure was the blocker.

If F-class does not improve, the bottleneck is likely model strategy rather
than missing generic data introspection.
