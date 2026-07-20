# Bounded class-aware Java interop

**Status:** planned

**Baseline:** `exp/minimal-kernel` at `294e438f`

**Last reviewed:** 2026-07-20

## Summary

Replace PTC-Lisp's flat collection of Java-shaped builtins with a closed,
class-aware subsystem. The implementation remains BEAM-native: it does not load
a JVM at runtime, perform arbitrary reflection, map source names to arbitrary
Elixir modules, or expose ambient host calls.

The essential changes are:

1. define the supported Java surface once in a validated manifest;
2. preserve class and invocation kind in CoreAST;
3. dispatch instance members from the receiver's declared Java type;
4. represent different Java temporal classes with different native values;
5. implement selected Java overload, parsing, temporal, and UTF-16 String
   semantics explicitly;
6. retain tagged values at native boundaries and project them safely at the
   existing public/tool/Kernel boundaries; and
7. verify the surface against pinned JVM Clojure, with Babashka as a fast
   secondary oracle.

This document is intentionally limited to work required for Java interop. The
generic Kernel publication, EventSink lifecycle, REPL ownership, cache, and
arbitrary-host-term hardening considered during the investigation is retained
separately in
[`../future/kernel-publication-and-boundary-hardening.md`](../future/kernel-publication-and-boundary-hardening.md).
That work is not a prerequisite for this plan.

## Why change the current implementation

The current Java surface is bounded, but Java identity is erased early and its
definition is duplicated.

### Class and invocation identity are lost

`PtcRunner.Lisp.Analyze` rewrites several qualified Java spellings into generic
calls. For example, `LocalDate/parse` and `Instant/parse` can reach the same
generic `parse` binding. CoreAST then contains an ordinary call rather than an
explicit static Java invocation.

Consequences:

- static calls, constructors, fields, and instance calls are not represented as
  different operations;
- diagnostics cannot consistently distinguish unknown class, member, kind,
  arity, or overload;
- Java member references cannot retain a precise class/overload constraint; and
- later consumers cannot verify that the operation documented and tested is the
  one actually selected.

### Instance dispatch is not receiver-owned

Java-shaped instance operations are currently exposed through the flat runtime
environment and `Runtime.Interop`. Selection starts from a global method name,
not from a Java class identity carried by the receiver.

This allows unrelated method families to drift together. An operation such as
`.getTime`, `.isBefore`, or `.plusDays` should be admitted only for the Java
class that owns it.

### Host temporal structs conflate Java classes

`%Date{}` and `%DateTime{}` currently stand in for multiple Java concepts. That
cannot faithfully distinguish:

- `java.time.LocalDate`;
- `java.time.Instant`;
- `java.time.Duration`; and
- `java.util.Date`.

The conflation causes observable errors, including ambiguous parse results,
wrong method sets, and `Date(long)` unit heuristics. It also lets a raw
host-provided `%DateTime{}` accidentally look like a Java object.

### Several Java names implement PTC behavior

The Java-looking Math and numeric parser names often delegate to ordinary
PTC-Lisp helpers. Some are variadic, accept values outside a Java primitive
overload, return recoverable signal values where Java throws, or apply different
numeric coercion rules.

Java-named operations should have the selected Java semantics unless a bounded
PTC divergence is deliberately documented.

### Java String indexing is not grapheme indexing

PTC strings are UTF-8 binaries and ordinary PTC string helpers work in grapheme
terms. Java `String.length`, `indexOf`, `lastIndexOf`, and `substring` operate on
UTF-16 code units. The results differ for non-BMP characters and for indexes
inside a surrogate pair.

### The supported surface has several authorities

Overlapping Java information currently appears in analyzer clauses,
`SourceAtoms`, environment bindings, runtime builtins, runtime functions,
function metadata, the Java audit, generated documentation, and conformance
cases. A change can update one authority while leaving another stale.

## What this enables

The new model enables:

- unambiguous constructors, static methods, fields, and instance methods;
- class-correct temporal results and method sets;
- Java member references usable as first-class callables without open host
  lookup;
- strict Java numeric parsing and explicit primitive overload selection;
- Java-compatible UTF-16 String indexes while retaining UTF-8 PTC strings;
- exact, generated documentation of the admitted surface;
- structured errors for unsupported class/member/arity/type and Java domain
  failures;
- executable coverage showing which manifest overload was exercised; and
- adding a new Java operation by extending one closed manifest plus a focused
  implementation and tests.

## Goals

- Preserve exact class/member/invocation identity from analysis through
  dispatch.
- Keep the runtime implementation finite and auditable.
- Keep sandbox safety and bounded recoverable failures.
- Match JVM Clojure/Java behavior for admitted operations except for explicit
  PTC divergences.
- Maintain native Java identity across `run_native/2` and REPL continuation
  state.
- Prevent native wrapper structs and callable authority from leaking through
  public, tool, or Kernel JSON boundaries.
- Delete the legacy Java route after each operation family migrates.

## Non-goals

- General Java reflection or class loading.
- A JVM embedded in the production runtime.
- General BEAM interop modelled after Clojerl's open module lookup.
- Implementing the entire Java standard library.
- Replacing EventSink, RunConfig, TraceLog, Viewer persistence, or
  `ReplSession` process ownership.
- Redesigning generic tool caching or all host-value validation.
- Making arbitrary BEAM structs valid Lisp values.
- Copying Clojerl, SCI, Babashka, or Clojure test/code text into this project
  without a separate licensing decision.

## Lessons from other Clojure implementations

### Clojerl

Clojerl is a Clojure implementation for the BEAM. It does not implement the JVM
Java API, but its receiver-oriented runtime is the most relevant architectural
inspiration.

Useful ideas:

- a runtime value has an owning type/module;
- member application is routed through that owner;
- the analyzer preserves dot-form intent rather than treating every member as a
  global function; and
- callable and protocol dispatch are explicit runtime concepts.

PTC-Lisp should reuse the shape of that idea, not Clojerl's open lookup. A PTC
receiver maps only to one of the Java profiles declared in the manifest, and the
result maps only to a fixed implementation key.

Relevant upstream research points:

- [`clj_rt:type_module/1`](https://github.com/clojerl/clojerl/blob/4ad14e57df85d30cc3332308f861f4e174383483/src/erl/clj_rt.erl)
- [Clojerl analyzer dot handling](https://github.com/clojerl/clojerl/blob/4ad14e57df85d30cc3332308f861f4e174383483/src/clj/clojerl/analyzer.cljc)

Clojerl is EPL-licensed. Reuse architectural ideas unless an explicit license
review approves copying particular code or tests.

### SCI and Babashka

SCI is useful for its closed allowlist model: namespaces, classes, vars, and
members are admitted deliberately, and unsupported interop is denied. Babashka
adds a practical executable compatibility target and fast developer feedback.

Reuse:

- a closed surface rather than ambient reflection;
- denial tests for every route that could bypass the allowlist;
- Babashka as a fast compatibility signal; and
- pinned executable fixtures rather than documentation-only compatibility
  claims.

Do not treat Babashka as the final authority for Java overload details. Native
GraalVM behavior and Babashka's selected surface can differ from JVM Clojure.

### JVM Clojure

Pinned JVM Clojure is the authoritative behavior oracle for the admitted Java
surface. The test harness should compare typed values and structured error
categories, not only printed output or the fact that both sides failed.

## Architecture

### 1. One authoritative surface manifest

Add `priv/java_interop.exs` and load it through
`PtcRunner.Lisp.Java.Surface`.

The manifest is the only semantic authority for supported Java operations.
Other tables are generated projections.

Each class record contains:

- stable `class_id`;
- canonical JVM class name;
- admitted short and fully-qualified spellings;
- runtime receiver profile, if instances are representable; and
- documentation/audit grouping.

Each reference record contains:

- stable `reference_id`;
- class ID;
- source member name;
- invocation kind: `:static`, `:constructor`, `:instance`, or `:field`;
- whether value-position use creates a callable;
- admitted source spellings; and
- one or more overload IDs.

Each overload contains:

- stable `overload_id`;
- exact arity;
- JVM descriptor or field type;
- receiver profile;
- argument/coercion profiles;
- return profile;
- declared error categories;
- optional divergence ID; and
- a closed implementation key.

Example shape:

```elixir
%{
  classes: [
    %{
      class_id: :java_time_local_date,
      name: "java.time.LocalDate",
      spellings: ["LocalDate", "java.time.LocalDate"],
      receiver_profile: :local_date
    }
  ],
  references: [
    %{
      reference_id: :local_date_parse,
      class_id: :java_time_local_date,
      member: "parse",
      kind: :static,
      callable?: true,
      overloads: [:local_date_parse_string]
    }
  ],
  overloads: [
    %{
      overload_id: :local_date_parse_string,
      descriptor: "(Ljava/lang/CharSequence;)Ljava/time/LocalDate;",
      arity: 1,
      arguments: [:java_string],
      return: :local_date,
      errors: [:date_time_parse_exception],
      implementation: :local_date_parse
    }
  ]
}
```

`Java.Surface` validates at compile time:

- globally unique IDs;
- unique class/member/kind/spelling combinations;
- exact descriptor/arity agreement;
- valid receiver, argument, coercion, return, error, and implementation enums;
- no ambiguous direct-dot family without an explicit policy;
- every implementation key has a code-owned handler;
- every documented or runtime-linked row resolves back to the same manifest
  identity; and
- no Java-shaped entry remains in the generic function manifest after final
  migration.

The manifest must be included as `@external_resource` and in Hex package files.

Generated consumers:

- analyzer class/member lookup;
- bounded source atom/name inventory;
- dispatch tables;
- Java audit and coverage inventory;
- generated Java interop documentation; and
- conformance target inventory.

The generated `docs/java-interop.md` remains generated. Update its generator
input and run `mix ptc.gen_docs` rather than editing it directly.

### 2. Class-aware syntax and CoreAST

Preserve invocation kind in CoreAST. Exact tuple names may be adjusted during
implementation, but the algebra must distinguish:

```elixir
{:java_static, reference_id, arguments}
{:java_new, reference_id, arguments}
{:java_field, reference_id}
{:java_instance, reference_id, receiver, arguments}
{:java_dot, member_family_id, receiver, arguments}
{:java_ref, reference_id}
```

Semantics:

- qualified static/member syntax resolves a fixed reference during analysis;
- constructor syntax resolves a constructor reference;
- qualified instance syntax retains the required class constraint;
- unqualified `(.member receiver ...)` retains a finite member-family ID and
  selects a class-specific reference from the evaluated receiver;
- value-position member/static syntax produces a `%Java.Callable{}` only when
  the manifest admits it; and
- no Java form lowers to a generic environment var call after migration.

The analyzer reports bounded, distinct failures for:

- unknown Java class;
- unsupported member;
- wrong invocation kind;
- unsupported value-position reference; and
- statically impossible arity.

Update all CoreAST consumers in the same slice:

- `CoreAST.validate/1` and typespecs;
- undefined-variable collection;
- tool/prelude dependency collection;
- `CoreToSource` and its reference walk;
- closure capture;
- data-key/static walks; and
- any prelude compiler/bundle walkers that enumerate CoreAST explicitly.

Tests must prove both valid recursion and rejection of malformed Java nodes. A
source export/reload test should round-trip closures containing qualified and
direct-dot Java calls.

### 3. Closed dispatch

Add `PtcRunner.Lisp.Java.Dispatch` as the only Java operation selector.

Dispatch inputs are already-resolved manifest identities plus evaluated values:

```text
reference_id + invocation kind + receiver profile + arguments
    -> selected overload row
    -> fixed implementation key
    -> validated native outcome
```

Direct-dot dispatch first maps the receiver to one closed Java profile, then
selects a reference from the manifest-owned member family. It does not search
Elixir modules or all known methods by string.

Handler modules should remain focused, approximately:

- `Java.Lang.Boolean`;
- `Java.Lang.Numeric`;
- `Java.Lang.Math`;
- `Java.Lang.String`;
- `Java.Lang.System`;
- `Java.Time.LocalDate`;
- `Java.Time.Instant`;
- `Java.Time.Duration`;
- `Java.Util.Date`; and
- `Java.Dispatch`, `Java.Surface`, and shared value/coercion helpers.

Use one module per file.

Handlers receive values already checked/coerced for the selected overload and
return a closed outcome:

```elixir
{:ok, native_value}
{:error, java_condition}
```

`Java.Dispatch` validates that a handler success satisfies the manifest return
profile and that a handler error is declared by the selected row. A raise,
wrong wrapper class, malformed wrapper, wrong primitive range, unexpected nil,
or undeclared error becomes a bounded internal handler-contract error. Raw
handler terms and stacktraces are not exposed to Lisp.

Stable public failure families should cover:

- `:unsupported_java_class`;
- `:unsupported_java_member`;
- `:java_arity_error`;
- `:java_type_error`;
- `:java_domain_error`;
- `:invalid_java_string`; and
- `:java_handler_contract_error`.

Expected Java exceptions remain recoverable evaluator failures because the
sandbox has no general Java exception/catch facility.

### 4. Java callables

Represent an admitted member reference as a validated `%Java.Callable{}` with
only manifest identity and bounded class/arity constraints. Do not retain a raw
function, module, or open member name.

Application goes through the evaluator's existing callable/effect path and then
`Java.Dispatch`. Update all callable consumers that currently recognize
closures, builtins, composed callables, keywords, maps, or runtime callables,
including higher-order functions, predicates/type descriptions, `apply`, sort
comparators, `pmap`, and `pcalls`.

The callable must remain native in `run_native/2` and continuation state. Public
projection renders it as a fixed inert class/member label. Tool/Kernel JSON
boundaries reject it unless a future explicit contract says otherwise.

### 5. Tagged native Java values

Add one struct per represented Java object class:

| Java class | Native payload | Initial instance families |
|---|---|---|
| `java.time.LocalDate` | validated calendar/epoch-day identity | parse, plusDays, comparisons, toString |
| `java.time.Instant` | epoch second plus nanosecond adjustment | parse, comparisons, toEpochMilli, toString |
| `java.time.Duration` | signed seconds plus nanosecond adjustment | between, duration accessors, toString |
| `java.util.Date` | signed epoch milliseconds | constructors, getTime, before/after, toString policy |

Do not infer these identities from arbitrary `%Date{}` or `%DateTime{}` values.
Every constructor validates the selected Java range and normalization invariant.
Every consumer validates a wrapper before using its payload so a host-forged
struct cannot bypass the manifest.

Native wrappers are retained in:

- `run_native/2` results;
- REPL continuation memory/history;
- closures and user definitions; and
- native intermediate evaluation values.

Class-specific corrections include:

- `LocalDate/parse` returns LocalDate only;
- `Instant/parse` returns Instant only and preserves admitted fractional
  precision;
- `Duration/between` initially accepts two Instants;
- `Date(long)` always interprets milliseconds;
- `.getTime` belongs to legacy Date;
- `.toEpochMilli` belongs to Instant;
- LocalDate/Instant use their admitted `isBefore`/`isAfter` families; and
- legacy Date uses `before`/`after`.

### 6. Numeric and Math semantics

Numeric coercion must be selected by the overload row, not by a generic BEAM
number helper. Define closed profiles for Java primitive arguments and results,
including range, float/double rounding, signed zero, infinities, and NaN.

Implement strict Java parser behavior for admitted forms such as:

- `Integer/parseInt`;
- `Long/parseLong`;
- `Float/parseFloat`; and
- `Double/parseDouble`.

These must not delegate to PTC `parse-long` or `parse-double` helpers when those
helpers have different syntax, failure, or signal-value behavior.

For Math, admit only overloads whose contract is explicitly represented. Do not
retain a variadic `Math/max` or `Math/min` merely because an ordinary PTC helper
has that name. Preserve non-Java convenience behavior under PTC-named functions
instead.

Each numeric overload needs boundary cases for:

- minimum/maximum primitive values;
- nearest out-of-range values;
- integer versus floating inputs;
- float versus double rounding;
- positive and negative zero;
- NaN and infinities where admitted; and
- exact Java error category where parsing or conversion fails.

### 7. Java String semantics

Keep PTC strings as UTF-8 binaries; do not add a JavaString wrapper.

For admitted Java String operations, validate UTF-8 and build a bounded UTF-16
code-unit view. Use it for:

- `length`;
- `indexOf`;
- `lastIndexOf`;
- `substring`; and
- any other operation whose Java contract is code-unit based.

Indexes and returned lengths are UTF-16 code-unit indexes. Converting a
substring back to PTC UTF-8 can fail if the selected Java range contains an
unpaired surrogate. Record that representational difference as a deliberate
PTC divergence rather than silently changing the index or returning invalid
UTF-8.

Casing methods require an explicit policy. Prefer the smallest correct initial
surface:

- locale-independent operations whose JVM behavior can be pinned to a checked
  Unicode-data version; or
- defer locale-sensitive casing until a deterministic locale/data contract is
  selected.

Tests must cover ASCII, BMP non-ASCII, supplementary characters, indexes before
and inside surrogate pairs, empty strings, absent searches, and invalid UTF-8
host input.

### 8. Minimal boundary projection

Java identity must remain native while evaluation can use it, but wrapper structs
and callable authority must not escape accidentally.

Extend the existing boundary code with a focused Java projection layer:

| Boundary | Required behavior |
|---|---|
| `run_native/2` | retain valid native wrappers and Java callables |
| REPL continuation | retain valid native wrappers/callables for later forms |
| `run/2` public result | recursively replace wrappers with inert canonical values and callables with inert labels |
| `format_value` / runtime `str` | class-aware canonical display without struct internals |
| declared direct tool argument/result | apply existing signature contract, converting an Instant/legacy Date to `%DateTime{}` only when exact and representable |
| Kernel/tool JSON | emit canonical JSON-safe values or reject before callback/publication |
| cache identity | derive from the already-prepared callback-visible value; do not key from raw wrapper storage |

Canonical inert values should initially be:

- LocalDate: Java-compatible ISO local-date text;
- Instant: Java `Instant.toString`-compatible UTC text;
- Duration: Java `Duration.toString`-compatible text;
- legacy Date: a documented canonical UTC instant derived from exact epoch
  milliseconds; and
- Java callable: a fixed class/member label with no executable state.

Projection recursively covers lists, tuples, sets, map keys/values, result
records, and nested tool values. If two distinct native keys or set members
become equal after projection, return a bounded projection-collision error; do
not silently overwrite one.

This slice may factor the existing recursive externalization code so direct and
Kernel callers share Java leaf handling. It must not redesign EventSink,
TraceLog, REPL lifecycle, or the complete generic value algebra.

### 9. Executable conformance

Harden the existing conformance runner specifically for Java cases.

Every Java case has:

- stable case ID;
- manifest target: overload, reference/member family, boundary, or unsupported
  candidate;
- structured invocation/fixtures;
- expected typed value or structured error category;
- oracle choice; and
- optional durable divergence ID.

For overload coverage, the PTC side must report the selected `overload_id` from
`Java.Dispatch` through a test-only internal attestation hook. The ID is not
Lisp data and is unavailable to public options. A case counts toward overload
coverage only when:

1. its target resolves to the manifest row;
2. the JVM adapter invoked the matching class/member/descriptor;
3. PTC dispatch selected the same overload ID; and
4. the typed outcome comparison passes.

The JVM adapter should use pinned Java and Clojure versions and exact reflection
descriptors for overload-target cases. Babashka runs the fast compatible subset
but cannot grant authoritative overload coverage where its implementation
differs from JVM Clojure.

Keep the harness proportionate:

- run one bounded subprocess per case or bounded batch;
- cap source, stdout, stderr, result size, and runtime;
- terminate the subprocess on timeout; and
- keep checked-in typed fixtures for hermetic ordinary tests.

More elaborate reusable worker/reaper supervision belongs to the future
hardening plan unless actual harness failures demonstrate the need.

Required commands may be introduced as:

```bash
mix ptc.java_conformance --oracle babashka --subset fast
mix ptc.java_conformance --oracle jvm --subset implemented
mix ptc.java_fixtures --oracle jvm --check
```

The JVM implemented-surface check must be a required CI job rather than relying
on the default suite, which currently excludes Clojure-tagged tests.

Write original PTC tests from the public contract and observed oracle behavior.
Record upstream version, commit/release, command, JVM, locale, and timezone for
generated fixtures.

## Migration strategy

This is a 0.x library. Prefer complete vertical migration and deletion over
compatibility shims.

### Phase 0: freeze and classify

1. Inventory every currently accepted Java spelling from analyzer, Env,
   runtime, metadata, audit, generated docs, tests, examples, and preludes.
2. Classify it as:
   - exact admitted Java operation;
   - intentional PTC divergence;
   - temporary legacy route needing migration; or
   - incorrect/non-Java alias to remove.
3. Add `priv/java_interop.exs`, `Java.Surface`, stable IDs, and validation.
4. Make audit/docs/conformance inventories projections of that manifest.
5. Add typed JVM/Babashka cases that characterize current behavior and expose
   the selected fixes as failing regressions.
6. Remove clearly non-Java-shaped aliases such as variadic Java Math forms once
   their removal tests and docs land.

Phase-0 gate:

- every shipped Java spelling has exactly one classification;
- every exact admitted operation has a JVM descriptor and executable case;
- every known mismatch has a durable divergence/bug record and owning phase;
- no documentation or audit row is orphaned; and
- ordinary runtime behavior is unchanged except for explicitly selected alias
  removals.

### Phase 1: dispatch foundation and scalar statics

1. Add the complete existing CoreAST validation baseline and Java nodes.
2. Update every CoreAST consumer.
3. Add `Java.Dispatch`, handler postcondition validation, and structured errors.
4. Add `%Java.Callable{}` and update existing callable consumers.
5. Add minimal Java native/public/tool/Kernel projection.
6. Migrate Boolean, numeric parser, selected Math, System, and constant/static
   rows one complete family at a time.
7. Delete each migrated Env/runtime route and regenerate docs.

Phase-1 gate:

- no migrated operation remains live through both Env and Java dispatch;
- direct, native, tool, Kernel, and callable cases agree on manifest identity;
- all scalar overloads have authoritative JVM coverage; and
- `mix precommit` passes after every family.

### Phase 2: temporal profile

1. Add the four temporal wrapper modules and invariants.
2. Add their formatting, predicates/type descriptions, signatures, and boundary
   projections.
3. Migrate all LocalDate, Instant, Duration, and legacy Date constructors,
   statics, fields, and instance methods.
4. Replace temporal parser and receiver unions with class-specific operations.
5. Delete the old `Runtime.Interop.Duration` and other temporal aliases.

Migrate the temporal family atomically enough that a value produced by a new
constructor never reaches an old global member dispatcher.

Phase-2 gate:

- native values preserve class identity across multiple forms;
- no raw host temporal struct receives Java methods;
- every min/max/range/precision case passes or names an explicit divergence;
- all old temporal Java routes are deleted; and
- generated docs describe class-correct methods.

### Phase 3: Java String

1. Add the bounded UTF-16 view and index conversion helpers.
2. Migrate admitted String instance/static/reference rows.
3. Add or defer casing rows according to the selected deterministic Unicode
   policy.
4. Preserve ordinary PTC grapheme helpers under their existing non-Java names.
5. Delete old Java String aliases and regenerate docs.

Phase-3 gate:

- UTF-16 cases match the pinned JVM oracle;
- unrepresentable surrogate results produce the documented bounded divergence;
- invalid UTF-8 host values fail before a handler; and
- no Java String spelling reaches a grapheme-index implementation.

### Phase 4: remove migration machinery

1. Prove all surviving Java rows use closed dispatch.
2. Delete temporary legacy-route schema and adapter.
3. Delete duplicate Java analyzer clauses, Env bindings, metadata, audit tables,
   and obsolete tests.
4. Regenerate `docs/java-interop.md`, function reference material, and
   conformance reports.
5. Move durable behavior into the language specification, module docs, and
   maintainer guides; do not link code documentation to this plan.

Final gate:

- the manifest is the only supported-surface authority;
- every admitted overload has executable JVM coverage;
- every intentional mismatch has a durable divergence record;
- all legacy Java routes and duplicate tables are gone;
- focused tests, `mix precommit`, and `mix prepush` pass; and
- the final diff contains no unrelated Kernel/Viewer lifecycle refactor.

## Test plan

### Manifest and analyzer

- manifest schema/completeness and duplicate-ID tests;
- source spelling to exact reference/kind tests;
- static, constructor, field, qualified-instance, direct-dot, and reference
  CoreAST tests;
- unknown class/member/kind/arity diagnostics;
- complete CoreAST consumer recursion tests; and
- source export/reload round trips.

### Dispatch

- representative success for every overload;
- arity and type rejection before handler execution;
- receiver class mismatch;
- nil receiver policy;
- overload precedence/ambiguity;
- handler return/error postcondition failures; and
- no fallback to generic Env after Java selection fails.

### Native values and boundaries

- valid and forged wrappers at top level and nested positions;
- continuation memory/history across forms;
- canonical formatting and public projection;
- map/set projection collisions;
- direct tool signature conversion and precision/range rejection;
- Kernel JSON acceptance/rejection; and
- Java callable native retention and inert public projection.

### Semantic families

- numeric primitive boundaries and special values;
- strict parser syntax and Java error categories;
- temporal class/range/precision/method families;
- Date milliseconds with no heuristic;
- UTF-16 String indexes and surrogate boundaries; and
- explicit divergence regressions.

### Conformance and drift

- JVM descriptor attestation;
- PTC selected-overload attestation;
- typed value/error comparison;
- Babashka fast subset;
- checked-in fixture verification;
- manifest-to-doc/audit/case bidirectional completeness; and
- searches proving migrated Env/runtime routes are deleted.

## Implementation risks

### An analyzer-only migration would be unsafe

New nodes must land with all CoreAST consumers and runtime dispatch. The phase
gates require this vertical slice.

### Tagged values affect public boundaries

Retain them only at native boundaries. Add the focused recursive projection and
collision tests before the first wrapper-producing operation is enabled.

### Overload tests can pass accidentally

Equal results do not prove equal overloads. Require exact JVM descriptor and PTC
selected-overload attestation for coverage.

### UTF-16 results are not always valid UTF-8

Treat an unpaired-surrogate result as an explicit representational divergence;
do not silently repair it.

### The manifest can become another duplicate table

Delete old authorities as families migrate and add bidirectional drift tests.

### Scope can expand into generic Kernel hardening

Use the non-goals above. A Java slice may extend an existing boundary with Java
leaf handling, but it must not redesign unrelated lifecycle, publication, or
cache infrastructure without a separate approved change.

## Completion criteria

The plan is complete when:

- the supported Java surface is defined once;
- analyzer and runtime preserve exact Java identity;
- instance methods are receiver/class constrained;
- temporal values retain distinct native class identity;
- selected numeric, Math, temporal, and String behavior matches pinned JVM
  cases or an explicit divergence;
- native/public/tool/Kernel boundaries handle Java values deliberately;
- generated docs and audit inventory cannot drift from dispatch;
- every admitted overload is executable and descriptor-attested; and
- all replaced flat Java routes are deleted.
