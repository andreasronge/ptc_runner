# Prelude-Selected Capability Namespaces

**Status:** tiers 1-2 implemented for MCP stateful sessions (2026-07-06) after
independent implementation-readiness and post-implementation review passes.
This doc now holds three tiers with different maturity:

1. **Dependent Surface Variant** (`scoped_base_surface`) — accepted by the
   `composable-demo-2-20260705` gated loop; implemented as an opt-in session
   presentation mask with measured before/after trace validation.
2. **Contract Line Variant** (`strict_transitive_calls`) — design note filed
   alongside it; implemented as an opt-in role grant, including the
   `:prelude_ref` value-position guard found in review.
3. **Namespace unification** (the original direction: selected preludes as
   the main enable/disable surface, `mode: "write_capable"` collapsing into
   `preludes: ["prelude/write"]`) — long-term cleanup, *not* a prerequisite
   for tiers 1–2 and not scheduled.

Both variants **extend** the `role`/grant model implemented in
[`composable-prelude-library-demo.md`](../composable-prelude-library-demo.md)
Slice C (they wire into `Policy.Grant` and session options); only tier 3
would eventually simplify that model. Read Slice C first for the baseline.

## Problem

ptc_runner currently enables optional Lisp namespaces through several adjacent
mechanisms:

- regular capability preludes are attached with `:prelude` / `runtime_prelude`;
- `log/` is a host-shipped prelude plus host-granted `log_*` tools;
- `prelude/` store authoring is a host-shipped prelude plus private
  `prelude_store_*` tools, gated by MCP server config and
  `mode: "write_capable"`;
- `tool/` is populated directly from the granted host tool map;
- core discovery exposes a small fixed set of built-in namespaces.

The model is defensible, but the MCP session surface is more special-cased than
it needs to be. In particular, `mode: "write_capable"` is a separate switch
whose real effect is "attach the `prelude/` authoring capability and grant its
private backing tools."

The composable-prelude demo adds an auditability reason to pursue this
direction. Process-level CLI allow/deny flags can hide the surface a model
actually saw from the run's own turn log. Session-selected capability
namespaces would make that surface part of `lisp_session_start`, so a gated run
can prove which read, write, discovery, and authoring capabilities were visible
to each stage.

## Direction

Make selected preludes the main namespace enable/disable surface for MCP
sessions:

```json
{
  "preludes": ["paged@2", "log/read", "prelude/read"]
}
```

or, if variants remain attached to one logical prelude id:

```json
{
  "preludes": [
    {"id": "prelude", "config": "read"},
    {"id": "paged", "version": 2}
  ]
}
```

The important split remains:

- **namespace availability:** which public namespaces and exports are attached;
- **authority backing:** which host/private tools those exports are allowed to
  call.

Loading a capability prelude should never implicitly widen authority. Instead,
each capability prelude declares its `tool:<name>` requirements in the normal
export metadata. Session start resolves the selected preludes, grants only the
backing tools allowed by host policy, attaches the bundle, and fails closed when
any selected export requires unavailable authority.

## Three Lines: Authority, Attention, Contract

Three distinct properties get conflated when this direction is discussed as
one thing. Keeping them separate matters because they have different owners,
are enforced at different points, and each needs its own case for change:

- **Authority** — which host/private tools a function is allowed to call.
  This is the existing, strict line: host policy grants tool access,
  `requires` validation is checked at attach time, and sessions fail closed
  when a selected export needs authority the server did not grant. Nothing in
  this document proposes loosening it.
- **Attention** — what gets *presented* to a session for browsing: the prompt
  inventory and the `ns-publics`/`dir`/`apropos` discovery surface. This is
  what the Dependent Surface Variant narrows. It is a decluttering knob, not
  a boundary — execution still resolves the full dependency closure
  regardless of what the session was shown.
- **Contract** — who may *call* what. Today this line does not exist for
  session-level code: once a dependency closure is attached, any namespace in
  it is callable from anywhere in the session, whether or not the caller
  declared a dependency on it. The Contract Line Variant below proposes
  closing that gap.

The Dependent Surface Variant fixes the attention line only. It was proposed
and accepted on attention evidence — discovery-turn cost, eval-attempt count
— and nothing in that evidence measured harm from a session *calling* a
transitive dependency directly. It does not touch, and was never evidenced to
need to touch, the contract line.

## Dependent Surface Variant (Attention Line)

The `composable-demo-2-20260705` gated loop produced and accepted a concrete
variant of this direction for dependency-heavy read-only sessions:
`scoped_base_surface`.

When a session attaches dependent prelude `P` with base dependency `B`, and
`scoped_base_surface` is explicitly enabled, the catalog/discovery surface
contributed by `B` is narrowed to the `B` exports that `P` actually references.
Execution still resolves the full dependency closure; only the presented
surface changes. The option is default-off, recommended for read-only
inspection sessions, and must not change authoring or direct-base attach
behavior.

Required shape from the accepted review:

- **Opt-in, default off.** With the option disabled, dependent attach behavior is
  byte-for-byte unchanged.
- **Full-surface escape hatches.** Direct attach of `B` always presents all of
  `B`'s exports, and dependent attach provides the explicit
  `(dir 'base {:full true})` discovery path.
- **Deterministic derivation.** The narrowed set is derived from pinned
  dependency metadata: the union of `dep_calls.transitive` references from
  `P`'s forms into the pinned `(id, version, checksum)` for `B`.
- **Fail open to full surface on presentation-mask staleness.** Normal stale
  dependency pins already fail closed during prelude dependency resolution; if a
  later presentation-mask derivation cannot prove it is using the exact pinned
  base metadata, do not silently re-derive a narrower mask. Present the full
  base surface and flag the split for re-review.
- **Measured promotion.** Acceptance requires a `catalog_ops` before/after on
  the motivating split with no task-output regression. If the measurement shows
  no reduction, the request demotes to no-change.

The demo split that produced this request had `paged_audit` depend on
`paged_base`; recomputing cross-layer references over all audit forms yielded
`{paged_base/sample}`, so the scoped catalog would present one base export
instead of six. The request is provenance-tracked as specified and reviewed by
the `ptc-bench-comparison` gated loop, not as an implementation commitment.

### Solution Outline

One wiring distinction dominates this design, and it is the attention/contract
split showing up in code: **Slice C's `Policy.filter_prelude/2` is an
authority cut** — a filtered export is genuinely not attached, and calling it
fails. `scoped_base_surface` must NOT reuse that filter for the base
namespace, because execution has to keep resolving the full closure. What it
needs is a **presentation-only mask** that discovery and the prompt inventory
honor while the evaluator's export table stays complete.

1. **Session option, same lifecycle as `tags`/`role`.** Accept
   `scoped_base_surface: true` in `lisp_session_start` args (validated in the
   same allowed-keys chain), default absent/off. Optionally gate *permission*
   to enable it per role later; the option itself is not an authority change,
   so a grant field is not required for the first slice.
2. **Preserve selection metadata.** Extend the prelude-store selection result
   before implementing masking. `Selection.resolve_with_prefix!/4` currently
   returns only `{compiled_prelude, resolved_refs}` and `compile_closure!/2`
   discards the resolved candidates after compilation. `scoped_base_surface`
   needs an attach-time metadata object that survives into the MCP session:
   the caller-supplied direct refs, each selected candidate's id/version/
   checksum, its namespaces, its `form_graph`, and `required_by` provenance for
   transitive entries. Do not try to reconstruct direct-vs-transitive status
   from the compiled aggregate alone.
3. **Derive the presented set at attach time.** For each directly requested
   prelude `P` with `prelude_deps` pins: union `dep_calls.transitive`
   references from `P`'s `form_graph` (the compiler already unions this data
   for `requires`/`tool_refs` aggregation, `compiler.ex:759-827`) filtered to
   namespaces of pinned dependency `B`. Verify the mask derivation is using
   the same `(id, version, checksum)` candidate selected by dependency
   resolution. If that proof is unavailable or mismatched, **skip masking
   entirely** (full surface) and emit the re-review flag — fail-open-to-full is
   the safe direction for a presentation mask, the opposite of an authority
   check.
4. **Carry the mask as data, not by shrinking `%Prelude{exports}`.** Add a
   `presented_exports` (or `masked_refs`) field alongside the attached
   prelude bundle. The evaluator's `prelude_exports` table is untouched —
   `(paged_base/fold-pages ...)` still resolves and runs (that is the point;
   the Contract Line Variant is the one that would restrict it).
5. **Mask only browsing/enumeration by default.** Honor the mask in the prompt
   inventory, `ns-publics`, `dir`, and `apropos` for prelude exports. `doc`,
   `meta`, and `source` on an explicitly named masked export still answer:
   knowing the exact ref means the attention problem is already past, and this
   keeps debugging from requiring a restart. `all-ns`/`ns-name` are not masked;
   namespace existence is not the costly surface, export enumeration is.
6. **Use a concrete reveal API in the first slice.** Add a `dir` option:
   `(dir 'paged_base {:full true})`. It returns the full namespace listing for
   that call only and does **not** clear the session mask. The existing
   `catalog_ops` turn-log entry for `dir` must include enough args to show
   `full: true`, preserving the audit story without adding a new discovery
   form.
7. **Wire the mask through current discovery/rendering entry points.** The
   implementation must add mask-aware inputs to `PromptInventory.render/2` (or
   equivalent session rendering) and to the prelude discovery helpers in
   `lib/ptc_runner/lisp/discovery.ex`; current implementations render directly
   from `%Prelude{exports}` and have no mask input. `dir` option validation
   must accept `:full`/`"full"` in addition to existing pagination options.
8. **Measurement gate.** Acceptance per the review: `catalog_ops`
   before/after on the motivating split (tags + `log/counters` make this a
   query), no task-output regression, demote to no-change if no reduction.

### Validation

The Dependent Surface slice needs both local regression tests and a measured
promotion run:

- `lisp_session_start` accepts `scoped_base_surface: true`, rejects malformed
  values and unexpected keys consistently with `tags`/`role`, and records the
  selected option in session/turn metadata where session-start options are
  already audited;
- selected-prelude resolution preserves direct refs, closure candidates,
  component checksums, `form_graph`, namespaces, and `required_by` provenance
  through the attach path;
- with the option off, prompt inventory and `ns-publics`/`dir`/`apropos`
  output is unchanged;
- with the option on, a transitive base namespace lists only the exports
  referenced by the direct dependent prelude, while a directly attached base
  namespace lists its full surface;
- `(dir 'base {:full true})` reveals the full base listing for that call only,
  and a later `(dir 'base)` returns to the masked listing;
- `doc`/`meta`/`source` on an explicitly named masked export still answer;
- an unavailable or mismatched mask provenance path falls back to full
  presentation and emits a review/audit flag, without changing runtime
  execution;
- prompt inventory masking is covered separately from discovery masking,
  because `PromptInventory.render` and `Discovery` are distinct code paths;
- the motivating split gets a `catalog_ops` before/after with no task-output
  regression before this option is promoted beyond experimental/default-off.

## Contract Line Variant (Strict Transitive Calls)

Filed alongside the Dependent Surface Variant, from the same
`composable-demo-2-20260705` analysis, but deliberately not folded into it:
the two fix different lines, derive from the same `dep_calls`/
`namespace_deps` metadata the compiler already tracks, and are complementary
rather than alternatives.

### Motivation: pin discipline, not module hygiene

ptc_runner's composability story is that evolution is safe because every
prelude dependency edge is declared and checksum-pinned: a `prelude_deps` edit
is a deliberate, reviewable event, and a re-pin can compute exactly what
depends on the version being replaced. That guarantee only holds if the
declared edges are the *complete* set of edges that exist.

They currently are not. If a session has `paged_audit` attached (which pulls
in `paged_base` as a dependency) and top-level session code calls
`paged_base/fold-pages` directly, that call is a real, load-bearing dependency
edge that no pin protects. When `paged_audit` later re-pins to a reshaped
`paged_base@2` that renames or removes `fold-pages`, that caller breaks
silently — the exact failure mode the store's checksum-pin discipline exists
to prevent. Phantom edges outrun the mechanism built to catch them.

This is Cargo's actual rationale for the same restriction, not an imported
aesthetic: a crate cannot `use` a transitive dependency's symbol unless it
declares that dependency itself, because the direct dependency is free to
drop or change it without a SemVer-visible break for you — you were never
owed that stability, since you never declared reliance on it.

There is also an LLM-specific version of this risk with no analogue in
human-written manifests: a call pattern that appears in evidence text — a
transcript, a worked example, an accepted run's record — can be imitated by a
later session that pattern-matches the *form* of a call without carrying
forward the reasoning that it was undeclared. A fail-closed error at the call
site is a corrective signal against exactly that failure mode; presentation
narrowing cannot touch it, because the call was never discovered through
browsing in the first place.

### Precedent: the compiler already enforces this, one layer up

This is not a new design front. `PtcRunner.Lisp.Prelude.Compiler` already
rejects undeclared cross-namespace references inside a prelude's own compiled
forms: `namespace_deps` is a declared `%{namespace => [dep_namespace]}` map,
checked by `validate_declared_deps/3`, and the module doc states the rule
directly — "Undeclared cross-namespace references keep failing (`unknown
namespace`)" — with dependency references inside `def` initializers rejected
outright (`:dep_ref_in_def`), because those evaluate at compile time and a
phantom dep call there would silently compute garbage.

Session top-level code is the one surface where the flat, pre-declaration
namespace model still survives. Extending the compiler's existing rule to
session code closes a gap in a discipline ptc_runner already enforces one
layer down, rather than opening a new one.

### Shape

- **Opt-in, role-scoped grant for the first slice.** A
  `strict_transitive_calls` field on session role policy, alongside the
  role-scoped grants already landed for store access. The initial
  implementation default is `false` everywhere because the current role schema
  has no role-class concept. Example workflow/editor/validator role configs may
  opt into `true`; analyst/diagnostic roles should normally stay relaxed while
  the behavior is being exercised.
- **Fails closed with a teaching error, not a bare rejection.** A call from
  session top-level code into a namespace attached only as a transitive
  dependency raises with a message that names the fix, e.g.: `paged_base is a
  transitive dependency of paged_audit; attach it directly to use it.`
- **The hatch is the same as Cargo's.** Attach the dependency directly — a
  declared, pinned, turn-log-visible session change — not a bespoke bypass
  flag. Nothing new to design here; direct attach already exists.
- **Introspection is untouched.** `prelude/read`'s `source`, `form`, and
  `form-deps` tools are governed by the `prelude_store: read` grant, a wholly
  separate surface from namespace-attach execution. Reading
  `paged_base/sample` via those tools — exactly what the Stage 4 reviewer did
  in `composable-demo-2-20260705` — is unaffected regardless of this setting;
  the reviewer used the read surface, not the call surface, so that reach-
  through is not evidence that soft encapsulation is load-bearing.
  **Introspection stays open, calls get strict, authority was never the
  issue.**
- **Relaxed-grant calls need provenance, not just permission.** A call made
  under `strict_transitive_calls: false` is exactly the imitation risk this
  section opened with — an analyst's diagnostic call, if left unmarked in
  evidence, is indistinguishable from a validated recipe to a later session
  that reads it. Evidence bundles should tag calls made under a relaxed grant
  so a downstream reader — human or model — can tell diagnostic reach-through
  from precedent.

### Solution Outline

Confirmed against the current runtime (`lib/ptc_runner/lisp/eval/context.ex`,
`eval/apply.ex`, `eval.ex`, `analyze.ex`,
`lib/ptc_runner/prelude_store/selection.ex`,
`mcp_server/lib/ptc_runner_mcp/sessions/policy.ex`) before writing this down,
so the shape below is a wiring plan, not a guess. Re-verified in the
2026-07-05 implementation review, which added the `:prelude_ref`
second-enforcement-site correction in step 3.

**The key finding: no new declared-deps validation needs writing — it
already exists, and a mechanism already in the evaluator can be reused to
gate on it.** `PtcRunner.Lisp.Prelude.Compiler` already proves every call
reachable from *inside* a compiled prelude's own forms is a declared edge
(`namespace_deps` / `validate_declared_deps/3`, `compiler.ex:184-224`). The
gap is only for calls originating from session top-level code, which never
goes through that compiler pass — `Session.eval/3` and every other caller
run through the same `Lisp.run`/`Analyze`/`Eval` pipeline regardless of
whether the code came from a compiled prelude or an ad hoc session form
(`lib/ptc_runner/lisp.ex:389,431-441`). So the fix is not "validate deps at
eval time" (recomputing what the compiler already proved) — it's "know,
at the one dispatch point that matters, whether the current call is running
*inside* an already-validated prelude form or not."

That distinction already exists as `EvalContext.origin_stack` /
`current_origin/1` (`eval/context.ex:585-589`), pushed by
`maybe_push_prelude_origin/3` (`eval/apply.ex:983-1005`):
`push_prelude_origin` (`%{type: :prelude_export, namespace: ns, ...}`) when
entering a compiled export's own body, `push_user_origin`
(`%{type: :user_closure}`) for an ordinary closure — including a
session-defined callback invoked from inside a prelude call — and no push at
all for a private prelude-internal sibling call. It exists today to gate
*tool* authorization (`Eval.do_eval` on `:tool_call`, checked against
`origin.tool_refs`, `eval.ex:857`; see `{:private_tool_unauthorized, ...}` in
`lisp.ex:1002-1008`). The same signal answers the contract question for
free: `current_origin` of `%{type: :prelude_export}` means the call is
running inside a form the compiler already validated — always allow. `nil` or
`%{type: :user_closure}` means the call originates from session-authored
code that was never checked against `namespace_deps` — this is exactly where
`strict_transitive_calls` needs to look.

1. **Add `direct_namespaces` and `strict_transitive_calls` to `EvalContext`**,
   following the existing pattern for opt-in stricter runtime modes
   (`strict_data`, `eval/context.ex:93,301`). This is an MCP-stateful-session
   feature in the first implementation slice. Non-MCP `PtcRunner.Session` and
   `SubAgent` selected-prelude paths keep current behavior unless/until a
   follow-up explicitly threads the same metadata through those constructors.
2. **Populate `direct_namespaces` from the session's original requested
   prelude-id list — not from `PreludeStore.Selection`'s `required_by`.**
   `required_by` (`selection.ex:191-197,223-231`) looks like the right
   signal (`[] ` = user-selected, non-empty = auto-pulled) but
   `add_requirer/2` appends a requirer to an entry whenever one is visited,
   with no special case for "this candidate was *also* directly requested."
   A prelude explicitly listed in `preludes: [...]` that another attached
   prelude also depends on ends up with a non-empty `required_by` regardless
   of the direct request — using `required_by == []` as the "direct" test
   would misclassify it as transitive-only and break the escape hatch itself
   (attaching a dependency directly is supposed to always work). The correct
   signal is membership in the caller-supplied requested-id set, captured
   once in `Session.new/1` (`session.ex:106-117`) before
   `expand_dep_closure!/2` runs, resolved to namespace names via
   `Prelude.namespaces/1` on those specific candidates. `required_by` is
   still the right source for the *teaching-error message* (it already names
   who pulled a namespace in) — just not for the admission decision.
3. **Enforce at BOTH export-resolution dispatch sites — this is a
   correction found in implementation review.** The obvious site is
   `Eval.do_eval({:prelude_call, ref, arg_asts}, ctx)` (`eval.ex:817-840`),
   but a check placed only there is bypassable: the analyzer also emits
   `{:prelude_ref, ref}` for a bare export reference in value position
   (`analyze.ex:305`, constants at `analyze.ex:1443`), resolved by
   `do_eval({:prelude_ref, ref}, ctx)` (`eval.ex:798-808`) into a
   first-class closure value — so `(let [f paged_base/sample] (f src 5))`
   or `(map paged_base/profile xs)` would never hit the `:prelude_call`
   check. Apply the same guard at both sites: if
   `ctx.strict_transitive_calls` and `EvalContext.current_origin(ctx)` is
   `nil` or `%{type: :user_closure}`, resolve `ref`'s namespace and check
   membership in `ctx.direct_namespaces`. Not a member → return a new
   `{:transitive_call_unauthorized, ref, requirers}` error, formatted the
   way `{:private_tool_unauthorized, ...}` is today (`lisp.ex:1002-1008`),
   rendering the teaching message from the `required_by` list captured in
   step 2.

   Guarding resolution (rather than application) also gets the re-export
   semantics right for free: a closure that a *prelude export returns* to
   session code was resolved under a `:prelude_export` origin, so it is
   handed out unchecked — that is the deliberate-re-export case (Cargo's
   `pub use` analogue), and applying it later pushes the prelude origin
   from its `bind_prelude_ref` metadata (`eval.ex:891-901`), so its own
   internal cross-namespace calls stay valid. Only *session-originated*
   naming of a transitive namespace is refused.
4. **Propagate the fields through evaluator sub-contexts.** Updating the
   top-level `EvalContext` struct is not enough: closure application and
   parallel worker paths build fresh contexts and copy selected fields by hand.
   The implementation must include `direct_namespaces` and
   `strict_transitive_calls` in `EvalContext.new/1`, `inherit_prelude/2`, the
   closure context construction paths in `lib/ptc_runner/lisp/eval/apply.ex`,
   and the `Lisp.run` option plumbing used by MCP session eval. The validation
   cases below must exercise user closures/HOFs so missing propagation cannot
   hide behind a top-level-only pass.
5. **Grant wiring, following the existing `Policy` lifecycle exactly:**
   add `strict_transitive_calls: false` to `Policy.Grant`
   (`mcp_server/.../sessions/policy/grant.ex:4-14`); parse and validate it in
   `parse_grant/2` (`policy.ex:377-407`) with a dedicated validator alongside
   `modes/2` / `prelude_store_level/2`; include it in `fingerprint/1`'s
   canonical JSON (`policy.ex:609-626`) so a grant change is detectable; read
   it at the same construction point as `filter_prelude`/
   `session_eval_tools` (`Session.snapshot_prelude/1`,
   `mcp_server/.../sessions/session.ex:953-959`) to decide the
   `EvalContext` fields for that session's `Lisp.run` call.
6. **No compiler changes, no new `Export` field, no change to introspection.**
   `dep_calls.transitive` lives on `prelude.form_graph`, not on `%Export{}`
   (`compiler.ex:759-827` only uses it to union `requires`/`tool_refs`) — the
   origin-stack approach above needs none of that, since it defers to the
   compiler's own proof instead of re-deriving it. `prelude/read`'s
   introspection tools are untouched because they never run through
   `EvalContext`/`origin_stack` at all.
7. **Composes with the Dependent Surface Variant without special-casing.**
   Attention (what `ns-publics`/the prompt inventory show) and contract
   (what a bare call may reach) read different data — `Prelude.exports`
   filtering vs. `direct_namespaces` membership — so `scoped_base_surface`
   and `strict_transitive_calls` can be enabled independently per session
   with no interaction to design for.

### Validation

This proposal's payoff — evolution safety at re-pin time — is harder to
measure directly than the Dependent Surface Variant's per-session
`catalog_ops` delta, and it should not inherit that measurement gate. Its
natural validation is a regression battery instead:

- an undeclared transitive call fails closed with the teaching error;
- an undeclared transitive reference in **value position** fails the same
  way — `(let [f paged_base/sample] ...)`, `(map paged_base/profile xs)`,
  and a bare constant ref all hit the `:prelude_ref` guard;
- a closure **returned by a directly-attached prelude's export** remains
  callable from session code, and its internal cross-namespace calls still
  work (deliberate re-export path);
- a session-defined callback passed *into* a prelude export
  (`%{type: :user_closure}` origin) is refused transitive naming exactly
  like top-level code — user code is user code regardless of call depth;
- a declared direct attach works exactly as before;
- prelude-internal (already-compiled) behavior is unchanged;
- role-policy parsing accepts only booleans for `strict_transitive_calls`,
  rejects unknown/malformed role keys as today, and grant fingerprints change
  when the flag changes;
- MCP session eval passes `strict_transitive_calls` and `direct_namespaces` into
  `Lisp.run`; non-MCP `Session`/`SubAgent` behavior is explicitly unchanged in
  first-slice tests;
- turn/evidence metadata marks relaxed diagnostic sessions
  (`strict_transitive_calls: false`) when selected preludes include transitive
  dependency closures, so later evidence readers can distinguish diagnostic
  reach-through from a validated recipe;
- replaying prior accepted gated-run evidence (`composable-demo-2-20260705`
  and `mcp-native-composable-library-demo-20260704`, at minimum) produces no
  new failures — a strict-calls change that quietly invalidated an
  already-accepted run would undermine the reproducibility this program
  depends on.

## Implementation Order

The two variants are independent — attention reads the presentation mask,
contract reads `direct_namespaces` membership; neither consults the other's
data — so either can land first, and enabling both per session needs no
interaction design. Facts that bear on ordering:

- **Contract Line first is the lower-risk start.** It is self-contained
  evaluator + policy work; every mechanism it needs was verified present
  (origin stack, `required_by` provenance, grant lifecycle); its validation
  is a local regression battery with no external dependency.
- **The Dependent Surface Variant carries the measured-promotion
  obligation** from its accepted review: a `catalog_ops` before/after on the
  motivating split with no task-output regression. That means its acceptance
  loop needs a bench-side run, not just unit tests — more coordination, and
  the honest possibility of a no-change demotion.
- Neither variant touches tier 3 (namespace unification), and tier 3 should
  not be started until both variants have settled the grant-model
  precedents they add.

## Store Capability Shape (Tier 3)

Prefer capability-split store preludes over one dynamically configured
`prelude/` namespace:

- `prelude/read` exposes read-only inspection: `list`, `history`, `read`,
  `source`, `forms`, `form-deps`, `deps`, `form`.
- `prelude/write` exposes mutation: `write`, `edit`, `set-default`, and depends
  on or composes with the read capability as needed.

This lets the prompt inventory, discovery surface, and authority requirements
match what the session actually selected. It also avoids a source/runtime
mismatch where a single prelude advertises functions that are disabled by
configuration and then fail later at call time.

An implementation could choose either separate namespaces:

```text
prelude_read/list
prelude_write/write
```

or one user-facing namespace assembled from selected components:

```text
prelude/list
prelude/write
```

The latter is nicer for users but requires careful duplicate-export and prompt
inventory handling.

## MCP Session Sketch (Tier 3)

Target session start behavior:

1. Parse `preludes` as the complete requested capability namespace set.
2. Resolve store refs and host-shipped capability refs through one selection
   mechanism.
3. Expand declared prelude dependencies and order the bundle.
4. Build the allowed backing-tool map from server policy.
5. Attach the selected prelude bundle with `requires` validation against that
   backing-tool map and the upstream runtime.
6. Reject the session if a selected capability requires authority the server did
   not grant.

Under this model, the current special case:

```json
{"mode": "write_capable"}
```

becomes something closer to:

```json
{"preludes": ["prelude/write"]}
```

with server policy still deciding whether `prelude/write` is allowed.

## Non-Goals (Tier 3)

- Do not make all built-in language namespaces preloadable packages. Core Lisp
  namespaces can remain curated and always available.
- Do not collapse `tool/` into prelude selection; the granted tool map remains
  the authority boundary.
- Do not let selected preludes bypass existing `requires` validation or private
  tool authorization.
- Do not implement this before the prelude dependency model can express and
  attach capability components predictably.

## Open Questions

For tiers 1-2:

- The first implementation scope is MCP stateful sessions. A later follow-up
  can decide whether non-MCP `PtcRunner.Session`, `SubAgent`, and `mix ptc.repl`
  should share the same `scoped_base_surface` and `strict_transitive_calls`
  controls.
- Relaxed diagnostic provenance is required, but the exact downstream evidence
  projection shape can still evolve. The first slice should at least stamp the
  turn log with the strict/relaxed setting and selected-prelude closure
  metadata; evidence-bundle item attributes can be added after the projection
  consumer needs them.

For tier 3 (original direction):

- Should capability variants be separate ids (`prelude-read`, `prelude-write`)
  or one id with configs (`prelude` + `read`/`write`)?
- If two selected components contribute the same namespace, should this be
  allowed only for host-shipped capability fragments, or should duplicate
  namespaces keep failing closed everywhere?
- How should `mix ptc.repl` expose the same model: `--prelude-store-seed` plus
  `--prelude prelude/read`, or a separate authoring-mode flag for local testing?
- How should prompt inventory distinguish host-shipped capabilities from
  store-authored capability libraries?
