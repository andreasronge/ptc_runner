# Runtime validation and readable prompt rendering for PTC-Lisp contracts

Status: implemented. Created 2026-07-18 after auditing the prelude
compiler/evaluator, the surviving `PtcRunner.Lisp.Signature` runtime validator,
the Kernel capability dispatcher, and the removed SubAgent return-validation
loop.

This plan makes the optional `:signature` and `:type` metadata on public
PTC-Lisp prelude exports executable contracts instead of prompt-only metadata,
and uses those same contracts to replace the compact JSON block in the default
system prompt with a readable prelude-rendered `Available API` list.
For a fixed-arity function such as:

```clojure
(defn search
  {:signature "(query :string) -> {items [:string]}"}
  [query]
  ...)
```

the evaluator will reject a non-string `query` before entering `search`, and it
will reject a successful function result whose shape does not match
`{items [:string]}`. The same checks will apply whether the export is called
directly or passed as a higher-order function.

The existing JSON Schema checks remain authoritative at raw capability
boundaries. Prelude signatures add an earlier, model-facing contract at the
mission API boundary; they do not replace capability validation, grants, or
resource limits.

The presentation boundary remains swappable: Elixir freezes bounded structured
mission data, while the editable `agent.prompt` prelude owns its model-facing
text. `agent.core` continues to know only that it must request a rendered
system prompt.

## Supported declaration syntax

PTC-Lisp does not currently implement Clojure's `^` reader-metadata syntax.
Prelude contract metadata is an ordinary keyword-keyed map in the supported
`defn`/`def` declaration grammar.

A function without a docstring uses:

```clojure
(defn search
  {:signature "(query :string, limit :int?) -> {items [:string]}"}
  [query limit]
  ...)
```

With a docstring, the metadata map follows the docstring:

```clojure
(defn search
  "Search the configured document source."
  {:signature "(query :string) -> [{id :string, title :string}]"
   :effect :read}
  [query]
  ...)
```

A constant uses `:type` rather than `:signature`:

```clojure
(def answer
  "The configured answer."
  {:type ":int"}
  42)
```

The metadata map is PTC-Lisp data, while the contract itself is a string in
the separate signature grammar. Multiple parameters and map fields in that
string are comma-separated. `:string?`/`:int?` means the value may be `nil`; it
does not make a positional function argument optional. The current type
vocabulary is `:string`, `:int`, `:float`, `:bool`/`:boolean`, `:keyword`,
`:map`, `:datetime`, `:any`, lists such as `[:string]`, and shaped maps such as
`{id :string, title :string?}`.

## Why this work is needed

### The previous metadata promised more than the evaluator enforced

Before this work, the prelude compiler parsed a declared function signature,
canonicalized it, and checked that its parameter count equaled the function's
fixed arity. The analyzer subsequently checked only the number of arguments in
a call. The evaluator carried the export record to the invocation boundary but
did not consult its signature.

Consequently, given:

```clojure
(defn search
  {:signature "(query :string) -> [:string]"}
  [query]
  ...)
```

these calls had different outcomes:

| Program | Current check | Current result |
| --- | --- | --- |
| `(api/search)` | arity | rejected before evaluation |
| `(api/search "cats")` | arity | admitted |
| `(api/search 42)` | arity | admitted because it still has one argument |
| `(map api/search queries)` | callable arity | admitted; export type metadata is not enforced |

The mission inventory and model-context renderer can display the signature as
the documented mission API contract. Without runtime enforcement, that
contract may be useful guidance but is not trustworthy execution semantics.

### The previous system prompt exposed data rather than an API

`agent.prompt/render` appended this heading and a compact JSON value:

```text
Mission API and limits (deterministic JSON)
{"schema_version":1,"mission_api":[...],"direct_capabilities":[...],"limits":{...}}
```

The JSON is deterministic and machine-readable, but it is a poor default
model-facing explanation:

- call forms, documentation, types, and limits compete inside one dense line;
- missing documentation appears as `"doc":null`;
- wrapper signatures retained by the authoritative inventory are not included
  in the current compact `mission_api` entries;
- direct capability schemas dominate the text even when a short PTC-Lisp type
  shape would teach the call more clearly; and
- JSON field names such as `schema_version` describe the transport contract,
  not the task the model must perform.

The deterministic structure should remain the frozen source of truth, but an
editable prelude should render its model-facing presentation.

### Runtime signature validation already exists

`PtcRunner.Lisp.Signature` already supports:

- parsing and canonical rendering;
- strict input validation with `validate_input/2`;
- strict return validation with `validate/2`;
- nested path errors for maps and lists;
- primitive, collection, optional, map, closed-map, keyword, and datetime
  types; and
- conversion to and from the supported JSON Schema subset.

The generic Lisp runner still uses it for private-tool arguments and optional
top-level result validation. This work should reuse that implementation rather
than introduce a second type system.

### JSON Schema catches the error at the wrong abstraction boundary

A wrapper may eventually pass a bad value to a raw capability. The Kernel
dispatcher then rejects invalid arguments against the capability's input JSON
Schema before invoking the provider. That remains necessary, but it is not a
substitute for a prelude contract:

- a pure PTC-Lisp export may call no capability at all;
- a wrapper may transform or combine values before making several capability
  calls;
- the capability error names the raw transport operation rather than the
  documented mission API call; and
- a wrapper's declared return type has no downstream input schema to enforce
  it.

Input validation at the public export boundary produces a more direct error
and prevents the wrapper body, including capability side effects, from
starting.

### The old SubAgent behavior was real but belonged to another boundary

The removed SubAgent loop accepted an agent-level result signature, validated
the value from an explicit `(return ...)`, formatted an actionable error, and
gave the model another turn. For example, `() -> :int` rejected
`(return "54")`, after which the model could correct it to `(return 54)`.

That behavior proves the signature language is capable of runtime validation.
It does not mean a prelude export signature currently validates the mission's
final `(return ...)`: an agent result contract and a prelude function contract
are different boundaries. This plan restores runtime checking for prelude
exports. A configurable final mission-result contract is listed separately
under follow-up work.

## Current and planned contract layers

| Layer | Contract | Current authority | Planned change |
| --- | --- | --- | --- |
| Prelude declaration | PTC-Lisp signature syntax | prelude compiler | unchanged |
| Prelude call count | function arity | compiler and analyzer | unchanged |
| Prelude argument values | PTC-Lisp signature input types | not enforced | validate before function entry |
| Prelude successful result | PTC-Lisp signature return type | not enforced | validate after function completion |
| Prelude constant value | PTC-Lisp `:type` metadata | syntax only | validate once while compiling the artifact |
| Raw capability input/output | JSON Schema | Kernel dispatcher | unchanged and still authoritative |
| Mission final result | no configurable result contract | none | out of scope for this slice |

## Design decisions

1. **Contracts remain optional.** An export without `:signature` or `:type`
   keeps its existing behavior. Adding a contract opts that export into runtime
   checking.
2. **Validation is strict and does not coerce.** A string containing `"42"`
   is not an integer. Any future coercion policy must be explicit and separate;
   implicit coercion would hide model mistakes and diverge from capability JSON
   Schema behavior.
3. **Compile once, validate many times.** The compiler retains a parsed,
   bounded signature/type representation in the frozen export artifact while
   preserving the canonical string used by inventories and prompt rendering.
   Runtime calls must not reparse the signature text.
4. **Argument names come from the signature; values remain positional.** For
   validation, the evaluator zips the parsed signature parameter names with
   evaluated positional arguments. Existing compile-time arity equality makes
   that mapping total for fixed-arity functions.
5. **Optional does not mean omitted.** `(query :string?)` still occupies one
   positional argument; it accepts `nil`. Call arity remains the analyzer's
   responsibility.
6. **Validate input before entering the body.** A failed input contract must
   execute no private helper, capability, print, memory mutation, or call-count
   increment attributable to entering the export.
7. **Validate every public invocation path.** Direct calls such as
   `(api/search q)` and value-position/higher-order calls such as
   `(map api/search queries)` must share one enforcement owner. Private sibling
   helpers are not public exports and receive no implicit checks.
8. **Validate every successful exit from an export.** An ordinary returned
   value is checked. An export-local `(return value)` is also checked before the
   whole-program return continues, so it cannot bypass the public contract. A
   `(fail value)` control signal is not checked against the success type.
9. **Constant contracts fail during compilation.** A public `def` is immutable
   in the compiled artifact, so its declared `:type` should be checked once
   after the runtime environment is built. An invalid constant rejects the
   component instead of failing repeatedly whenever it is read.
10. **Errors are bounded, structured, and model-readable.** Contract failures
    use a stable evaluation-error classification and include the public export
    ref, phase (`input` or `output`), bounded validation paths, expected
    contract, and a concise actual-type description. They never include the
    private prelude environment or source. Validation short-circuits at the
    installed error budget instead of materializing an unbounded error list;
    compile-time constant diagnostics use the same bound.
11. **Capability JSON Schema remains defense in depth.** A hidden raw
    capability can still be called by exact granted name, and wrappers can be
    wrong. The dispatcher continues validating raw inputs and outputs
    independently.
12. **A contract is not authority.** It cannot grant a capability, expand a
    root path, increase a quota, or make a hidden capability discoverable.
13. **Structured data and prompt text have different owners.**
    `MissionInventory` freezes the bounded authoritative projection and its
    hashes. `agent.prompt` parses that frozen value and owns headings, layout,
    omission rules, and wording. `agent.core` owns neither.
14. **Missing optional metadata produces no placeholder text.** Every visible
    call always retains its exact call form. A type line is shown
    only when type information exists, and a documentation line is shown only
    when the documentation is non-blank. The renderer never emits `null`,
    `unknown`, or an empty label merely to fill space.
15. **The default prompt presents one facade, not an architectural taxonomy.**
    When any prompt-visible prelude function exists, prelude functions and
    constants form the complete `Available API` and raw `tool/...` entries are
    omitted. With no prompt-visible prelude function, direct capabilities are
    rendered. Callable entries use `Call`; constants use `Value` so the model
    is not taught to invoke a value. The frozen context retains all entries;
    omission is swappable `agent.prompt` presentation policy, not authority.
16. **One model contract, source-specific authorities.** The model sees one
    versioned contract vocabulary regardless of call origin. A prelude
    contract remains authoritative for its wrapper boundary, while full JSON
    Schema remains authoritative for a raw capability. The shared projection
    must retain every constraint needed to construct a valid call; it is not a
    replacement runtime validator.
17. **Types are labeled honestly.** A prelude `Type:` is its exact
    runtime-enforced contract after this plan lands. For `tool/...`, the input
    is the one argument map and the displayed return type describes the
    successful `:value`; one general prompt rule explains the surrounding
    result envelope. Constraints outside the current PTC-Lisp signature grammar
    are rendered explicitly rather than silently discarded.

## Invocation and error semantics

### Input mismatch

For:

```clojure
(defn search
  {:signature "(query :string, limit :int?) -> {items [:string]}"}
  [query limit]
  (tool/search {"query" query "limit" limit}))
```

this is valid:

```clojure
(api/search "cats" nil)
```

and this fails before `tool/search` is invoked:

```clojure
(api/search 42 nil)
```

The public error should have a stable shape equivalent to:

```elixir
%{
  outcome: :evaluation_error,
  kind: :prelude_contract_error,
  details: %{
    ref: "api/search",
    phase: :input,
    message: "api/search input query: expected string, got int"
  }
}
```

The exact internal tuple may follow existing Lisp error conventions, but the
Kernel projection and feedback text must be deterministic and bounded.

### Output mismatch

If the same export successfully evaluates to:

```clojure
{:items "cats"}
```

the output contract fails at path `items` because a list was expected. This is
an evaluation failure, not a successful value and not a capability result
envelope.

Output validation happens after the function body. Memory from a failed
subordinate evaluation can be rolled back, but external capability effects
cannot be. Therefore an output-contract failure is not automatically safe to
retry. The agent integration must preserve this distinction:

- an input-contract failure is corrective model feedback and is retryable only
  when the complete evaluation recorded no capability activity;
- an output-contract failure after zero recorded capability calls is
  retryable; and
- an output-contract failure after any recorded capability call is
  non-retryable, regardless of the declared effect.

`Kernel.Evaluation` exposes this as a stable `retryable?` classification and
`agent.core` follows it for contract failures instead of inferring policy from
error text. Existing retry behavior for unrelated evaluation failures remains
unchanged. The implementation must not claim that the `effect` documentation
hint alone provides rollback or idempotency.

### Direct and higher-order calls

The same validation must apply here:

```clojure
(api/search query)
(map api/search queries)
(let [f api/search] (f query))
```

The preferred enforcement seam is the actual application of a closure tagged
as a public prelude export. `Eval.bind_prelude_ref/2` already tags such
closures, and both direct and value-position calls eventually pass through the
callable application machinery. Contract metadata should travel with that
tag, while private internal closures remain untagged for contract purposes.

Contract enforcement must happen exactly once per public invocation. Existing
prelude call counts and capability ledgers must not be double-incremented.

## Relationship to JSON Schema

PTC-Lisp signatures and JSON Schema overlap but serve different APIs:

```text
model-authored PTC-Lisp
        |
        | prelude signature: documented mission API values
        v
public prelude wrapper
        |
        | JSON Schema: raw granted capability payload
        v
Kernel dispatcher and provider
```

For transparent one-capability wrappers, the two contracts may describe
similar data. They still must both run because raw capabilities remain callable
when granted, and wrapper implementations may transform values. General
wrappers can compose several capabilities or expose a deliberately smaller
API, so the compiler cannot generally infer or require equality between a
wrapper signature and one capability schema.

Both authorities are normalized into the shared model-contract vocabulary for
prompt rendering. Full JSON Schema remains at the raw capability boundary and
in host inspection data; the projection does not replace it.

## Prelude-rendered available API

### Implemented default prompt shape

The default system prompt will no longer include the heading
`Mission API and limits (deterministic JSON)` or expose the compact JSON as its
primary presentation. `agent.prompt/render` will produce a stable readable
section such as:

```text
Available API

- Call: (tutorial.files/read-text path)
  Type: (path :string) -> :string
  Effect: read
  Docs: Read one UTF-8 file beneath the configured mission root.
```

`Available API` is rendered even when there are no prompt-visible exports or
model-visible raw capabilities, giving the Viewer one canonical prompt shape.
A prompt-visible prelude function selects facade mode and suppresses every raw
capability entry. Without a prelude function, raw capabilities are rendered
with the `tool/...` map/envelope convention. `Effect:` is omitted for
`unknown`; it is not rendered as a placeholder. Numeric limits remain in the
frozen context and Viewer but are not rendered by the default prompt.

For an export with no signature and no documentation, the exact call remains:

```text
Available API
- Call: (tutorial.files/read-text path)
```

It does not grow empty `Type:`, `Constraints:`, `Effect:`, `Docs:`, `null`, or
`unknown` lines. If only one optional field exists, only that line is shown.

The renderer does not guess whether individual operations have equivalent
meaning. Instead it applies one structural rule: a prompt-visible mission
function makes the entire mission prelude the public facade. A custom prompt
prelude may render the frozen raw entries as well for diagnostics.

### Prelude ownership

The existing installed `agent.prompt` prelude is the first renderer. It will:

1. obtain the frozen model-context JSON through
   `kernel/mission-model-context`;
2. decode it with the bounded PTC-Lisp JSON parser;
3. sort the already-normalized model-contract entries by exact call/value form;
4. select the prelude facade when a prompt-visible mission function exists;
5. emit the `tool/...` map/envelope convention once in direct-capability mode;
6. omit limits and absent, blank, or unknown optional fields; and
7. return the complete system prompt to `agent.core`.

This does not require another hard-coded renderer in `agent.core`. Editing the
prelude changes presentation for newly compiled bundles, while an already
frozen run remains immutable. If mission-context presentation later needs to
vary independently of the rest of the prompt, the private renderer helpers can
be extracted into an `agent.mission-context` prelude without changing the
`agent.core` API.

The prelude must not receive live capability callbacks or private environment
state. It sees only the same bounded public projection already exposed by the
reserved Kernel runtime route.

### Frozen data contract

`MissionInventory` remains responsible for building and bounding two values:

- the authoritative V2 inventory used for host inspection and hashing; and
- a compact, versioned model-contract projection intended for the prompt
  prelude to decode.

Prelude contracts and raw capability schemas have different runtime
authorities, but `MissionInventory` normalizes both into the same bounded call
record before freezing the model context. The projection contains structured
type and constraint nodes, not preformatted `Type:` or `Constraints:` text, so
an editable prompt prelude can change the wording without reinterpreting raw
prelude source or JSON Schema. A representative abbreviated value is:

```json
{
  "schema_version": 2,
  "entries": [
    {
      "kind": "call",
      "form": "(tutorial.files/read-text path)",
      "contract": {
        "parameters": [{"name": "path", "type": {"kind": "string"}}],
        "returns": {"kind": "string"}
      },
      "effect": "read",
      "docs": "Read one UTF-8 file beneath the configured mission root."
    },
    {
      "kind": "call",
      "form": "(tool/fs-read {\"path\" path})",
      "contract": {
        "parameters": [{
          "name": "arguments",
          "type": {
            "kind": "object",
            "closed": true,
            "fields": [{
              "name": "path",
              "required": true,
              "type": {"kind": "string", "min_length": 1}
            }]
          }
        }],
        "returns": {
          "kind": "object",
          "closed": true,
          "fields": [
            {"name": "bytes", "required": true, "type": {"kind": "integer", "minimum": 0}},
            {"name": "content", "required": true, "type": {"kind": "string"}},
            {"name": "path", "required": true, "type": {"kind": "string"}}
          ]
        }
      },
      "effect": "read",
      "docs": "Read one bounded UTF-8 file beneath the configured root."
    }
  ],
  "limits": {
    "evaluation_timeout_ms": 1000,
    "subordinate_source_bytes": 131072,
    "mission_capability_calls": 128,
    "mission_capability_calls_per_name": 32,
    "capability_argument_bytes": 262144,
    "capability_result_bytes": 1000000
  }
}
```

The exact contract-node schema must be specified beside its implementation and
cover the complete normalized capability-schema profile: primitive and null
types, objects, arrays, required fields, `additionalProperties`, `enum`,
`const`, numeric bounds, and string/array size bounds. Property order is
canonicalized. Null optional record fields may remain valid for stable
encoding, but the prelude never renders them. Alternatively, the projection
may omit absent optional keys if that rule is deterministic and versioned.
Tests must freeze whichever representation is selected.

The node schema represents field presence and value nullability independently.
In rendered map types, `"limit"? :int` means the field may be omitted while
`"limit" :int?` means the field is required but may contain `nil`; both markers
may be combined. This is intentionally more precise than today's author-facing
signature grammar, where an optional shaped-map type permits both omission and
`nil`. Raw JSON Schema optionality must never be rendered as nullable.

The current `mission_model_context_hash` continues to identify this exact
structured projection, not the complete system prompt. The exact rendered
system prompt remains private LLM-request input and is captured by the
inspection overlay. Changing prelude wording changes the frozen component and
bundle hashes even when the mission-data hash is unchanged.

### Shared model-contract and rendering rules

For public prelude exports:

- project the already-parsed canonical `Export.signature` or constant
  `Export.type` AST into the shared contract nodes;
- do not reconstruct a signature from parameter names or documentation; and
- ship prompt rendering together with runtime enforcement so `Type:` does
  not overstate advisory metadata.

For direct raw capabilities:

- convert the complete accepted normalized JSON Schema profile into the shared
  contract nodes without dropping enum/const values, numeric bounds, size
  bounds, required/optional fields, arrays, nulls, or closed-map semantics;
- keep this projection display-only and separate from the compiled JSON Schema
  used for runtime validation;
- fail bundle/model-context construction for a model-visible capability if its
  accepted schema cannot be represented losslessly, instead of publishing a
  misleading partial contract;
- retain exact argument-map call syntax in addition to the structured
  contract; and
- keep full input/output JSON Schema in the authoritative inventory and at the
  dispatcher boundary.

The raw capability's display signature has one named `arguments` parameter
whose type is the projected input object. Its displayed return type is the
successful provider value, not the whole Dispatcher envelope. The single
`tool/...` convention above owns that qualification so it is not repeated for
every call.

The `Type:` line uses one compact PTC-Lisp-oriented vocabulary for every call.
Constraints not expressible in today's signature grammar are rendered from
structured nodes on a bounded `Constraints:` line. Initially these include
enum/const values, numeric bounds, string/array size bounds, and closed-map
semantics. Closed and open maps may therefore share the same compact type shape
while `Constraints:` states `no additional fields`. A direct capability call
is still checked against its complete JSON Schema before provider invocation.

Schema property names are data, not trusted prompt syntax. Object field names
in type rendering use deterministic JSON string escaping. Exact call examples
also escape map keys and use the field name as a placeholder only when it is a
valid, collision-free PTC-Lisp symbol; otherwise stable placeholders such as
`value1` are assigned after canonical field sorting. Newlines, control
characters, quotes, spaces, or heading-like property names must never escape a
single rendered field. Capability input-property names that change under the
Lisp tool boundary's recursive hyphen-to-underscore normalization are rejected
during assembly, including collisions such as `user-id` plus `user_id`, so an
advertised exact call cannot be invalid solely because the boundary rewrote its
keys. The same recursive check covers object keys inside input `const` and
`enum` values. This restriction applies only to capability inputs, not provider
output schemas.

Prelude signature parameter names must be unique. Shaped-map field names must
also be unique after the validator's existing key normalization, so aliases
such as `user-id` and `user_id` cannot address the same runtime field with two
different contracts. These ambiguities fail prelude compilation.

Effects are likewise normalized when the mission environment is frozen, where
both reusable prelude metadata and the selected host capabilities are known.
Raw calls use their authoritative capability effect. Wrapper effects are the
conservative join of explicit metadata and transitive callable dependencies:
`write` dominates `read`, while an unresolved dependency produces `unknown`
rather than a guessed `read`. Explicit metadata may strengthen the result but
cannot lower a dependency-derived effect; an understatement is corrected in
the frozen projection rather than rejecting an otherwise reusable prelude.
Invalid effect metadata still fails prelude compilation. `unknown` is omitted
from the prompt, and effect remains documentation, not authority or rollback
semantics. The resolved value is included in the frozen model-context hash.

### Determinism, safety, and bounds

Determinism must not depend on BEAM map iteration or decoded JSON insertion
order. Exact golden tests will prove that semantically identical projections
with shuffled map/array order render identically after explicit sorting.

Deployment-authored documentation, descriptions, property names, enum/const
values, and other schema-derived values are prompt content. The projection
already bounds them; the renderer must additionally escape or normalize each
field according to its context so one entry cannot counterfeit a new section
heading. It must preserve Unicode and measure the final prompt against the
existing LLM request byte limit before invoking a provider. If the complete
request is too large, evaluation returns the stable request-size error before
provider invocation; contracts and constraints are never truncated.

The raw authoritative inventory and compact structured projection remain
available through Kernel inspection/runtime surfaces. They are not duplicated
in the default model prompt behind a second disclosure because the model has no
disclosure UI; developers can inspect the captured request and inventory in the
Viewer.

## Implementation plan

### Phase 1: Lock the behavior with failing integration tests

1. Add a prelude integration fixture with a signed fixed-arity export and an
   observable body/capability callback.
2. Prove a wrong primitive input fails before the callback and before wrapper
   body effects.
3. Cover nested maps, lists, optional values, keyword values, and path
   rendering using the existing signature vocabulary.
4. Prove a wrong successful return is rejected and a correct return is
   unchanged.
5. Run the same contract through direct, bound-function, `map`, and other
   supported higher-order invocation paths.
6. Prove an unsigned export remains behaviorally unchanged.
7. Add constant `:type` success and compile-failure cases.
8. Add regressions for contract errors inside `pmap`/parallel evaluation so
   worker cleanup and bounded error propagation remain intact.

### Phase 2: Retain the compiled contract

1. Extend `PtcRunner.Lisp.Prelude.Export` with internal parsed contract fields
   or an equivalent bounded compiled representation.
2. Have `Prelude.Compiler` parse once, retain the AST, and derive the canonical
   display string from that AST.
3. Preserve the canonical contract string in the authoritative inventory and
   keep parsed tuples internal. Phase 5 projects those tuples into bounded
   shared model-contract nodes rather than exposing internal tuples or asking
   the prompt prelude to parse the signature string.
4. Validate public constant values after `build_runtime/3` has produced the
   namespace environment and before returning a compiled `%Prelude{}`.
5. Keep deterministic hashes based on source and existing bundle inputs; do not
   add runtime-dependent data to compilation.
6. Reject duplicate signature parameters and normalized shaped-map field-name
   collisions during contract parsing/compilation.

### Phase 3: Add one runtime enforcement owner

1. Introduce a small prelude-contract helper around
   `PtcRunner.Lisp.Signature` for positional input mapping, output validation,
   and bounded error formatting.
2. Attach the compiled contract when a public export closure is bound.
3. Validate arguments immediately before closure execution.
4. Validate the ordinary successful result before returning it to the caller.
5. Cover direct calls and escaped/value-position calls in the shared callable
   application path rather than duplicating checks in `Eval` and `Apply`.
6. Preserve caller/private namespace isolation, tool ledgers, call counts,
   caches, iteration accounting, and abort-signal context restoration.
7. Validate an export-local `(return ...)` before propagating the successful
   whole-program return; let `(fail ...)` propagate without success validation.

### Phase 4: Feed safe correction information to `agent.core`

1. Project the stable contract-error kind and bounded public details through
   `Kernel.Evaluation`.
2. Update `agent.feedback/evaluation-error` to render the export ref, phase,
   path, and expected/actual information without raw internal tuples.
3. Classify both input and output contract errors from the authoritative
   per-evaluation capability-call delta. An input error still occurs before its
   selected wrapper body, but prior top-level or higher-order calls make the
   complete evaluation unsafe to retry.
4. Add a deterministic two-response fake-LLM integration test: the first
   generated program passes a wrong argument, feedback identifies the public
   mission API contract, and the second program corrects it.
5. Add a no-retry regression for an output mismatch after any recorded
   capability call, proving the agent cannot silently duplicate even an
   operation labeled `read`.

No live provider call or newly generated trace is required for this correctness
gate. A later DeepSeek smoke run may verify prompt comprehension and Viewer
presentation, but deterministic integration tests own the contract.

### Phase 5: Replace compact JSON with the unified prelude renderer

1. Specify and implement the versioned shared model-contract node schema.
   Project parsed prelude contracts and complete normalized direct-capability
   schemas into it without preformatting prompt text.
2. Improve exact direct-capability call forms to show the single argument map
   with JSON-escaped keys and stable collision-free field placeholders when its
   object schema permits it.
3. Increment the compact model-context schema/rendering version without
   changing the authoritative inventory version or hash meaning.
4. Include the resolved effect and all supported constraints in each frozen
   API entry and in model-context hashing. Resolve wrapper effects against the
   selected mission capabilities; explicit metadata may strengthen but cannot
   lower the resolved value.
5. Add private renderer helpers to `agent.prompt` that render functions/tools
   as `Call`, constants as `Value`, and all entries with the same
   `Type`/`Constraints`/`Effect`/`Docs` fields; sort them, render the one
   conditional `tool/...` convention and optional-field/nullability convention,
   omit absent lines, select the prelude facade when present, and omit limits.
6. Remove `Mission API and limits (deterministic JSON)` from the default prompt
   and append `Available API` instead.
7. Add golden tests for ordinary, empty, missing-doc, missing-type,
   missing-effect, wrapper-only, tool-only, mixed, enum/const, numeric and size
   bounds, closed maps, hostile/unusual property names, Unicode/control
   characters, shuffled order, unrepresentable schemas, and maximum bounded
   projections.
8. Prove an oversized final request fails before provider invocation and is
   never partially rendered or truncated.
9. Verify captured private system text contains the readable form while the
   canonical metadata retains the structured context hash and byte count.
10. Compare prompt bytes/tokens and scripted-model correctness before and after;
   readability and valid generated programs are the gate, not size alone.
11. Verify the default prompt selects wrapper-only facade mode while a
   swappable diagnostic prompt can still render the complete frozen context.
12. Render the `Available API` heading even when the frozen entry list is
    empty, so the default prompt keeps one canonical Viewer-readable shape.
13. Render bounded nested JSON Schema `title`/`description` annotations with
    their argument or return paths; field semantics must not disappear when
    full raw schemas are replaced by readable type summaries.
14. Canonically order JSON Schema `enum` members by deterministic JSON bytes,
    because member order has no validation meaning and must not perturb the
    frozen model-context hash.

### Phase 6: Update documentation and examples

1. Document inline `{:signature ...}` function metadata and `{:type ...}`
   constant metadata as enforced runtime contracts in the Kernel maintainer
   guide and PTC-Lisp specification; explicitly state that `^` reader metadata
   is unsupported.
2. Explain syntax validation, arity validation, and value validation as three
   distinct stages.
3. Update the Kernel tutorial's mission wrapper with a truthful docstring and
   signature so `Available API` demonstrates the feature.
4. State that optional positional parameters accept `nil` but are not omitted.
5. Document strict validation, retry classification, and the lack of rollback
   for external effects.
6. Keep capability JSON Schema documentation as the raw authority boundary.
7. Show the readable `Available API` prompt format and explain that
   `agent.prompt` owns presentation over frozen structured data.

## Acceptance criteria

1. A malformed signature or signature/function arity mismatch still fails
   prelude compilation.
2. A signed export rejects a wrong argument value before its body or any
   capability callback runs.
3. A signed export rejects a wrong successful result with a bounded path-aware
   error.
4. Correct calls preserve their exact values and existing effect accounting.
5. Direct and higher-order calls enforce the same contract exactly once.
6. Unsigned exports retain current behavior and cost no signature parse per
   call.
7. A mistyped constant rejects component compilation rather than failing when
   read.
8. Contract failures reveal no private prelude names, source, environments, or
   capability payloads.
9. Raw capability JSON Schema checks remain unchanged and still reject invalid
   direct calls.
10. `agent.core` can retry an input mismatch with actionable feedback only when
    the complete evaluation recorded no capability activity.
11. The agent does not automatically retry an output mismatch after an
    observable capability effect.
12. The default prompt contains one readable `Available API` list without a
    numeric limits block or compact JSON.
13. Missing documentation/type information emits no placeholder line, while
    every visible operation retains its exact call form; unknown effects are
    also omitted.
14. Prelude contracts shown to the model are the same canonical contracts
    enforced at runtime.
15. The `tool/...` convention appears exactly once when needed and accurately
    explains the one-map argument and result envelope.
16. Direct capability type summaries never replace or weaken dispatcher JSON
    Schema validation.
17. Every constraint in the accepted normalized capability-schema profile is
    retained in the shared model contract and rendered when it affects valid
    call construction.
18. Arbitrary schema property names and enum/const values cannot inject prompt
    sections or invalid PTC-Lisp syntax.
19. Closed-map semantics and resolved effects are represented honestly even
    though neither is inferred from the compact base type alone.
20. Reordered equivalent structured inputs produce byte-identical rendered
    mission context.
21. A prompt-visible prelude function selects facade mode and hides all raw
    capabilities from the default rendering without changing their authority.
22. An oversized final request fails before provider invocation without
    truncating any call contract.
23. Optional raw-schema fields are distinguished from nullable values, and
    prompt-visible constants are labeled as values rather than calls.
24. Duplicate signature parameters and normalized shaped-map field aliases are
    rejected at compile time.
25. Export-local `(return ...)` values cannot bypass output validation, while
    `(fail ...)` payloads are not validated as successful results.
26. Contract retry classification is explicit: input and output mismatches
    retry only when the complete evaluation recorded no capability activity.
    The Kernel reads dispatcher accounting before releasing the evaluation
    lease and combines it with evaluator-recorded activity so reserved runtime
    tools cannot be mistaken for a pure evaluation.
27. A contract failure inside `pmap` or `pcalls` preserves the failed worker's
    bounded tool ledger, print ledger, nested parallel records, cache delta,
    and public prelude call counts in the returned error step. It also preserves
    successful worker payloads already received before the failure, including
    when those workers remain alive awaiting their termination signal.
28. An empty mission still renders one empty `Available API` section that the
    Viewer recognizes as the canonical prompt format.
29. Nested direct-capability schema documentation is rendered with stable
    argument/return paths, while absent annotations emit no placeholder.
30. Reordered JSON Schema enum members produce byte-identical model contexts
    and hashes.
31. Internal runtime and constant contracts accept actual Lisp keywords for
    `:keyword`, never ordinary strings that merely look like keyword names.
32. Successful `pmap` and `pcalls` workers preserve bounded tool calls, prints,
    nested parallel records, cache deltas, and public prelude call counts in
    deterministic input order.
33. Capability assembly rejects input-property names that cannot survive tool
    argument normalization, including nested names, normalized collisions, and
    object keys inside `const`/`enum` values.
34. `max_tool_calls` is a program-wide atomic bound shared by direct calls,
    HOF closures, and top-level or nested `pmap`/`pcalls` workers. Cache hits do
    not reserve another invocation.
35. Every parallel failure class preserves the bounded audit effects of
    successful workers completed before the failure, not only contract errors.
36. `mix precommit` passes, including integration coverage for direct, HOF,
    parallel, abort-signal, Kernel projection, and agent correction paths.

## Out of scope and follow-up work

- Extending the signature grammar with variadic/rest parameter types. The
  current compiler supports signed fixed-arity exports; variadic contracts
  need an explicit grammar and validation design rather than treating the rest
  as `:any` implicitly.
- Static whole-program type checking. This plan performs runtime checks at
  public prelude boundaries; ordinary PTC-Lisp remains dynamically typed.
- Inferring wrapper signatures from capability JSON Schema or proving that a
  composite wrapper is schema-equivalent to its dependencies.
- Extending author-written PTC-Lisp signature syntax with inline enum, const,
  numeric/size-bound, or closed-map constraints. The shared model-contract IR
  preserves and renders that bounded information now; a later grammar extension
  may expose the same supported subset to prelude authors without embedding
  general JSON Schema, unions, references, conditionals, or arbitrary
  predicates.
- Coercing strings to numbers, parsing datetimes, or repairing values
  automatically.
- Treating a signature as authorization or capability visibility policy.
- Restoring an agent-level final mission-result contract. If needed, add a
  separate bounded result contract to the agent configuration, validate the
  model-authored final `(return ...)`, and reuse the safe correction loop from
  this work without coupling that contract to an arbitrary prelude export.
