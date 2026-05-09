# JSON Support for PTC-Lisp & MCP Aggregator — Specification

| Field | Value |
|---|---|
| Status | Draft |
| Target packages | `:ptc_runner` (PTC-Lisp builtins), `:ptc_runner_mcp` (helpers, auto-decode) |
| Depends on | `ptc-runner-mcp-aggregator.md` |
| Last revised | 2026-05-09 |

This document specifies JSON-handling support for PTC-Lisp programs and
the MCP aggregator. It addresses the concrete friction observed when
upstream MCP servers return JSON inside `content[0].text` (e.g.
`mem.read_graph`), forcing generated programs to fall back to string
regex to split entities from relations.

Sections using **MUST** / **SHOULD** / **MAY** carry RFC 2119 normative
weight.

## 1. Scope and Goals

The work delivers three complementary, layered pieces:

1. **JSON primitives in PTC-Lisp** — `json/parse-string` and
   `json/generate-string` builtins matching Cheshire's signatures.
2. **MCP unwrap helpers** — `mcp/text` and `mcp/json` so programs
   stop hand-coding `(get-in result ["content" 0 "text"])`.
3. **Conservative auto-decode at the aggregator boundary** — promote
   parsed JSON into `structuredContent` only when the upstream
   declares `mimeType: "application/json"`.

Goals:

1. Eliminate the string-regex workaround for JSON-as-text MCP results
   without requiring per-upstream registry entries.
2. Keep PTC-Lisp's "no try/catch in the sandbox" invariant: parsing
   failures **MUST NOT** raise — they return `nil` (DIV-* convention,
   see CLAUDE.md).
3. Match Clojure / Cheshire naming so LLM-generated code is natural
   without prompt hints (Domain-Blind Prompts rule).
4. Stay opt-in at the aggregator: programs that want the raw envelope
   still get it; auto-decode only fires on explicit upstream signal.

## 2. Definitions

| Term | Meaning |
|---|---|
| Text content item | An MCP `content[]` entry where `"type" == "text"`. Carries `"text" :: String.t()` and optional `"mimeType" :: String.t()`. |
| JSON-as-text | A text content item whose `"text"` is a JSON document. |
| Structured content | The MCP `result.structuredContent` field — the spec-blessed channel for typed JSON. |
| DIV-* convention | PTC-Lisp's deliberate divergence from Clojure: where Clojure raises, PTC-Lisp returns a signal value (`nil`/`""`/`false`). See `docs/clojure-conformance-gaps.md`. |

## 3. Non-Goals

- A streaming JSON parser. `json/parse-string` operates on whole
  strings.
- JSONL/file I/O builtins. Tracked separately; out of scope here.
- A `jq` or JSONPath query builtin. The PTC-Lisp threading + `get-in`
  combo covers this idiomatically once values are parsed.
- Per-upstream "well-known content shapes" registry. Rejected in §6.3.
- Heuristic auto-decode based on leading `{` / `[`. Rejected in §6.3.
- Custom encoders for non-JSON-native values (atoms, tuples, structs)
  beyond what PTC-Lisp already round-trips.

## 4. PTC-Lisp Builtins

### 4.1 `json/parse-string`

```
(json/parse-string s) -> value | nil
```

- **Signature**: `String.t() -> term() | nil`
- **Returns**: the parsed value on success; `nil` on any of:
  - input is `nil`
  - input is not a binary
  - input is not valid JSON
- **Map keys**: parsed objects use **string keys** (no atom keys).
  This matches PTC-Lisp's tool-boundary convention
  (`docs/signature-syntax.md:339`) and prevents atom memory leaks.
- **Numbers**: JSON integers parse to Elixir integers, floats to
  Elixir floats. No bigint promotion beyond what `Jason` provides.
- **Failure mode**: **MUST NOT** raise. The DIV-* convention applies:
  no try/catch in the sandbox means a raise is unrecoverable.
- **Argument arity**: 1-arity only in v1. No second-arg
  `keywordize-keys` flag (the LLM converts via `walk` if needed and
  string keys are the documented norm).

#### 4.1.1 Examples

```clojure
(json/parse-string "{\"a\": 1, \"b\": [2, 3]}")
;; => {"a" 1, "b" [2 3]}

(json/parse-string "[1, 2, 3]")
;; => [1 2 3]

(json/parse-string "null")
;; => nil

(json/parse-string "not json")
;; => nil

(json/parse-string nil)
;; => nil
```

> **Ambiguity note.** `(json/parse-string "null")` and a parse failure
> both return `nil`. v1 does not surface a separate parse-error
> sentinel; this is captured as Open Question OQ-1 (§9). Programs that
> need to distinguish them **SHOULD** guard on `(empty? s)` / shape
> before calling. Note that `mcp/json` (§5.2) collapses *both* failures
> AND the JSON-null case to `nil` — it is **not** a way to recover the
> distinction. See §6.2 for a worked example showing how `:json-null`
> propagates differently through the top-level §7.3 rewrite vs the
> auto-decode `structuredContent` path.

### 4.2 `json/generate-string`

```
(json/generate-string v) -> String.t() | nil
```

- **Signature**: `term() -> String.t() | nil`
- **Returns**: a JSON-encoded string on success; `nil` if the value
  contains anything `Jason` cannot encode (PIDs, references, atoms
  outside `true`/`false`/`nil`, tuples, functions).
- **Atoms**: `true` / `false` / `nil` encode as JSON `true` / `false`
  / `null`. Other atoms (including PTC-Lisp keywords like `:fs`) are
  **not** auto-stringified — they fail the encode and produce `nil`.
  Programs that want atom keys or values serialized **SHOULD** convert
  with `name`/`str` first.
- **Map key types**: **string and integer keys only.** Integer keys
  stringify, matching `Jason`'s default. **All other key types —
  atoms (including `true` / `false` / `nil`), floats, tuples, etc. —
  produce `nil`.** This is stricter than the value rule because JSON
  itself only accepts string keys; once stringified, atom and float
  keys preserve no type signal across the round-trip and would break
  §4.3's round-trip property. The pre-validation sketch in §4.4
  encodes this asymmetry explicitly via separate
  `encodable_key?`/`encodable_value?` predicates.
- **Encoder pre-validation is required.** Vanilla `Jason.encode/1`
  silently encodes non-boolean atoms as JSON strings (e.g. `:fs` →
  `"fs"`). PTC-Lisp's `json/generate-string` deliberately diverges
  from this default: §4.4 mandates a pre-validation walk that
  inspects the value tree and short-circuits to `nil` on any
  non-boolean atom, atom-keyed map, tuple, PID, reference, or
  function. Only after that walk passes does the implementation hand
  the value to `Jason.encode/1`. Implementations that just wrap
  `Jason.encode/1` will silently encode where the spec requires
  rejection — that is a bug.
- **Failure mode**: **MUST NOT** raise.
- **Pretty-printing**: not exposed in v1. Output is compact.

#### 4.2.1 Examples

```clojure
(json/generate-string {"a" 1, "b" [2 3]})
;; => "{\"a\":1,\"b\":[2,3]}"

(json/generate-string nil)
;; => "null"

;; Keyword keys / values are NOT encodable. PTC-Lisp keywords are
;; atoms outside {true, false, nil}, so they fail and the call
;; returns nil. Convert with `name` / `str` first if the wire
;; format requires strings.
(json/generate-string {:server "fs"})
;; => nil       ; keyword key not encodable

(json/generate-string {"server" :fs})
;; => nil       ; keyword value not encodable

(json/generate-string {"server" (name :fs)})
;; => "{\"server\":\"fs\"}"
```

The "non-encodable atom → `nil`" behavior is intentional: silently
auto-stringifying keywords would erode PTC-Lisp's type signal at the
wire boundary. Programs that need strings on the wire **MUST** convert
explicitly. Doctests on `Runtime.Json.generate_string/1` cover the
keyword case specifically (per §4.4 / §8).

### 4.3 Round-trip property

For all values `v` whose shape is JSON-native (string keys, JSON
scalars, lists/maps recursively), the following **MUST** hold:

```clojure
(= v (json/parse-string (json/generate-string v)))
```

This is the contract programs rely on. Any divergence is a bug.

### 4.4 Implementation notes

- **Unconditional registration for both `json/*` and `mcp/*`.**
  `json/parse-string`, `json/generate-string`, `mcp/text`, and
  `mcp/json` all live in `:ptc_runner` proper and are available in
  **every** PTC-Lisp run — default mode, aggregator mode, in-process
  callers via `PtcRunner.SubAgent`, everything. They are pure
  functions on binaries / parsed values, no side effects, no
  upstream dependency, no analyzer profile awareness required.
  §5.5 explains the placement rationale for `mcp/*` (which would
  otherwise want gating); the four steps below cover both
  namespaces in one coordinated change.
- Live alongside `parse-long` / `parse-double` in
  `lib/ptc_runner/lisp/runtime/`. A new `runtime/json.ex` is
  appropriate; `string.ex` is already long.
- **Four coordinated registration steps** — all required, missing
  any one leaves the new builtins uncallable or breaks the registry
  sync test:

  1. **Analyzer namespace allowlist.** PTC-Lisp's analyzer recognizes
     slash forms (`json/parse-string`) as namespace symbols and
     rejects namespaces not in its allowlist (existing entries:
     `tool/`, `data/`, `clojure.string/`, etc.). Add **both `json/`
     and `mcp/`** to that allowlist in the same change — both are
     unconditional base builtins per §5.5, so the allowlist must
     accept them in default mode and aggregator mode alike. (Phase
     3 / aggregator §3 forbids *new analyzer passes* but allowlist
     additions are mechanical and do not introduce new semantics —
     the existing slash-form handling is reused.)
  2. **Env registration.** Add to `lib/ptc_runner/lisp/env.ex` next
     to the other `:"parse-..."` entries — **all four forms in the
     same change**:
     ```elixir
     # JSON builtins (§4)
     {:"json/parse-string", {:normal, &Runtime.Json.parse_string/1}},
     {:"json/generate-string", {:normal, &Runtime.Json.generate_string/1}},
     # MCP unwrap helpers (§5)
     {:"mcp/text", {:normal, &Runtime.Mcp.text/1}},
     {:"mcp/json", {:normal, &Runtime.Mcp.json/1}},
     ```
  3. **Function registry sync.** `RegistryTest` asserts every
     `Env.initial()` builtin is present in `priv/functions.exs` (the
     metadata source for `Registry.doc/1` and catalog rendering).
     Add matching entries for **all four** new forms — name, arity,
     namespace, one-line description, and any optional fields the
     existing `parse-*` entries use. Without this step the new
     builtins are undiscoverable via `Registry.doc` and the test
     suite fails.
  4. **Namespaced dispatch.** Resolve OQ-5 (§9): allowlist + Env
     entries alone are NOT sufficient because
     `normalize_clojure_namespace/3` currently dispatches the
     unqualified atom (`:"parse-string"`), not the namespace-
     qualified key (`:"json/parse-string"`). The implementer
     **MUST** pick one of OQ-5's options (per-namespace lookup
     tables, or full namespaced atom dispatch) and wire all four
     of `(json/parse-string ...)`, `(json/generate-string ...)`,
     `(mcp/text ...)`, `(mcp/json ...)` to evaluate without
     "unknown namespace" or "unbound function" errors. ExUnit
     coverage on all four is a hard gate per OQ-5.
- Internally wrap `Jason.decode/1` and `Jason.encode/1` with a
  `case`/`rescue` boundary so neither raises into the sandbox.
- **For `generate_string/1`, run a pre-validation walk before
  invoking `Jason.encode/1`.** The walk recursively inspects the
  value tree; on any non-encodable term — atoms outside
  `{true, false, nil}`, atom-keyed map entries, tuples (Jason
  rejects these but raises an explicit error rather than encoding),
  PIDs, references, functions — return `nil` immediately. Only when
  the walk completes does the implementation hand the value to
  `Jason.encode/1`. This is the single non-obvious step that
  divergences from "just wrap Jason.encode/1" — see §4.2 rationale
  ("erodes PTC-Lisp's type signal").
  ```elixir
  # Sketch of the pre-validation contract.
  # Note: map-key validation is STRICTER than value validation —
  # JSON only accepts string/integer keys, so booleans, nil, floats,
  # and atoms (other than via the encodable_value? bool/nil rule)
  # are rejected as keys even when they would be acceptable as values.
  defp encodable_value?(v) when is_atom(v), do: v in [true, false, nil]
  defp encodable_value?(v) when is_binary(v) or is_number(v), do: true
  defp encodable_value?(v) when is_list(v), do: Enum.all?(v, &encodable_value?/1)
  defp encodable_value?(v) when is_map(v) do
    Enum.all?(v, fn {k, val} ->
      encodable_key?(k) and encodable_value?(val)
    end)
  end
  defp encodable_value?(_), do: false

  # Map keys: strings and integers only. Floats stringify
  # ambiguously; atoms — including true/false/nil — preserve no
  # type signal once stringified, so all are rejected at the key
  # position even though they may appear elsewhere.
  defp encodable_key?(k) when is_binary(k) or is_integer(k), do: true
  defp encodable_key?(_), do: false
  ```
  ExUnit tests **MUST** cover the keyword-key, keyword-value, tuple,
  and PID cases explicitly (per §8 testing requirements).
- Add the entries to `docs/function-reference.md` under a new `JSON`
  section, sorted alphabetically with the other namespaced builtins.
- Update `docs/ptc-lisp-specification.md` with a short subsection
  cross-linking the function reference. Per CLAUDE.md
  ("when you find issues, fix both the code and the docs together")
  the docs land in the same PR.

## 5. MCP Unwrap Helpers

These helpers wrap the well-known MCP result envelope so programs
stop hand-coding `get-in` chains. **Registration is unconditional**
— they live in `:ptc_runner`'s `Env.initial()` alongside `json/*`,
available in default mode and aggregator mode alike. See §5.5 for
the rationale (no env extension hook for normal builtins exists
today, the analyzer is not profile-aware, and the helpers are
harmless against non-MCP-shaped maps — they just return `nil`).

### 5.1 `mcp/text`

```
(mcp/text result) -> String.t() | nil
```

- Returns `result["content"][0]["text"]` when:
  - `result` is a map,
  - `result["content"]` is a non-empty list,
  - the first item is a map with `"type" == "text"`,
  - the first item has a binary `"text"` field.
- Returns `nil` in all other shapes (including `nil` input, the
  `:json-null` sentinel, and lists where item 0 is non-text).
- **MUST NOT** raise. **MUST NOT** scan past index 0 — programs that
  need later items use `get-in` directly. (Index 0 covers the observed
  cases; broadening is a future change once a counterexample appears.)

### 5.1.1 What `mcp/text` does *not* cover

`mcp/text` returns `content[0]["text"]` only. Real upstreams sometimes
return multiple text items in a single response — `fs.read_multiple_files`
is a concrete present-day counterexample, returning one text item per
file in `content[]`. Programs that need to reach later items handle
them explicitly:

```clojure
;; Multi-text upstream result (e.g. fs.read_multiple_files):
(def result (tool/mcp-call {:server "fs"
                            :tool "read_multiple_files"
                            :args {:paths ["a.txt" "b.txt" "c.txt"]}}))
(def all-texts (map #(get % "text") (get result "content")))
;; => ["contents of a.txt" "contents of b.txt" "contents of c.txt"]
```

The capped `mcp/text` covers the dominant case (single text item per
result) without trying to be clever. Broadening to a multi-item helper
(`mcp/all-text`) is captured as OQ-4 (§9); for v1 the explicit `(map
#(get % "text") (get result "content"))` form is the recommended path
and is included in `docs/aggregator-mode.md`'s example library.

### 5.2 `mcp/json`

```
(mcp/json result) -> term() | nil
```

- Equivalent to `(json/parse-string (mcp/text result))`.
- Single helper for the dominant case: "the upstream stuffed a JSON
  document into the first text item."
- Returns `nil` if `mcp/text` returns `nil`, *or* if the extracted
  text isn't valid JSON. The two failures are not distinguished
  (OQ-1).

### 5.3 Examples

```clojure
;; Before: regex split workaround
(def raw (tool/mcp-call {:server "mem" :tool "read_graph" :args {}}))
(def text (get-in raw ["content" 0 "text"]))
(def entities-section (re-find #"(?s)entities:.*?(?=relations:)" text))
;; ... fragile string slicing ...

;; After: direct parse
(def graph (mcp/json (tool/mcp-call {:server "mem"
                                     :tool "read_graph"
                                     :args {}})))
(def entities (get graph "entities"))
(def relations (get graph "relations"))
```

### 5.4 Naming and namespace

The helpers live in the `mcp/` namespace. Prior art:
`ptc-runner-mcp-aggregator.md` §3 lists "a new `mcp/<server>` PTC-Lisp
namespace syntax" as a non-goal — that referred to *per-server tool
forms* (e.g. `mcp/github/search_repos`), not general aggregator-side
helpers. The two uses do not collide: helpers occupy
`mcp/{text,json,...}`, leaving `mcp/<server>/<tool>` available if it
is ever resurrected.

If a future change resurrects the per-server syntax, helpers
**SHOULD** move to `mcp.util/` rather than be renamed away from
`mcp/`. This is captured as OQ-2.

### 5.5 Implementation notes

- New module **in `:ptc_runner`** (e.g.,
  `lib/ptc_runner/lisp/runtime/mcp.ex`) — NOT in `:ptc_runner_mcp`.
  Placement matters: `:ptc_runner_mcp` already depends on
  `:ptc_runner`, so putting the helpers in the MCP package and then
  registering them via `:ptc_runner`'s `Env.initial()` would invert
  the dependency direction. The helpers themselves are pure shape
  inspectors with no MCP-protocol dependency; they belong in the
  base library.
- Helpers are pure functions on parsed values — no side effects, no
  upstream calls — so they run inside the sandbox without lock or
  side-channel concerns.
- **Registration is unconditional.** The first revision of this spec
  proposed gating registration on `configured_aggregator_mode?/0`,
  but the existing aggregator hook only injects *virtual tools* via
  the `tools:` option to `tool/mcp-call`; there is no current
  env-extension hook for normal builtins, and the PTC-Lisp analyzer
  is not profile-aware. Adding either would be a bigger change
  than the helpers themselves justify. Since `mcp/text` and
  `mcp/json` are pure functions on parsed values that produce `nil`
  for non-MCP-shaped inputs, they are harmless in non-aggregator
  mode (they just always return `nil` against unrelated maps). Make
  them unconditional, registered alongside `json/*` in
  `:ptc_runner`'s `Env.initial()` and the function registry.
  This parallels OQ-3's resolution for the `json/*` builtins.

## 6. Aggregator Auto-Decode

### 6.1 Trigger

**Precondition.** Auto-decode is only invoked on values that have
already been classified as successful by `classify_value/1` (§7.1 /
Phase 4). `isError: true` envelopes never reach this stage — they
are intercepted upstream and surfaced to the program as `nil` plus
an `upstream_error` entry in `upstream_calls`. Implementations
**MUST NOT** call the auto-decode promotion on world-fault values;
the pipeline ordering in §6.4 makes this explicit.

Given a value that has passed classification, the aggregator **MAY**
promote JSON-as-text into `structuredContent` **iff** all of the
following hold:

1. `result["structuredContent"]` is absent or `nil`. (If the upstream
   already filled `structuredContent`, that wins — the aggregator
   never overrides.)
2. `result["content"]` is a list, and its first item is a text item
   (`"type" == "text"`).
3. The first item's `"mimeType"` is one of:
   - `"application/json"` (exact match), or
   - any string ending in `"+json"` (RFC 6839 structured suffix —
     covers `application/ld+json`, `application/vnd.foo+json`, etc.).
4. `Jason.decode/1` on `"text"` returns `{:ok, value}`.

When all four hold, the aggregator **MUST** add
`result["structuredContent"] = value` (with the §6.4 decoded-nil-to-
`:json-null` substitution) and pass the rest of the envelope through
unchanged. The original `content[]` is preserved — auto-decode is
*additive*, never destructive.

When any condition fails, the aggregator **MUST** pass the result
through unchanged. Programs can still use `mcp/json` to recover. The
former `isError`-not-true condition is **removed** from this list
because the upstream classify_value step already enforces it; keeping
it here would falsely imply that an unhandled `isError: true`
envelope is allowed to reach this point.

### 6.2 Interaction with §7.3 `:json-null` rewrite

The §7.3 top-level `:json-null` rewrite operates on the whole upstream
payload. Auto-decode is a *sub-field* promotion and runs before the
top-level rewrite check. A successful decode that produces JSON
`null` populates `structuredContent` with `:json-null` (so programs
get the same sentinel via either path), while the top-level envelope
remains a non-nil map and is not rewritten.

**Practical consequence — the two paths place `:json-null` differently.**
Programs that branch on `:json-null` need to look in the right place
depending on whether the upstream's *whole* result was JSON `null` or
just a *content text item* whose JSON decoded to `null`:

```clojure
;; Path A: upstream returned the whole result as JSON null.
;; Top-level §7.3 rewrite kicks in.
(def a (tool/mcp-call {...}))
;; a => :json-null
(= a :json-null)                              ;; => true
(get a "structuredContent")                   ;; n/a (a is not a map)

;; Path B: upstream returned a non-null map whose content[0].text
;; was the JSON literal "null" with mimeType "application/json".
;; Auto-decode promotes that into structuredContent.
(def b (tool/mcp-call {...}))
;; b => {"content" [{"text" "null" "type" "text" "mimeType" "application/json"}]
;;       "structuredContent" :json-null}
(= b :json-null)                              ;; => false  — outer is a map
(= (get b "structuredContent") :json-null)    ;; => true
```

Programs that compose across both shapes can normalize:
`(or (= result :json-null) (= (get result "structuredContent") :json-null))`.
`mcp/json` (§5.2) collapses both Path A and Path B to plain `nil` and
is the recommended entry point when the program just wants the parsed
value without caring about provenance.

### 6.3 What was rejected and why

- **Heuristic decode** (try-parse if text starts with `{` or `[`):
  rejected. False positives on natural-language text that happens to
  start with `{` are real, and once `mcp/json` exists the LLM has a
  clean explicit path. Reliability beats convenience.
- **Per-upstream registry** of "this tool returns JSON-as-text":
  rejected. Maintenance tax scales with every new upstream;
  generic `mcp/json` covers the same cases without server-specific
  configuration.
- **Recursive auto-decode** of nested text fields: rejected. Only the
  top-level `content[0]` is in scope. Nested cases are vanishingly
  rare and trivially handled by an explicit `json/parse-string` call.

### 6.4 Implementation notes

- **Pipeline order** (single source of truth — supersedes any
  earlier wording in §6.2 if they drift):
  ```
  upstream {:ok, value}
    └─ classify_value/1            # §7.1, Phase 4: world-fault on isError: true
        └─ auto-decode promotion   # §6 — runs HERE, while value is still a map
            └─ §7.3 :json-null     # top-level rewrite of the whole result
                └─ value handed to PTC-Lisp closure
  ```
  Auto-decode runs **after** classify_value's world-fault check (so
  `isError: true` still short-circuits to `nil` + `upstream_error`
  without decode side effects), and **before** the §7.3 top-level
  `:json-null` rewrite (so promotion operates on the upstream's
  original map, not on a `:json-null` keyword). §6.2's worked example
  is consistent with this ordering.
- **Decoded `nil` becomes `:json-null` in `structuredContent`.** When
  `Jason.decode/1` succeeds and the parsed value is Elixir `nil`
  (i.e., the `text` was the JSON literal `"null"`), the auto-decode
  step **MUST** substitute `:json-null` before assigning to
  `structuredContent`. This mirrors §7.3 at the sub-field level so
  programs reading via either path see the same sentinel for
  upstream-emitted JSON null. Without this rule, `structuredContent`
  would contain bare `nil`, indistinguishable from "field absent."
- The promotion lives in `aggregator_tools.ex` on the success branch
  of `:ok` classification (`aggregator_tools.ex:428` — the `case
  classify_value(value)` block).
- Decode **MUST NOT** raise. The `Jason.decode/1` call is wrapped;
  on `{:error, _}` the result passes through unchanged.
- Decoded value size is bounded by the existing
  `max_response_bytes` upstream cap — auto-decode does not amplify
  the payload because the original `content[]` is also retained.
  Telemetry (§7) records decoded byte size so operators can spot
  pathological growth.

## 7. Telemetry

A single new telemetry event:

```
[:ptc_runner_mcp, :upstream, :auto_decode, :stop]
```

Measurements (vary by outcome):

| Outcome | `decoded_bytes` | `text_bytes` |
|---|---|---|
| `:promoted` | byte size of `Jason.encode!(value)` on the promoted value (best-effort; round-trip failure suppresses the field but not the event) | n/a |
| `:already_structured` | `0` | n/a (the upstream provided `structuredContent` so no decode occurred) |
| `:decode_failed` | `0` | byte size of the rejected `text` (so operators can correlate failure size with the cap) |

Metadata (always present):
- `server`, `tool` — upstream identifiers.
- `mime_type` — the matched mimeType string.
- `outcome` — one of `:promoted`, `:already_structured`,
  `:decode_failed` (the three measurement-distinct cases above).

No telemetry event is emitted when no text-content item is present or
when the mimeType does not match — the volume would dwarf the signal.
The `:decode_failed` event always carries `text_bytes` so a
downstream consumer can disambiguate "Jason rejected" from "no event"
without resorting to count subtraction.

## 8. Testing Requirements

Builtins (`:ptc_runner`):

- ExUnit tests for `json/parse-string` and `json/generate-string`
  covering: valid input, invalid input, `nil` input, non-binary
  input, atom key encode failure, round-trip property.
- Doctests on `Runtime.Json.parse_string/1` and `generate_string/1`
  with full module paths per the CLAUDE.md doctest convention.
- One end-to-end PTC-Lisp test in
  `test/ptc_runner/lisp/eval_test.exs` exercising both forms in a
  realistic threaded pipeline.

Helpers (`:ptc_runner_mcp`):

- Unit tests for `mcp/text` and `mcp/json` against the well-formed
  envelope, malformed envelopes (missing `content`, non-text item 0,
  empty list, `nil` input).
- One e2e test using a stub upstream that returns
  `mem.read_graph`-shaped JSON-as-text, asserting the program can
  reach `entities`/`relations` without string parsing.

Auto-decode:

- Aggregator unit tests covering: mimeType match → promoted,
  mimeType absent → unchanged, `+json` suffix → promoted, malformed
  JSON with matching mimeType → unchanged + telemetry
  `:decode_failed`, `structuredContent` already present → unchanged
  + telemetry `:already_structured`. **Note:** the `isError: true`
  case is *not* tested here — auto-decode is never invoked on world-
  fault values per §6.1's precondition. The Phase 4 classify_value
  test (`aggregator_is_error_test.exs`) already covers that path.

Per CLAUDE.md "Bug fix workflow" — the regex-workaround case in the
existing program that motivated this spec **MUST** be captured as a
failing integration test before any code lands.

## 9. Open Questions

**OQ-1 — Distinguishing parse failure from JSON null.** v1 collapses
both to `nil`. If LLMs in practice need to distinguish, options are
(a) a second sentinel (`:"json-parse-error"`), (b) a 2-arity form
returning `[:ok value]` / `[:error reason]` tuples, or (c) leaving
it as-is and relying on `mcp/json` plus `:json-null` propagation.
Decision deferred to first observed need.

**OQ-2 — Helper namespace if `mcp/<server>` ever ships.** §5.4
proposes moving to `mcp.util/`. Confirm at the time of resurrection;
until then `mcp/` is fine.

**OQ-5 — Analyzer dispatch shape for namespaced builtins.** PTC-Lisp's
analyzer parses `(json/parse-string ...)` as
`{:ns_symbol, :json, :"parse-string"}` and `normalize_clojure_namespace/3`
currently dispatches via the unqualified atom (`:"parse-string"`),
not via the namespace-qualified key (`:"json/parse-string"`). The
existing `clojure.string/split` family works because of namespace-
specific lookup tables tied to particular Elixir modules. v1's
implementation **MUST** pick one of:

(a) **Per-namespace lookup tables** — add a `json/` map and an
    `mcp/` map to the analyzer, mirroring how `clojure.string/` is
    wired today. Smaller change; consistent with existing patterns.
    Both namespaces ship together so neither is left dangling.
(b) **Full namespaced atom dispatch** — extend
    `normalize_clojure_namespace/3` to look up
    `:"<namespace>/<name>"` directly in `Env.initial()` when the
    namespace is on the analyzer's allowlist. More general; covers
    `json/`, `mcp/`, and any future namespace without per-namespace
    plumbing.

(a) is recommended for v1 — narrower change, clearer parallel to
existing namespaces. (b) is the natural follow-up if the spec ever
adds a fourth namespace beyond `tool/`, `data/`, `json/`, and `mcp/`.
The implementer should pick during the implementation PR and note
the choice in the PR description. Either way, ExUnit tests in
`lisp/eval_test.exs` **MUST** assert that **all four** of
`(json/parse-string "...")`, `(json/generate-string {})`,
`(mcp/text {...})`, and `(mcp/json {...})` evaluate without
"unknown namespace" or "unbound function" errors against minimal
fixtures.

**OQ-4 — Multi-text helper (`mcp/all-text`).** §5.1 caps `mcp/text`
at `content[0]`. `fs.read_multiple_files` is a present-day counterexample
that returns one text item per file. v1 documents the explicit `(map
#(get % "text") (get result "content"))` form (§5.1.1). If the
explicit form proves cumbersome in practice — particularly once
catalog-driven authoring against multi-text upstreams becomes common
— add `(mcp/all-text result) -> [String.t()]` returning every text
item's `"text"` (returns `[]` for non-text shapes, mirroring `mcp/text`
nil-on-mismatch semantics). The decision should land alongside the
first observed friction, not preemptively.

## 10. Document History

- 2026-05-09 — Initial draft.
- 2026-05-09 (codex round 6 — final): Three more cleanup findings.
  (1) §4.4's "Unconditional registration" bullet still claimed
  `mcp/*` was aggregator-only. Reworded to put all four forms
  (`json/*` + `mcp/*`) under one unconditional umbrella with one
  cross-reference to §5.5 for placement rationale.
  (2) §4.4 checklist steps 2-3 only enumerated `json/*` Env
  entries; with `mcp/*` now also unconditional both must be added
  in the same change. Listed all four explicitly in the code block
  and called out "all four" in step 3.
  (3) §7's measurements only defined `decoded_bytes` for the
  `:promoted` outcome; `:already_structured` and `:decode_failed`
  had no payload shape. Added a per-outcome measurement table and
  introduced `text_bytes` for `:decode_failed` so consumers can
  correlate failures with the response cap.
  Spec is internally consistent at this revision; remaining codex
  rounds would surface taste-level rather than correctness-level
  drift. Locking and committing.
- 2026-05-09 (codex round 5): Two leftover consistency findings.
  (1) §4.4's `mcp/` allowlist note still tied registration to
  "aggregator-mode helpers" — but §5.5's revision made the helpers
  unconditional. Reworded so both `json/` and `mcp/` are
  allowlisted unconditionally in the same change.
  (2) §4.4's three-step registration checklist promised
  completeness, but OQ-5's namespaced-dispatch step is also
  required — without it the new forms still fail with
  unbound/unknown namespace errors. Promoted OQ-5's resolution to
  step 4 of the checklist with explicit eval-test gating on all
  four new forms.
- 2026-05-09 (codex round 4): Two consistency findings folded.
  (1) §5 intro still said helpers were "loaded only when
  `configured_aggregator_mode?/0` is true," contradicting §5.5's
  unconditional decision. Aligned the intro.
  (2) §5.5's "new module in mcp_server/" placement contradicted
  unconditional registration via `:ptc_runner`'s `Env.initial()` —
  `:ptc_runner_mcp` depends on `:ptc_runner`, so the placement
  would invert the dependency direction. Specified the module lives
  in `:ptc_runner` (e.g., `lib/ptc_runner/lisp/runtime/mcp.ex`).
  (3) OQ-5's recommended path only mentioned `json/` and the test
  assertion only required `(json/parse-string ...)` to evaluate —
  but the same analyzer change must cover `mcp/` or the helpers
  fail with unknown namespace. Widened to require both namespaces
  in (a)/(b) and to require eval tests for all four new forms.
- 2026-05-09 (codex round 3): Four more findings, three resolved
  in spec text and one (analyzer dispatch) elevated to OQ-5
  because the right answer requires implementer judgment against
  the actual analyzer code.
  (1) §4.2 said "atom keys outside `true`/`false`/`nil` produce
  `nil`," implying the three booleans WERE acceptable as keys; §4.4
  sketch rejected all atoms. Resolved in favor of the stricter rule
  (string + integer keys only) and harmonized §4.2's prose with §4.4's
  predicates.
  (2) `mcp/text`/`mcp/json` originally proposed conditional
  registration on `configured_aggregator_mode?/0`, but no env
  extension hook for normal builtins exists today and the analyzer
  is not profile-aware. Resolved by making registration unconditional
  (§5.5) — the helpers return `nil` against unrelated maps so they
  are harmless in non-aggregator mode.
  (3) §8 listed `isError: true → unchanged` as an auto-decode test
  expectation; per §6.1's new precondition auto-decode is never
  invoked on isError values. Removed and pointed at Phase 4's
  classify_value test as the authoritative coverage.
  (4) Added OQ-5: the analyzer parses `json/parse-string` as
  `{:ns_symbol, :json, :"parse-string"}` and dispatches the
  unqualified atom, so `Env.initial()` registration of
  `:"json/parse-string"` alone won't make the form callable.
  Implementer must choose between a per-namespace lookup table
  (recommended for v1, parallels existing `clojure.string/`) or
  full namespaced atom dispatch (more general). ExUnit assertion
  on `(json/parse-string "...")` evaluating cleanly is a hard gate.
- 2026-05-09 (codex round 2): Four more [P2] integration findings.
  (1) `:"json/parse-string"` registered in `Env.initial()` is not
  callable until the analyzer's namespace allowlist is widened —
  added explicit step 1 in §4.4 (analyzer allowlist for `json/`,
  same for aggregator `mcp/`). (2) `priv/functions.exs` registry
  sync is required for `RegistryTest` and for `Registry.doc/1`
  discovery — added explicit step 3 in §4.4. (3) §4.4 pre-validation
  sketch reused value validation for map keys, which would let
  `true`/`false`/`nil`/floats slip through as keys; split into
  `encodable_value?` and `encodable_key?` (string/integer only) and
  documented the asymmetry. (4) §6.1 listed `isError != true` as an
  auto-decode condition, but Phase 4's classify_value already
  short-circuits isError before this stage; if the §6.1 phrasing
  were taken literally, an `isError: true` envelope failing
  condition (1) would *pass through unchanged* and leak to the
  program. Removed the redundant condition and added a clear
  precondition note that auto-decode runs only on classified-success
  values.
- 2026-05-09 (codex review pass): Folded three [P2] findings from
  codex review of the first revision: (1) §4.1.1's claim that
  `mcp/json` "preserves :json-null" was wrong — `mcp/text` returns
  `nil` for the sentinel per §5.1, so `mcp/json` collapses both JSON
  null and parse failure into bare `nil`; reworded to match §6.2
  honestly. (2) `Jason.encode/1` actually encodes non-boolean atoms
  as JSON strings — vanilla wrap would silently encode where the
  spec requires rejection. Added a mandatory pre-validation walk in
  §4.4 (with sketch implementation) and called the divergence out
  explicitly in §4.2's atom rules. (3) §6.2 said auto-decode runs
  *before* §7.3 rewrite; §6.4 said *after*. Picked one ordering
  (auto-decode runs after classify_value's world-fault check, before
  §7.3's top-level rewrite) and made §6.4 the single source of
  truth with an explicit pipeline diagram. Added the
  decoded-nil-to-:json-null sub-field rule.
- 2026-05-09 (review pass): Folded review feedback. Resolved OQ-3
  ("expose builtins in non-aggregator mode") by promoting it to a
  binding §4.4 implementation note — `json/*` is unconditional. Added
  §4.2.1 keyword-encode doctest examples plus rationale (silently
  auto-stringifying keywords would erode PTC-Lisp's type signal at
  the wire boundary). Added §5.1.1 covering what `mcp/text` does NOT
  cover, with a worked `fs.read_multiple_files` multi-text example
  and pointer to OQ-4. Expanded §6.2 with a concrete two-path example
  showing how `:json-null` lands at the top level vs inside
  `structuredContent` after auto-decode, plus the `mcp/json`
  collapse-to-nil shortcut. New OQ-4 covers the `mcp/all-text` helper
  for multi-text upstream results.
