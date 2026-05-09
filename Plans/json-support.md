# JSON Support for PTC-Lisp & MCP Aggregator — Specification

| Field | Value |
|---|---|
| Status | **Implemented** (Phase A `8da57a2`, Phase B `69b73c3`, Phase C `eea8323`; spec fix `6852ca4`). Live-validated end-to-end against the aggregator: Phase B path via `mem.read_graph`'s native `structuredContent`, Phase C auto-decode via a fake upstream emitting `mimeType: application/json`. |
| Target packages | `:ptc_runner` (PTC-Lisp builtins), `:ptc_runner_mcp` (helpers, auto-decode) |
| Depends on | `ptc-runner-mcp-aggregator.md` |
| Last revised | 2026-05-09 (pass 11 + post-impl §5.2 fix) |

This document specifies JSON-handling support for PTC-Lisp programs and
the MCP aggregator. It addresses the concrete friction observed when
upstream MCP servers return JSON inside `content[0].text` (e.g.
`mem.read_graph`), forcing generated programs to fall back to string
regex to split entities from relations.

Sections using **MUST** / **SHOULD** / **MAY** carry RFC 2119 normative
weight.

## 1. Scope and Goals

The work delivers four complementary, layered pieces:

1. **JSON primitives in PTC-Lisp** — `json/parse-string` and
   `json/generate-string` builtins matching Cheshire's signatures.
2. **MCP unwrap helpers** — `mcp/text` and `mcp/json` so programs
   stop hand-coding `(get-in result ["content" 0 "text"])`.
3. **Conservative auto-decode at the aggregator boundary** — promote
   parsed JSON into `structuredContent` only when the upstream
   declares `mimeType: "application/json"`.
4. **Prompt and authoring-card updates** (§10) — surface the new
   builtins consistently across the aggregator authoring card,
   default authoring card, language reference, and analyzer error
   message. Cheshire / `clojure.data.json` are the dominant Clojure
   JSON libraries in LLM training data; without explicit prompt
   callouts and an analyzer-message update, the new surface is
   discoverable only via wasted turns.

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
| `:json-null` sentinel | Existing top-level rewrite from Phase 4 §7.3. **Notation**: in PTC-Lisp source, written `:json-null`. As an Elixir atom, `:"json-null"` (the hyphen forces quoted-atom syntax). Same value at runtime — the parser maps PTC-Lisp keywords with hyphens to Elixir's quoted-atom representation. The plan uses both spellings depending on which side of the boundary the surrounding code is on. |

## 3. Non-Goals

- A streaming or incremental JSON parser. `json/parse-string`
  operates on whole strings via `Jason.decode/1`, materializing the
  full parse tree in sandbox memory. Inputs whose post-parse
  expansion exceeds the sandbox 10 MB cap **will fail the program**
  (the sandbox kills the worker; from the calling LLM's perspective
  the call simply errors). v1 makes no attempt to handle large
  inputs gracefully — see OQ-6 (§9) for the v2 path.
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
  Elixir floats. Elixir integers are **arbitrary precision** out of
  the box — JSON integers larger than int64 (`> 2^63 - 1`) parse
  cleanly without overflow or string fallback. Programs handling
  large IDs, snowflake-style timestamps, or UUIDs-as-bigint can
  rely on this.
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
> before calling. Note: `mcp/json` (§5.2) is **not** a way to recover
> the distinction at the parse layer — its `structuredContent`-first
> precedence preserves `:json-null` from auto-decode but still
> collapses bare-text parse failure (no `structuredContent`, invalid
> text JSON) to plain `nil`. See §6.2 for the full propagation table
> showing how `:json-null` lands differently through the top-level
> §7.3 rewrite vs the auto-decode `structuredContent` path.

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

For all values `v` whose shape is **string-keyed** maps, JSON scalars,
and lists/maps recursively, the following **MUST** hold:

```clojure
(= v (json/parse-string (json/generate-string v)))
```

This is the contract programs rely on. Any divergence is a bug.

**Integer-key carve-out.** Integer-keyed maps are accepted by
`json/generate-string` (per §4.2 and the `encodable_key?` predicate
in §4.4) but **do not round-trip**: `{1 "a"}` encodes to
`"{\"1\":\"a\"}"` and parses back as `{"1" "a"}` (string key). This
is consistent with `Jason`'s default and JSON's "string keys only"
rule. Programs that need round-trip equality **MUST** stringify
integer keys before encoding, or treat the key-type shift as
expected. The property above is therefore restricted to string-keyed
inputs; a separate property for integer-keyed inputs would have to
read `(= (stringify-keys v) (json/parse-string (json/generate-string v)))`.

**Special-float carve-out.** PTC-Lisp's `POSITIVE_INFINITY`,
`NEGATIVE_INFINITY`, and `NaN` constants resolve to the Elixir atoms
`:infinity`, `:negative_infinity`, and `:nan` respectively (see
`env.ex` `@constants` at lines 450-452). Per §4.4's
`encodable_value?/1`, those atoms aren't in `[true, false, nil]`,
so `(json/generate-string POSITIVE_INFINITY) => nil`. Special floats
are not JSON scalars; encoding deliberately returns `nil` rather
than emitting non-standard `Infinity` / `NaN` literals (which
upstream parsers will reject anyway). Programs that produce these
values from arithmetic must filter them before serialization.

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

  1. **Analyzer namespace allowlist + category mapping.** PTC-Lisp's
     analyzer recognizes slash forms (`json/parse-string`) as
     namespace symbols and rejects namespaces not in its allowlist
     (existing entries: `tool/`, `data/`, `clojure.string/`, etc.).
     The allowlist lives in `Env.@clojure_namespaces` and maps each
     namespace atom to a **category** atom used by suggestion
     diagnostics (`Env.namespace_category/1` →
     `Registry.category_name/1` → "did you mean one of: …"). Add
     **both `json/` and `mcp/`** to that allowlist in the same
     change with new dedicated categories so suggestions render
     cleanly:

     ```elixir
     # in lib/ptc_runner/lisp/env.ex @clojure_namespaces
     :json => :json,
     :mcp  => :mcp,
     ```

     ```elixir
     # in lib/ptc_runner/lisp/registry.ex category_name/1
     def category_name(:json), do: "JSON"
     def category_name(:mcp),  do: "MCP"
     ```

     `Registry.builtins_by_category/1` already iterates
     `Registry.implemented()` and filters by `:category` — no per-
     category clause needed there as long as registry entries
     (step 3) carry `category: :json` / `category: :mcp`.

     Both namespaces are unconditional base builtins per §5.5, so
     the allowlist must accept them in default mode and aggregator
     mode alike. (Phase 3 / aggregator §3 forbids *new analyzer
     passes* but allowlist additions are mechanical and do not
     introduce new semantics — the existing slash-form handling is
     reused.)
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
  3. **Function registry sync.** `RegistryTest`
     (`test/ptc_runner/lisp/registry_test.exs:10`) asserts every
     `Env.initial()` builtin is present in `priv/functions.exs` —
     specifically: `Env.initial() |> Map.keys() |>
     Enum.map(&Atom.to_string/1)` must be a subset of
     `Registry.implemented() |> Enum.map(& &1.name)`. Because the
     env keys are namespaced atoms (`:"json/parse-string"` per OQ-5
     resolution), the registry `name:` field **MUST** carry the
     full namespaced string — `name: "json/parse-string"`, NOT
     `"parse-string"`. This is the asymmetry vs `clojure.string/`
     entries (which use unqualified `name: "join"` because the env
     key is `:join`).

     Add full entries for all four new forms. Sketch for one:

     ```elixir
     %{
       name: "json/parse-string",
       description: "Parse a JSON string into a value; nil on failure.",
       binding: :normal,
       category: :json,
       dispatch: :env,
       signatures: ["(json/parse-string s)"],
       since: nil,
       section: "JSON",
       ptc_extension?: false,
       examples: [],
       notes: nil,
       see_also: ["json/generate-string", "mcp/json"],
       clojure_var: "cheshire.core/parse-string",
       divergences:
         "DIV-23: returns nil on invalid/non-binary input instead of raising. See docs/clojure-conformance-gaps.md."
     }
     ```

     The other three follow the same shape with `category: :json`
     for `json/generate-string` and `category: :mcp` for `mcp/text`
     / `mcp/json`. Without this step the new builtins are
     undiscoverable via `Registry.doc` and the registry sync test
     fails.
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
- Add the entries to `docs/function-reference.md` under a new
  combined "JSON / MCP helpers" section. **Note**:
  `docs/function-reference.md` today is a flat list of unqualified
  names (no existing namespaced entries — `clojure.string/X` is not
  enumerated separately because the analyzer treats it as an alias
  for the unqualified `:X`). Since `json/parse-string` and friends
  are NOT aliases — they're distinct env keys with no unqualified
  fallback — they need their own subsection rather than being
  inserted under "j" / "m" in the flat list. New section header,
  alphabetical within the section.
- Update `docs/ptc-lisp-specification.md` with a short subsection
  cross-linking the function reference. Per CLAUDE.md
  ("when you find issues, fix both the code and the docs together")
  the docs land in the same PR.
- **Add two DIV-* entries to `docs/clojure-conformance-gaps.md`** —
  the spec invokes the convention throughout but the divergences
  themselves must be cataloged in the canonical compliance doc, not
  just in this plan. Use the next free IDs (currently DIV-23 / DIV-24
  given DIV-22 is the last entry):
  - **DIV-23: `json/parse-string` returns `nil` on invalid input.**
    Cheshire / `Jason.decode!` raise on malformed JSON; PTC-Lisp
    returns `nil`. Rationale: no try/catch in the sandbox (DIV-10),
    so signal-value semantics is the only safe option. Cross-link
    to §4.1 of this plan.
  - **DIV-24: `json/generate-string` returns `nil` on non-encodable
    input.** `Jason.encode/1` silently coerces non-boolean atoms to
    JSON strings (e.g. `:fs` → `"fs"`); PTC-Lisp deliberately
    rejects them (returns `nil`). Rationale: preserve PTC-Lisp's
    type signal at the wire boundary (§4.2) and avoid lossy
    auto-stringification. Cross-link to §4.2 / §4.4.
  These entries land in the same PR as the builtins (CLAUDE.md
  "fix code and docs together"), not as a follow-up.
- **Prompt and authoring-card updates.** See §10 ("Prompt and
  Tool-Description Updates") for the full coordination plan: the
  aggregator authoring card (§10.1), default authoring card
  (§10.2), language reference (§10.3 — also fixes the misleading
  "namespaces NOT available" wording), and analyzer error message
  (§10.4). Note: the `json-system.md` / `json-user.md` /
  `json-error.md` prompts cover JSON-mode LLM **responses** (a
  different axis — text-mode structured output) and are
  **unaffected** by these new builtins. At PR time, re-grep
  `priv/prompts/*.md` and `mcp_server/priv/*.md` for `parse-int`,
  `parse-long`, `clojure.string/`, or any namespace allowlist
  string in case the prompt surface has shifted since 2026-05-09.
  Per CLAUDE.md, prompt files are compile-time and require a
  recompile after changes.
- **Cross-reference from `Plans/ptc-runner-mcp-aggregator.md`.**
  The aggregator spec's success-path classifier (§4.1 / §7.1) gains
  a new sub-step — auto-decode promotion (§6 of this plan) — that
  affects the value handed to the PTC-Lisp closure. Add a pointer
  in the aggregator spec's "Document History" or §16 Open Questions
  ("auto-decode added — see `Plans/json-support.md` §6") so future
  readers don't reason about the `:ok` branch in isolation.
- **Changelog entries.**
  - Root `CHANGELOG.md`: an entry for `json/parse-string`,
    `json/generate-string`, `mcp/text`, and `mcp/json` (user-facing
    PTC-Lisp builtins).
  - `mcp_server/CHANGELOG.md`: an entry for the auto-decode
    promotion behavior, the new telemetry event
    `[:ptc_runner_mcp, :upstream, :auto_decode, :stop]`, and the
    fact that `mcp/*` helpers are now part of the base PTC-Lisp
    surface (so aggregator-mode programs can rely on them).

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
  - `result["content"]` is a list (non-emptiness is implied by the
    next clause requiring a first item),
  - the first item is a map with `"type" == "text"`,
  - the first item has a binary `"text"` field.
- Returns `nil` for any non-conforming input, including `nil`,
  non-map values (e.g. the `:json-null` sentinel from §7.3, which is
  a keyword and so by definition lacks a `"content"` field), and
  maps whose `content[0]` is not a text item.
- **MUST NOT** raise. **MUST NOT** scan past index 0 — programs that
  need later items use `get-in` directly. (Index 0 covers the observed
  cases; broadening is a future change once a counterexample appears.)

### 5.1.1 What `mcp/text` does *not* cover

`mcp/text` returns `content[0]["text"]` only. Real upstreams sometimes
return multiple text items in a single response — the documented
filesystem-MCP `read_multiple_files` tool (from
`@modelcontextprotocol/server-filesystem`, a publicly documented
upstream) is a concrete counterexample, returning one text item per
file in `content[]`. The upstream is **not** part of this repo's
fixtures or catalog — it's referenced as a real-world shape, not as
something the test suite can spawn directly. Programs that need to
reach later items handle them explicitly:

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

`mcp/json` is the "give me the typed JSON of this result"
helper. It prefers the spec-blessed `structuredContent` channel
when it's present and falls back to parsing `content[0].text`
otherwise. Precedence — **key-presence**, NOT truthiness:

1. If `result` is a map AND `"structuredContent"` is a key in the
   map (regardless of value), return that value verbatim — including
   `:json-null` (§6.4 sub-field promotion), `false`, `0`, `""`, and
   `[]`. All of these are valid JSON payloads that an upstream may
   legitimately put on the typed channel.
2. Otherwise (key absent), return `(json/parse-string (mcp/text result))`.

> **Implementation trap — do not use `or` over `Map.get/2`.** A
> literal `(get r "structuredContent")` returns `nil` for both
> "key absent" and "key present, value `nil`", and combining it with
> an `or`-chain falls through to `mcp/text` whenever the value is
> any falsy term — including legitimate JSON payloads like `false`
> or `0` (post-Phase-C auto-decode of `"false"` / `"0"` text yields
> exactly these). The implementation **MUST** branch on key presence
> via `Map.fetch/2` + `case`, not on truthiness of `Map.get/2`.
> Phase B's runtime uses `Map.fetch(result, "structuredContent")`
> for this reason; the regression test in `runtime/mcp_test.exs`
> covers the `false` case explicitly. The earlier "(`or`-chain
> semantics: `:json-null` is truthy)" wording was misleading because
> it considered the keyword sentinel but missed every other
> falsy-but-valid JSON term.

This precedence matters because **the dominant case post-Phase 4 is
`structuredContent`-populated**, either via §6 auto-decode or via
upstreams that natively use the spec channel. A naive
`(json/parse-string (mcp/text result))` would return `nil` whenever
an upstream returns typed JSON in `structuredContent` and a
human-readable summary in `content[0].text` — exactly the case this
helper is supposed to make ergonomic. Programs that want the raw
text (e.g. for human display) call `mcp/text` directly.

- Returns `nil` when both paths fail: `structuredContent` absent /
  `nil`, AND `mcp/text` returns `nil`, OR the extracted text isn't
  valid JSON.
- The "structuredContent absent" and "structuredContent present but
  parse-failure on text" cases collapse to the same return shape
  whenever both happen to produce `nil` (OQ-1 — programs that need
  to distinguish branch on `(contains? result "structuredContent")`
  before calling `mcp/json`).
- **`:json-null` propagation.** When `structuredContent` is
  `:json-null` (auto-decoded JSON null per §6.4), `mcp/json` returns
  `:json-null`. When the *only* JSON null was at the top level
  (§7.3 rewrite, no map), the call to `mcp/json` receives
  `:json-null` directly as `result`, hits the "result is not a map"
  branch of §5.1, and returns `nil`. This asymmetry mirrors §6.2 and
  is intentional: a sub-field JSON null is preserved (so programs
  can distinguish "field present, value null" from "field absent");
  a top-level JSON null is collapsed (because the entire call has no
  structure left to address).

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
- **"Harmless" qualifier.** Calling `(mcp/text some-non-MCP-map)`
  outside an aggregator pipeline returns `nil` silently — by design.
  In a downstream pipeline that threads through `or` / `if-let` /
  `(when v ...)` chains, that `nil` can cascade through several
  steps before the program notices. This is a programmer error
  ("called the wrong helper"), not a runtime fault, and the spec
  does not introduce diagnostics for it. The helpers are documented
  in `docs/function-reference.md` as MCP-result-shape inspectors;
  programs that aren't reading MCP results shouldn't be calling
  them. If misuse becomes a recurring LLM bug pattern in practice,
  revisit via a follow-up open question.

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

**`mcp/json` interaction (post-§5.2 revision).**
- Path A (`result = :json-null`): `mcp/json` falls through both
  branches — result isn't a map, so the `structuredContent` lookup
  returns `nil`, and `mcp/text` of a non-map also returns `nil`.
  Final value: `nil`.
- Path B (`structuredContent = :json-null`): `mcp/json` returns
  `:json-null` verbatim (the sentinel is non-nil and §5.2 preserves
  it). Programs reading via `mcp/json` see `:json-null` and can
  distinguish "field present, value JSON null" from "field absent".

So `mcp/json` is *not* a universal collapse: top-level JSON null
becomes plain `nil`, sub-field JSON null is preserved as
`:json-null`. Programs that want a uniform "parsed-or-nothing"
signal can post-process with
`(if (= v :json-null) nil v)`. This is a deliberate design choice
(see §5.2 rationale) — losing the sentinel at the helper layer
would erase information that §6.4 was at pains to preserve.

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
- The promotion lives in `aggregator_tools.ex` on the `:ok` branch
  of the `case classify_value(value) do` block inside the call-
  result handler — currently right around the
  `rewritten = if is_nil(value), do: :"json-null", else: value`
  line. Anchor on the function/branch, not a line number. The
  surrounding code churns under Phase 4 / §16 hardening, and a
  numeric reference would rot inside one revision.
- Decode **MUST NOT** raise. The `Jason.decode/1` call is wrapped;
  on `{:error, _}` the result passes through unchanged.
- **`:decode_failed` is silent for the program.** A
  `mimeType: "application/json"` upstream that returns malformed
  JSON is arguably a soft upstream defect, but v1 treats it as a
  pass-through: the original envelope reaches the program intact
  (programs can still call `mcp/json` and observe `nil`), and **no**
  entry is added to `upstream_calls` — that side-channel is reserved
  for world-faults per §7.1. The `:decode_failed` telemetry event
  (§7) is the only operator-visible signal. Promoting decode
  failures to soft world-faults is a deliberate non-goal in v1; if
  the decode-failure rate proves operationally noisy, revisit via a
  follow-up open question.
- **Wire-payload growth is real and ~2×.** Auto-decode is
  *additive*: the original `content[]` text is retained AND
  `structuredContent` is added. When the aggregator response is
  JSON-encoded back to the MCP client, both fields ship — so a
  promoted result is roughly twice the byte size of the
  text-content item on the wire. The `max_response_bytes` upstream
  cap bounds the original *upstream-side* text coming in, NOT the
  *response-side* envelope going back to the client. Operators
  should size client-side response buffers with the doubling in
  mind. Telemetry (§7) records decoded byte size so operators can
  spot pathological growth and adjust caps if the doubling
  approaches client limits.

  Earlier wording in this spec ("auto-decode does not amplify the
  payload") was misleading and is corrected here. The accurate
  framing: parsed-tree size ≈ source-text size after re-encode
  (Jason output is comparable to source JSON), so total response
  growth ≈ 1× the text-content bytes that were already counted
  against `max_response_bytes`. No new ceiling is introduced, but
  the response envelope is meaningfully larger than the
  pre-auto-decode case.

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
- **Side-channel invariant test (§6.4 lock-in):** explicit assertion
  that a malformed-JSON-with-matching-mimeType produces *only* the
  `:decode_failed` telemetry event and **does NOT** add an
  `upstream_error` entry to `upstream_calls`. The side-channel is
  reserved for world-faults, not soft decode misses. Without this
  test the rule could regress silently (the value passes through
  intact, so program behavior is unchanged — only the side-channel
  shape would shift).
- **Wire-amplification spot check:** one assertion that a promoted
  response, after JSON-encoding, is ≥ 1.5× the byte size of the same
  response without promotion. Not a regression gate (Jason's exact
  encoding is brittle to assert on bytes), but a sanity check that
  the doubling described in §6.4 actually obtains. If this drops
  meaningfully below 1.5×, the implementation is silently dropping
  one of `content[]` / `structuredContent`.

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

**OQ-3 — Resolved.** Originally: "expose `json/*` builtins outside
aggregator mode?" Resolved during the first review pass by
promoting unconditional registration to a binding §4.4 / §5.5
implementation rule. Both `json/*` and `mcp/*` ship in
`:ptc_runner`'s `Env.initial()` and are available in every PTC-Lisp
run. Stub left here so readers don't think they're missing an entry
between OQ-2 and OQ-4.

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

**OQ-6 — Large JSON input handling.** v1 materializes whole parse
trees via `Jason.decode/1`. Three independent ceilings stack up:

1. **Sandbox memory cap (10 MB).** BEAM term overhead inflates JSON
   significantly (per-map ~50–100 B + per-key cost, list cons cells,
   etc.). A ~1–2 MB JSON input is a realistic ceiling before the
   10 MB sandbox limit blows up *during parse*.
2. **Sandbox timeout (1 s).** `Jason` decodes ~50–100 MB/s, so
   parsing alone is fine, but the surrounding PTC-Lisp work that
   walks/filters the result eats the rest of the second.
3. **`max_response_bytes` upstream cap** bounds the *text* coming
   in, but does not account for post-parse expansion.

This is a real limitation for the use cases motivating this spec
(`mem.read_graph` on a populated graph easily clears 1 MB; log /
issue-listing tools routinely return larger). v2 candidates,
ranked by impact:

(a) **`json/decode-at s "/path"`** built on **`jaxon`** (SAX-style
    streaming Elixir parser), with a path-projection arg returning
    just the addressed sub-tree without materializing the rest.
    Solves the dominant case ("LLM wants a sub-field of a big
    upstream result") and matches the JSONPath/jq mental model the
    LLM already has from broader training data.
(b) **`mcp/json-at result "/path"`** — companion that applies the
    same path-projection to the unwrap helper. Naturally extends
    the §5 surface. **Inherits `mcp/json`'s structuredContent-first
    precedence (§5.2):** path-projection runs against
    `structuredContent` if present and non-`nil`, falling back to
    streaming the `content[0].text` only when the typed channel is
    empty. v2 must not be less capable than v1's helper — operating
    only on `content[0].text` would erase the post-Phase 4 majority
    case where typed JSON arrives via `structuredContent`.
(c) **No general lazy seq abstraction.** Real interpreter laziness
    is a big lift, and path-projection covers the bulk of "big
    JSON, small slice" cases without touching evaluator semantics.

The decision to ship (a)+(b) should land alongside the first
observed v1 failure on a real upstream payload — not preemptively.
A failing integration test that exercises the §3 ceiling on a
realistic `mem.read_graph` size would be the natural trigger.

**OQ-4 — Multi-text helper (`mcp/all-text`).** §5.1 caps `mcp/text`
at `content[0]`. The documented filesystem-MCP `read_multiple_files`
tool (see §5.1.1 for upstream attribution) is a real-world
counterexample that returns one text item per file. v1 documents the
explicit `(map
#(get % "text") (get result "content"))` form (§5.1.1). If the
explicit form proves cumbersome in practice — particularly once
catalog-driven authoring against multi-text upstreams becomes common
— add `(mcp/all-text result) -> [String.t()]` returning every text
item's `"text"` (returns `[]` for non-text shapes, mirroring `mcp/text`
nil-on-mismatch semantics). The decision should land alongside the
first observed friction, not preemptively.

## 10. Prompt and Tool-Description Updates

A new builtin is uncallable in practice if the LLM doesn't know it
exists. Cheshire and `clojure.data.json` are the dominant Clojure
JSON libraries in training data, so an LLM reaching for "parse this
JSON" will naturally try `(cheshire.core/parse-string ...)` or
`(clojure.data.json/read-str ...)` first. Without prompt callouts
those attempts hit "unknown namespace" errors and waste turns.
Without an analyzer-message update they get pointed at `tool/` /
`data/` — the wrong direction. This section coordinates the prompt,
authoring-card, and analyzer-message changes so the new surface is
consistently advertised.

### 10.1 Aggregator authoring card

**File:** `mcp_server/priv/mcp_aggregator_authoring_card.md`
**Audience:** LLM clients calling `ptc_lisp_execute` against the
aggregator. This is the primary surface — LLMs read it before
generating programs that traverse upstream MCP results.

Add a new section after `## :json-null sentinel` and before
`## Response envelope`. Keep it tight: the LLM already knows what
"parse JSON" and "generate JSON" do — the prompt's job is just to
advertise *existence* and the few non-obvious twists (nil-not-raise,
`mcp/json` precedence). Recommended copy (~5 lines):

```markdown
## JSON helpers

- `(json/parse-string s)`, `(json/generate-string v)` — Cheshire-style; return `nil` on failure (no raise; map keys parse as strings).
- `(mcp/text r)` — `r["content"][0]["text"]` or `nil`.
- `(mcp/json r)` — `r["structuredContent"]` if set, else `(json/parse-string (mcp/text r))`. Use for typed JSON results.
```

Deliberately omitted: the non-encodable-input list (atoms, tuples,
PIDs) for `json/generate-string` — LLMs already expect "non-encodable
inputs fail," and the analyzer message + `nil` return surface the
specific case at runtime. Also omitted: the explicit
"`cheshire.core/...` not aliased" line — §10.4's analyzer error
message handles the redirect on first wrong attempt without bloating
the prompt.

### 10.2 Default (non-aggregator) authoring card

**File:** `mcp_server/priv/mcp_authoring_card.md`
**Audience:** LLM clients calling `ptc_lisp_execute` in default mode
(no upstream MCP servers). `json/*` is unconditionally registered;
`mcp/*` is registered too but won't usually have anything to
unwrap. Mention only `json/*` here — keep the card short.

Add a single bullet to the existing `## Non-obvious bits` list:

```markdown
- **JSON**: `(json/parse-string s)` / `(json/generate-string v)` are available; `nil` on failure.
```

One line. The Cheshire-name redirect is left to §10.4's analyzer
message — the default-mode card is already terse and an extra line
on aliasing would be disproportionate.

### 10.3 Language reference (also fix "namespaces" wording)

**File:** `priv/prompts/reference.md`
**Audience:** SubAgent path; default-included in PTC-Lisp system
prompts unless explicitly suppressed.

Two coordinated edits in one PR:

1. **Add a `<json>` block** alongside the existing `<java_interop>`
   and `<restrictions>` blocks. Mirror the structure (XML-like tag
   wrapping, tight bullet list). Same minimalism as §10.1 — advertise
   existence + non-obvious twists, nothing more:

   ```markdown
   <json>
   - `(json/parse-string s)`, `(json/generate-string v)` — Cheshire-style; `nil` on failure (no raise; map keys parse as strings).
   - `(mcp/text r)`, `(mcp/json r)` — extract MCP `content[0].text` / parse it. `mcp/json` prefers `r["structuredContent"]`.
   </json>
   ```

   Two lines of content. Aliasing redirect, non-encodable-value
   detail, and per-helper `nil`-on-mismatch semantics are all
   omitted on the same rationale: LLMs derive them, the analyzer
   message and `nil` returns surface the rest at runtime.

2. **Fix the "namespaces NOT available" wording** in `<restrictions>`.
   The current line:

   > NOT available: lazy-seq, atom, ref, future, promise,
   > try/catch/throw, dotimes, iterate, repeat, cycle, transients,
   > metadata, namespaces, macros, general Java interop, I/O
   > (except println)

   misleads LLMs because `tool/`, `data/`, `clojure.string/`,
   `clojure.set/`, and now `json/` / `mcp/` *are* namespaces. The
   intended restriction is on **declaring new namespaces**
   (Clojure's `ns`, `require`, `refer`, `import`). Replace with:

   > NOT available: lazy-seq, atom, ref, future, promise,
   > try/catch/throw, dotimes, iterate, repeat, cycle, transients,
   > metadata, **namespace declaration (`ns` / `require` / `refer` /
   > `import`)**, macros, general Java interop, I/O (except println).
   > A fixed allowlist of namespaces *is* available: `tool/`,
   > `data/`, `clojure.string/`, `clojure.set/`, `json/`, `mcp/`.

   This isn't strictly required for the JSON spec, but every new
   namespace makes the old wording more confusing — fold the fix
   into this PR rather than leaving it for a follow-up.

### 10.4 Analyzer "unknown namespace" error message

**File:** `lib/ptc_runner/lisp/analyze.ex` (the
`normalize_clojure_namespace/3` `true ->` branch, currently emits
`"unknown namespace <ns>/. Use tool/ for tools, data/ for input
data"`).

Currently hardcoded to mention only `tool/` and `data/`. After
adding `json/` and `mcp/` to the allowlist, an LLM that tries
`(cheshire.core/parse-string ...)` gets pointed at the wrong
namespaces. Update to enumerate the real allowlist or, better,
derive it from `Env.@clojure_namespaces` so future additions
(`OQ-2` resurrection, etc.) don't drift.

Recommended new message body:

```
unknown namespace <ns>/. Available namespaces: tool/, data/,
json/, mcp/, clojure.string/, clojure.set/. For JSON parsing use
json/parse-string (not cheshire.core/...).
```

The Cheshire callout is targeted because that name is the single
most likely first-attempt for "parse JSON in Clojure." Generic
exhaustive enumeration of every wrong-name candidate is impractical;
one explicit redirect for the dominant case is high-leverage.

### 10.5 What LLMs expect that we don't provide

Captured here so the implementer doesn't quietly add aliases under
"helpful" framing. **v1 deliberately does NOT alias**:

| LLM-expected name | Actual binding | Rationale for no alias |
|---|---|---|
| `cheshire.core/parse-string` | `json/parse-string` | Aliasing pollutes `Env.@clojure_namespaces` with vendor names; one canonical name keeps the surface tight. Analyzer error message (§10.4) redirects. |
| `cheshire.core/generate-string` | `json/generate-string` | Same. |
| `clojure.data.json/read-str` | `json/parse-string` | Same; less common than Cheshire in training data. |
| `clojure.data.json/write-str` | `json/generate-string` | Same. |
| `slurp` / `spit` | (unsupported) | I/O is excluded by sandbox design; explicit "no I/O" already in `reference.md`. |
| `read-string` (Clojure reader) | (unsupported) | Code-eval surface; security non-goal. |
| `json-path` / `jq` | (unsupported in v1) | Tracked as OQ-6 v2 path-projection (`json/decode-at`). |

This table is not in the prompts — it lives here as implementer
guidance. The prompts mention only the canonical names. If a
specific wrong-name attempt becomes a recurring LLM failure mode in
practice (visible via prompt-failure telemetry), revisit aliasing
as a follow-up open question.

### 10.6 Tool description (`@mcp_aggregator_description` in `tools.ex`)

**No change recommended.** This single-line description
(`mcp_server/lib/ptc_runner_mcp/tools.ex` line ~76) is the
high-level "what does this tool do" pitch attached to
`ptc_lisp_execute` in `tools/list`. Adding JSON-helper detail here
would crowd out the more important `tool/mcp-call` / world-fault /
`upstream_calls` framing. The authoring card (§10.1) is the right
surface for builtin enumeration — it's already injected as a
follow-on to this description (`tools.ex` builds
`@mcp_aggregator_description <> "\n\n" <> aggregator_authoring_card()`).

### 10.7 Coordination summary

The PR for this spec must touch all of:

1. `mcp_server/priv/mcp_aggregator_authoring_card.md` (§10.1)
2. `mcp_server/priv/mcp_authoring_card.md` (§10.2)
3. `priv/prompts/reference.md` (§10.3 — both the new `<json>`
   block and the `<restrictions>` wording fix)
4. `lib/ptc_runner/lisp/analyze.ex` (§10.4 — error message)

§4.4's existing prompt-audit guidance ("re-grep `priv/prompts/*.md`
for `parse-int`, `parse-long`, `clojure.string/`, or any namespace
allowlist string at PR time") still applies. The audit may surface
more files if the prompt surface has shifted since 2026-05-09. Per
CLAUDE.md, prompt files are compile-time and require recompile
after changes (`@external_resource` already wired).

## 11. Implementation Phases

The work splits into three independently-shippable phases. Each phase
ends with a hard `codex review` gate before merge — the reviewer is
not given the spec, just the diff and the codebase, so the gate
catches drift between intent and implementation. Phase A → B → C is
the recommended order; A and B can technically merge in either order
once the analyzer dispatch (OQ-5) is settled, but A's smaller surface
makes it the better warm-up.

Each phase is meant to be picked up by an **Engineer** subagent
working with TDD discipline (CLAUDE.md "Bug fix workflow": failing
test before code). The Engineer subagent is responsible for
resolving any open questions flagged for that phase (see "Decisions
required" rows below) and documenting the choice in the PR body.

### 11.1 Phase A — JSON primitives

Smallest, tightest scope. Lands `(json/parse-string ...)` and
`(json/generate-string ...)` as unconditional `:ptc_runner` builtins.
After this phase, default-mode programs and aggregator-mode programs
both have native JSON parsing without any aggregator-side changes.

**Scope:**

- New module `lib/ptc_runner/lisp/runtime/json.ex` with
  `parse_string/1` and `generate_string/1` (§4.1, §4.2, §4.4).
  Pre-validation walk for `generate_string/1` per the §4.4 sketch
  (`encodable_value?` + `encodable_key?`).
- Env registration in `lib/ptc_runner/lisp/env.ex` (§4.4 step 2).
- Analyzer namespace allowlist + `:json` category mapping in
  `Env.@clojure_namespaces` (§4.4 step 1, §10.4).
- `Registry.category_name(:json)` clause in
  `lib/ptc_runner/lisp/registry.ex`.
- Resolution of OQ-5 (analyzer dispatch shape) — implementer picks
  (a) per-namespace lookup tables or (b) full namespaced atom
  dispatch and documents the choice in the PR body.
- Function registry sync in `priv/functions.exs` with full
  `name: "json/parse-string"` entries (§4.4 step 3 sketch).
- DIV-23 + DIV-24 entries in `docs/clojure-conformance-gaps.md`
  (§4.4).
- New "JSON / MCP helpers" subsection scaffolded in
  `docs/function-reference.md` with the two `json/*` entries (§4.4).
- `<json>` block in `priv/prompts/reference.md` (§10.3) — and the
  paired `<restrictions>` wording fix.
- Analyzer error message update for unknown namespaces (§10.4) —
  even though `mcp/` lands in Phase B, the message should already
  list `json/, mcp/, …` so Phase B doesn't have to re-touch the
  analyzer.
- Root `CHANGELOG.md` entry for the two builtins.

**Decisions required (Engineer subagent picks + documents):**

- OQ-5 dispatch shape: (a) vs (b).
- `json/parse-string` registry `category:` value (`:json` —
  recommended for clean diagnostics, requires the `category_name`
  clause above).

**DoD:**

- `(json/parse-string "{\"a\":1}")` evaluates to `{"a" 1}` in a
  default-mode program.
- `(json/parse-string "garbage")`, `(json/parse-string nil)`, and
  non-binary inputs return `nil` — verified by ExUnit + doctests.
- `(json/generate-string {:server "fs"})` returns `nil` (keyword
  key rejected) — covered by an explicit doctest per §4.4.
- Round-trip property test passes for string-keyed maps,
  JSON scalars, and recursive lists (§4.3).
- Special-float carve-out test (§4.3): `POSITIVE_INFINITY`,
  `NEGATIVE_INFINITY`, `NaN` all encode to `nil`.
- `(cheshire.core/parse-string "...")` produces the Phase-A error
  message that points at `json/parse-string` (§10.4).
- `mix precommit` passes (format + compile + credo + dialyzer + test).

**Codex review gate (Phase A) — reviewer asks:**

- Does the analyzer dispatch resolution (OQ-5) actually evaluate
  `(json/parse-string "...")` cleanly, or did the implementer add
  the env entry without wiring dispatch?
- Does `generate_string/1` run the pre-validation walk *before*
  `Jason.encode/1`, or did it just wrap `Jason.encode/1` and miss
  the silent-stringify-of-atoms divergence (§4.2 / DIV-24)?
- Is the round-trip property restricted to string-keyed inputs
  (§4.3 carve-out), or does the test falsely assert it for
  integer-keyed maps?
- Are there explicit doctests for the keyword-key, keyword-value,
  tuple, and PID failure cases (§4.4 / §8)?
- Does `priv/functions.exs` use `name: "json/parse-string"` (slash,
  not the unqualified `"parse-string"`)?
- Does `Registry.category_name(:json)` return `"JSON"` so the
  "did you mean" suggestions render cleanly?
- Are DIV-23 and DIV-24 in `docs/clojure-conformance-gaps.md`, or
  did the PR claim them only in commit messages?

### 11.2 Phase B — MCP unwrap helpers

Lands `(mcp/text ...)` and `(mcp/json ...)`. Builds on Phase A
(`mcp/json` calls `json/parse-string` internally). All four builtins
are unconditional in `:ptc_runner`.

**Scope:**

- New module `lib/ptc_runner/lisp/runtime/mcp.ex` with `text/1` and
  `json/1` (§5.1, §5.2, §5.5).
- `mcp/json` precedence: `structuredContent` first, fall back to
  text-parse — §5.2 (this is **the** P1 finding from the codebase
  review, so the implementation must match the new semantics, not
  the older "(json/parse-string (mcp/text result))" formulation).
- Env registration + analyzer allowlist `:mcp => :mcp` +
  `Registry.category_name(:mcp)` clause.
- Function-registry entries with `category: :mcp`.
- Aggregator authoring card §10.1 — drop the 5-line "JSON helpers"
  section into `mcp_server/priv/mcp_aggregator_authoring_card.md`
  (it's `@external_resource`-loaded; no Mix tasks needed).
- Default authoring card §10.2 — single bullet into
  `mcp_server/priv/mcp_authoring_card.md`.
- `mcp_server/CHANGELOG.md` entry noting `mcp/*` is part of the
  base PTC-Lisp surface.

**Decisions required:**

- None (Phase A made the analyzer-dispatch call; this phase reuses
  it for `mcp/`).

**DoD:**

- `(mcp/text {"content" [{"type" "text" "text" "hello"}]})` evaluates
  to `"hello"`.
- `(mcp/json {"structuredContent" {"a" 1}})` evaluates to `{"a" 1}`
  *without* touching `content[]` — covered by an explicit
  precedence test per §5.2.
- `(mcp/json {"content" [{"type" "text" "text" "{\"x\":2}"}]})`
  (no structuredContent) evaluates to `{"x" 2}` — the legacy
  text-only fallback path.
- `(mcp/text :json-null)` returns `nil` (non-map input — §5.1).
- `:json-null` propagation table from §6.2 holds: top-level
  `:json-null` → `(mcp/json …)` returns `nil`; sub-field
  `:json-null` in `structuredContent` → `(mcp/json …)` returns
  `:json-null`.
- `mix precommit` passes.

**Codex review gate (Phase B) — reviewer asks:**

- Does `mcp/json` actually consult `structuredContent` first, or
  did the implementer ship the older "compose with `mcp/text`"
  version that the §5.2 revision rejected?
- Is the new module in `lib/ptc_runner/lisp/runtime/mcp.ex` (under
  `:ptc_runner`), not `mcp_server/lib/...`? Placement matters —
  the latter inverts the `:ptc_runner_mcp → :ptc_runner` dependency
  direction (§5.5).
- Does `mcp/text` correctly reject content items where `"type"` is
  not exactly the string `"text"` (e.g., `"image"`, `"resource"`)?
- Are the authoring-card additions exactly the §10.1 / §10.2 copy,
  or did the implementer expand them into longer prose? (Spec
  pass-10 deliberately trimmed these.)

### 11.3 Phase C — Aggregator auto-decode

Lands the §6 promotion + telemetry. Touches `:ptc_runner_mcp` only;
no `:ptc_runner` changes. After this phase, well-behaved upstreams
declaring `application/json` mimeType automatically populate
`structuredContent` for downstream programs.

**Scope:**

- Auto-decode promotion in
  `mcp_server/lib/ptc_runner_mcp/aggregator_tools.ex` on the `:ok`
  branch of `case classify_value(value) do`. Exact pipeline order
  per §6.4: `classify_value → auto-decode → §7.3 :json-null
  rewrite → program-visible value`.
- Decoded-`nil` → `:"json-null"` substitution at the sub-field
  level (§6.4) so programs see the same sentinel via either path.
- `Jason.decode/1` wrapped so it never raises (§6.4).
- Telemetry event
  `[:ptc_runner_mcp, :upstream, :auto_decode, :stop]` with the
  per-outcome measurement table from §7 (`:promoted` /
  `:already_structured` / `:decode_failed`).
- Cross-reference pointer in `Plans/ptc-runner-mcp-aggregator.md`
  (§16 Open Questions or Document History — Engineer picks)
  saying "auto-decode added — see `Plans/json-support.md` §6"
  (per §4.4).
- `mcp_server/CHANGELOG.md` entry for the auto-decode behavior +
  the new telemetry event.

**Decisions required:**

- None — the precondition (§6.1), pipeline order (§6.4), and
  telemetry shape (§7) are fully specified.

**DoD:**

- An upstream returning `content[0].text = "{\"x\":1}"` with
  `mimeType: "application/json"` produces a result envelope where
  `structuredContent == {"x" 1}` *and* `content[]` is unchanged.
- An upstream returning the JSON literal `"null"` with matching
  mimeType produces `structuredContent == :"json-null"` (§6.4
  sub-field rule).
- An upstream with matching mimeType but malformed JSON
  produces the `:decode_failed` telemetry event AND **no**
  `upstream_calls` entry — the §6.4 lock-in (§8 explicit test).
- An upstream with `isError: true` is never auto-decoded (§6.1
  precondition) — verified by ensuring `aggregator_is_error_test.exs`
  still passes plus a new test asserting no `:auto_decode`
  telemetry fires on isError envelopes.
- A promoted response is ≥ 1.5× the byte size of the same
  response without promotion (§8 wire-amplification spot check).
- `mix precommit` passes in both `:ptc_runner` and
  `:ptc_runner_mcp`.

**Codex review gate (Phase C) — reviewer asks:**

- Does auto-decode run AFTER `classify_value`'s world-fault check?
  (If it runs before, an `isError: true` envelope with matching
  mimeType could leak a promoted value to the program — §6.1.)
- Does auto-decode run BEFORE the §7.3 top-level `:json-null`
  rewrite, so promotion operates on the original map and not on a
  `:json-null` keyword? (§6.4 pipeline.)
- Is the decoded-`nil` sub-field correctly substituted with
  `:"json-null"`, or does `structuredContent` end up containing
  bare `nil` (which is indistinguishable from "field absent")?
- Does `:decode_failed` add **nothing** to `upstream_calls`?
  The side-channel is reserved for world-faults, not soft decode
  misses (§6.4).
- Are both `content[]` AND `structuredContent` retained in the
  promoted response? (If one is dropped, the wire-amplification
  spot-check should fail — that's the canary.)
- Does the `+json` mimeType suffix path actually match
  `application/ld+json` and `application/vnd.foo+json`, or did the
  implementer write a stricter suffix check?

### 11.4 Cross-phase invariants

Carry across all three phases — Codex should re-check on every gate
even when the diff is in another area:

- **No `try/catch` in PTC-Lisp evaluation paths.** All three phases
  use `case`/`with`/`rescue` boundaries to catch Jason raises;
  none should let an exception cross the sandbox boundary.
- **Doctests use full module paths** (`PtcRunner.Lisp.Runtime.Json.parse_string("...")`,
  not `Json.parse_string("...")`) per CLAUDE.md.
- **No `String.to_atom/1` on user input.** Parsing, decoding, and
  result classification must not introduce a memory-leak vector.
- **Domain-blind prompts.** Authoring cards and `reference.md`
  must not mention test data, benchmark domains, or specific
  upstream tools (e.g., `mem.read_graph`, `fs.read_multiple_files`)
  as motivating examples in the prompt itself. Those examples
  belong in this spec, not in the LLM-facing prompt.

### 11.5 Codex invocation

For each gate, from the repo root:

```
/codex review
```

If a finding is non-blocking and the implementer disagrees, the
disagreement is recorded in the PR body with rationale. Blocking
findings (correctness, security, spec divergence) **MUST** be
addressed before merge.

The reviewer is intentionally not given this spec — it works from
the diff and the codebase only. The phase-specific "reviewer asks"
questions above are for the Engineer subagent's self-check before
invoking codex; they are **not** instructions to codex itself.

## 12. Document History

- 2026-05-09 (post-Phase-B finding — §5.2 precedence rewording).
  Phase B implementation surfaced that §5.2's "`or`-chain semantics:
  `:json-null` is truthy" wording was incomplete: it considered the
  keyword sentinel but missed `false`, `0`, `""`, and `[]` — all
  legitimate JSON payloads an upstream may place on the typed
  `structuredContent` channel (post-Phase-C auto-decode of `"false"`
  / `"0"` text yields exactly these). A literal `or`-chain over
  `Map.get/2` collapses "key absent" and "key present, value falsy"
  into the same fallback, dropping valid payloads. Reworded §5.2 to
  specify **key-presence** semantics via `Map.fetch/2` + `case`,
  with an explicit "implementation trap — do not use `or` over
  `Map.get/2`" callout. Phase B's runtime already implements this
  correctly (regression test covers `structuredContent: false`); the
  spec wording is brought into agreement with the implementation.
  No code change needed; this is documentation-only.
- 2026-05-09 (review pass 11 — implementation phasing). Added §11
  "Implementation Phases" specifying a three-phase ship plan
  (A: JSON primitives, B: MCP unwrap helpers, C: aggregator
  auto-decode), each with explicit Scope / Decisions required /
  DoD / Codex review gate. Mirrors the §11.7 + §12 layout from
  `Plans/ptc-runner-mcp-aggregator.md` so engineers familiar with
  that spec see a consistent shape. Each phase is independently
  shippable: Phase A alone gives default-mode programs `json/*`;
  Phase B adds MCP unwrap helpers; Phase C adds auto-decode. The
  recommended assignee is an Engineer subagent (TDD discipline,
  CLAUDE.md "failing test before fix"). OQ-5's analyzer-dispatch
  decision is owned by Phase A's engineer (documented in PR body).
  Codex review questions are explicitly per-phase and target the
  highest-risk pieces: pre-validation walk for Phase A,
  `mcp/json` precedence for Phase B, pipeline ordering and the
  `:decode_failed`-no-`upstream_calls` invariant for Phase C.
  Cross-phase invariants (no try/catch in eval paths, doctest
  module paths, no `String.to_atom/1` on user input, domain-blind
  prompts) are listed once in §11.4 so codex re-checks them on
  every gate.
  Document History was renumbered §11 → §12 to make room.
- 2026-05-09 (review pass 10 — prompt minimalism). Trimmed §10.1,
  §10.2, §10.3 prompt copy. Principle: the LLM already knows what
  "parse JSON" / "generate JSON" do from training; the prompt's
  job is to advertise **existence** and the few **non-obvious
  twists** (`nil`-not-raise, `mcp/json` `structuredContent`
  precedence, string keys). Per-helper detail like the
  non-encodable-input list (atoms, tuples, PIDs) and the
  `cheshire.core/...`-not-aliased redirect were dropped from the
  prompts: the analyzer error message (§10.4) and runtime `nil`
  returns surface those at the moment they matter, without
  per-prompt repetition. Aggregator card section: 10 lines → 5.
  Default card: 3 lines → 1. Reference `<json>` block: 11 lines → 2.
- 2026-05-09 (review pass 9 — prompt surface). Added §10 "Prompt
  and Tool-Description Updates" covering the four prompt files +
  one analyzer message that need to change so LLMs actually
  discover the new builtins. Key decisions:
  (a) **Aggregator authoring card** (§10.1) gets a 10-line "JSON
  helpers" section listing `json/parse-string`, `json/generate-string`,
  `mcp/text`, `mcp/json` with one-line semantics each — the primary
  surface where MCP-using LLMs read about the language.
  (b) **Default authoring card** (§10.2) gets a single bullet
  mentioning `json/*` only (no MCP results to unwrap in default
  mode). Keeps the card short.
  (c) **`priv/prompts/reference.md`** (§10.3) gets a `<json>` block
  paralleling the existing `<java_interop>` and `<restrictions>`
  blocks. Same edit also fixes the misleading "namespaces NOT
  available" wording in `<restrictions>` — the restriction is on
  *declaring* new namespaces (`ns` / `require`), not on using the
  fixed `tool/` / `data/` / `clojure.string/` / `json/` / `mcp/`
  allowlist. Every new namespace addition makes the old wording
  more confusing; folded the fix into this PR.
  (d) **Analyzer "unknown namespace" error message** (§10.4) is
  hardcoded to mention only `tool/` and `data/`. After adding
  `json/` and `mcp/`, an LLM that tries `(cheshire.core/parse-string
  ...)` (the dominant Clojure JSON library in training data) gets
  pointed at the wrong namespaces. Updated message enumerates the
  full allowlist plus an explicit Cheshire→`json/parse-string`
  redirect.
  (e) **No aliasing of `cheshire.core/...` or
  `clojure.data.json/...`** in v1 (§10.5 table). The analyzer
  message redirects; aliasing would pollute the namespace allowlist
  with vendor names. Revisit only if a specific wrong-name attempt
  becomes a recurring failure mode in telemetry.
  (f) **No change** to `@mcp_aggregator_description` in `tools.ex`
  (§10.6) — the single-line tool pitch shouldn't crowd out the
  `tool/mcp-call` framing; the authoring card already extends it.
  Section §4.4's prompt-audit bullet was rewritten to point at §10
  rather than duplicate the instructions inline.
- 2026-05-09 (review pass 8 — codebase-grounded review). Five
  substantive findings folded; several smaller edits.
  (1) **§5.2 `mcp/json` semantics changed**. Old version mirrored
  `(json/parse-string (mcp/text result))` exactly, so it returned
  `nil` whenever an upstream populated `structuredContent` with a
  human-readable summary in `content[0].text` — exactly the case
  the helper was supposed to make ergonomic. New semantics: prefer
  `structuredContent` if present and non-`nil`, otherwise fall back
  to text-parse. §6.2's worked example updated for the new
  `:json-null` propagation table. §4.1's ambiguity note rewritten
  to reflect that `mcp/json` no longer universally collapses.
  (2) **§6.4 wire-amplification claim corrected.** Old wording
  ("auto-decode does not amplify the payload because the original
  `content[]` is also retained") was misleading: keeping both
  `content[]` AND `structuredContent` means the JSON-RPC response
  envelope ships ~2× the text-content bytes back to the MCP client.
  The `max_response_bytes` upstream cap bounds the upstream-side
  ingress, not the response-side egress. New wording is honest
  about the doubling. §8 gains a wire-amplification spot-check.
  (3) **OQ-3 stub added** between OQ-2 and OQ-4 so the numbering
  gap from "promoted to §4.4 implementation rule" doesn't leave a
  hole for readers scanning §9.
  (4) **§4.3 NaN/Infinity carve-out** added. The constants resolve
  to non-encodable atoms (`:infinity`, `:negative_infinity`,
  `:nan`) and `json/generate-string` returns `nil` on them. The
  round-trip property's "JSON scalars" carve-out implicitly
  excluded these, but a one-paragraph note prevents the
  surprised-LLM case where arithmetic produces these values and
  serialization mysteriously fails.
  (5) **§4.4 step 3 registry-entry shape clarified.** Sketch now
  shows a full `name: "json/parse-string"` entry (with the slash
  and `category: :json`), spelling out the asymmetry vs
  `clojure.string/X` (which uses unqualified `name: "join"` because
  the env key is `:join`). Step 1 also gains explicit `:json` and
  `:mcp` category mappings + `Registry.category_name/1` clauses so
  the analyzer's "did you mean" suggestion renders cleanly.
  Smaller edits: §2 glossary line for `:json-null` notation
  (PTC-Lisp `:json-null` ↔ Elixir `:"json-null"`); §4.1 note that
  Elixir integers are arbitrary precision; §5.5 caveat that
  `nil`-on-misuse can cascade silently; §5.1 wording cleanup;
  §6.4 line-number anchor replaced with function/branch anchor
  that won't rot; §8 explicit `:decode_failed`-no-`upstream_calls`
  side-channel test; §9 `fs.read_multiple_files` qualified as a
  "documented external upstream, not a repo fixture"; OQ-6's
  `mcp/json-at` v2 helper now explicitly inherits §5.2's
  `structuredContent`-first precedence.
- 2026-05-09 (review pass 7 — F1/F2/F3 + D1 + big-JSON):
  Five findings folded.
  (1) **F1**: §4.3 round-trip property was too generous — integer
  keys legitimately stringify and would falsify the property as
  written. Restricted to string-keyed inputs; added an explicit
  integer-key carve-out documenting the asymmetry.
  (2) **F2**: §5.1's bullet about returning `nil` for "the
  `:json-null` sentinel" was vacuous (the sentinel is a keyword,
  not a map, so it could never match the `content[0]` shape). Folded
  the sentinel into the general "any non-conforming input" rule.
  (3) **F3**: §6.4 didn't say what `:decode_failed` does to
  `upstream_calls`. Locked in v1 behavior: silent for the program,
  no `upstream_calls` entry, telemetry-only. Side-channel reserved
  for world-faults per §7.1.
  (4) **D1**: §4.4 now mandates two new entries in
  `docs/clojure-conformance-gaps.md` (DIV-23 / DIV-24) covering the
  raise-vs-nil divergence (parse) and the silent-stringify-vs-nil
  divergence (encode). The spec invoked the convention but never
  said "add the catalog entry" — closed the loop. Same step also
  adds `priv/prompts/` audit guidance, aggregator-spec
  cross-reference, and changelog entries.
  (5) **Big-JSON**: §3 now explicitly notes that v1 fails on inputs
  exceeding the post-parse 10 MB sandbox cap (no graceful handling).
  New OQ-6 captures the v2 path: `json/decode-at` + `mcp/json-at`
  built on `jaxon` SAX events with path-projection. Ship trigger:
  first observed v1 failure on a real upstream payload, not
  preemptive.
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
