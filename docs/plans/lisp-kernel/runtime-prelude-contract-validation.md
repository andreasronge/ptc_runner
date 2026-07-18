# Runtime validation for PTC-Lisp prelude contracts

Status: proposed. Created 2026-07-18 after auditing the current prelude
compiler/evaluator, the surviving `PtcRunner.Lisp.Signature` runtime validator,
the Kernel capability dispatcher, and the removed SubAgent return-validation
loop.

This plan makes the optional `:signature` and `:type` metadata on public
PTC-Lisp prelude exports executable contracts instead of prompt-only metadata.
For a fixed-arity function such as:

```clojure
^{:signature "(query :string) -> {items [:string]}"}
(defn search [query]
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

## Why this work is needed

### The current metadata promises more than the evaluator enforces

The prelude compiler currently parses a declared function signature,
canonicalizes it, and checks that its parameter count equals the function's
fixed arity. The analyzer subsequently checks only the number of arguments in
a call. The evaluator carries the export record to the invocation boundary but
does not consult its signature.

Consequently, given:

```clojure
^{:signature "(query :string) -> [:string]"}
(defn search [query] ...)
```

these calls have different current outcomes:

| Program | Current check | Current result |
| --- | --- | --- |
| `(api/search)` | arity | rejected before evaluation |
| `(api/search "cats")` | arity | admitted |
| `(api/search 42)` | arity | admitted because it still has one argument |
| `(map api/search queries)` | callable arity | admitted; export type metadata is not enforced |

The mission inventory and model-context renderer can display the signature as
the documented mission API contract. Without runtime enforcement, that
contract may be useful guidance but is not trustworthy execution semantics.

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
8. **Validate only successful function results.** An ordinary returned value is
   checked. A `(fail value)` control signal is not checked against the success
   type. The implementation must define and test how an export-local
   `(return value)` abort is classified; it must not accidentally bypass a
   declared success contract.
9. **Constant contracts fail during compilation.** A public `def` is immutable
   in the compiled artifact, so its declared `:type` should be checked once
   after the runtime environment is built. An invalid constant rejects the
   component instead of failing repeatedly whenever it is read.
10. **Errors are bounded, structured, and model-readable.** Contract failures
    use a stable evaluation-error classification and include the public export
    ref, phase (`input` or `output`), bounded validation paths, expected
    contract, and a concise actual-type description. They never include the
    private prelude environment or source.
11. **Capability JSON Schema remains defense in depth.** A hidden raw
    capability can still be called by exact granted name, and wrappers can be
    wrong. The dispatcher continues validating raw inputs and outputs
    independently.
12. **A contract is not authority.** It cannot grant a capability, expand a
    root path, increase a quota, or make a hidden capability discoverable.

## Invocation and error semantics

### Input mismatch

For:

```clojure
^{:signature "(query :string, limit :int?) -> {items [:string]}"}
(defn search [query limit]
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

- an input-contract failure is corrective model feedback and may consume a
  retry turn;
- an output-contract failure after no capability activity may be offered as
  corrective feedback; and
- an output-contract failure after capability activity must fail closed or be
  marked non-retryable unless the invoked operations are proven idempotent.

The implementation must not claim that the `effect` documentation hint alone
provides rollback or idempotency.

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

Prompt rendering continues using the compact PTC-Lisp signature. Full JSON
Schema is retained for raw capabilities the model must call directly and for
host-side validation.

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
3. Preserve the current mission-inventory shape: only the canonical contract
   string is model-visible; parsed tuples are internal.
4. Validate public constant values after `build_runtime/3` has produced the
   namespace environment and before returning a compiled `%Prelude{}`.
5. Keep deterministic hashes based on source and existing bundle inputs; do not
   add runtime-dependent data to compilation.

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
7. Explicitly test `(return ...)` and `(fail ...)` from inside a public export
   so success validation cannot be bypassed and failure payloads are not
   misclassified.

### Phase 4: Feed safe correction information to `agent.core`

1. Project the stable contract-error kind and bounded public details through
   `Kernel.Evaluation`.
2. Update `agent.feedback/evaluation-error` to render the export ref, phase,
   path, and expected/actual information without raw internal tuples.
3. Make retry classification distinguish a pre-entry input error from a
   post-entry output error.
4. Add a deterministic two-response fake-LLM integration test: the first
   generated program passes a wrong argument, feedback identifies the public
   mission API contract, and the second program corrects it.
5. Add a no-retry regression for an output mismatch after an observable
   capability call, proving the agent cannot silently duplicate the effect.

No live provider call or newly generated trace is required for this correctness
gate. A later DeepSeek smoke run may verify prompt comprehension and Viewer
presentation, but deterministic integration tests own the contract.

### Phase 5: Update documentation and examples

1. Document `^{:signature ...}` and `^{:type ...}` as enforced runtime
   contracts in the Kernel maintainer guide and PTC-Lisp specification.
2. Explain syntax validation, arity validation, and value validation as three
   distinct stages.
3. Update the Kernel tutorial's mission wrapper with a truthful docstring and
   signature so the compact Mission API demonstrates the feature.
4. State that optional positional parameters accept `nil` but are not omitted.
5. Document strict validation, retry classification, and the lack of rollback
   for external effects.
6. Keep capability JSON Schema documentation as the raw authority boundary.

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
10. `agent.core` can retry a pre-entry input mismatch with actionable feedback.
11. The agent does not automatically retry an output mismatch after an
    observable capability effect.
12. `mix precommit` passes, including integration coverage for direct, HOF,
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
- Coercing strings to numbers, parsing datetimes, or repairing values
  automatically.
- Treating a signature as authorization or capability visibility policy.
- Restoring an agent-level final mission-result contract. If needed, add a
  separate bounded result contract to the agent configuration, validate the
  model-authored final `(return ...)`, and reuse the safe correction loop from
  this work without coupling that contract to an arbitrary prelude export.
