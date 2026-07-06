# Grant Projection Legibility

**Status:** core runner slice implemented 2026-07-06: session grant projection
now carries filtered-export refs/reasons into `lisp_session_start`, turn-log
metadata, and analysis-time call errors. Boot-time empty-surface warnings remain
future follow-up. Filed 2026-07-06 from the
`composable-demo-3-source-first-20260706` bench run — the third bench→runner
handoff of that run. Revised the same day after an implementation-readiness
review that verified the code anchors; the review's corrections (analysis-time
error site, single projection function, summary-count start output,
empty-only boot warning) are folded in below. This is the **legibility/mitigation layer** for
[`dynamic-upstream-requirement-metadata.md`](dynamic-upstream-requirement-metadata.md):
that plan removes the over-filtering; this one makes any remaining filtering
self-explaining. Both build on the Slice C grant model in
[`composable-prelude-library-demo.md`](../composable-prelude-library-demo.md)
and reuse patterns landed in
[`prelude-selected-capability-namespaces.md`](prelude-selected-capability-namespaces.md)
tiers 1–2.

## Problem

Slice C's grant filter is an authority cut: an export whose tool authority a
finite role grant cannot prove is genuinely absent from the session's
evaluator table. As a boundary this is correct and stays. As an experience it
is illegible, and the bench has now paid for that three times in one day:

- the scoped-base-surface promotion run archived two invalid cells before
  finding that `upstream_tools: "all"` was required at all;
- the demo-3 Stage 2 analyst attached `paged_audit@1` cleanly, then spent
  Phase B budget probing why `(dir 'paged_audit)` was `[]` while
  `prelude/read` showed everything public, before documenting the split
  surface and working around it;
- the demo-3 Stage 6 validator (sealed failed stage, bench commit `3fc699f`)
  burned its entire turn budget against the same wall at the one stage where
  calling the export is the task, and never emitted its verdict.

The measured principle behind all three is the same one the
`scoped_base_surface` demotion established on the attention line: **an
unexplained divergence between two surfaces taxes attention** (there:
mask-vs-source inconsistency drove `catalog_ops` 4→8 re-probing; here:
filter-vs-store inconsistency drove budget-fatal probing). Narrowing a
surface is fine; narrowing it silently is what costs.

Three specific pathologies, all verified in the demo-3 traces:

1. **The error is wrong and its hint is actively harmful.** A grant-filtered
   call fails with `invalid_form: paged_audit/reconcile-totals is not a
   public export of namespace paged_audit. Discover its public exports with
   (ns-publics 'paged_audit) or (apropos "reconcile-totals").` The form *is*
   public in an attached prelude, and the suggested discovery calls return an empty
   set and nothing, respectively — the hint routes the model to surfaces
   that cannot explain the situation.
2. **Attach reports success while the callable surface is empty.**
   `lisp_session_start` returns clean `prelude_refs` (ids, checksums,
   `required_by`) with no indication that the grant removed every callable
   export — the one moment the server holds that information, it says
   nothing.
3. **No audit trail.** Turn metadata does not record the filtered surface,
   so a gate audit cannot detect an emptied surface without the model's
   cooperation — the same auditability gap `masked_namespaces` stamping was
   added to close for the presentation mask.

One design decision must be preserved, not "fixed": store introspection
(`prelude/list`, `prelude/forms`, `prelude/form`) is deliberately
grant-independent — *introspection stays open, calls get strict* is the
accepted demo-2 principle, and the demo-3 source-first mandate, the Stage 4R
review pattern, and the R5 referential-claim measurement all depend on
reading store truth regardless of session grants. The session surfaces
(`ns-publics`, `dir`, execution) are already mutually consistent and
truthful. The fix is therefore **not** to unify store truth with session
truth; it is to make the session explain its own reductions.

## Direction: carry the filtered exports as data

The inverse of the pattern `scoped_base_surface` already established. There,
a presentation mask was carried as data alongside a *complete* export table.
Here, keep cutting the export table (the authority boundary is unchanged)
but **retain the removed export refs, each with a reason, as attach
metadata**. One metadata object then feeds all three surfaces:

1. **Attach status in the `lisp_session_start` result.** Extend the
   structured content with `filtered_export_count`, `empty_namespaces`,
   per-namespace filtered counts, and a bounded `filtered_exports` sample as
   `{ref, namespace, name, reason}` entries (e.g.
   `reason: "finite_upstream_grant"`). Do **not** list callable export names —
   that duplicates `ns-publics`/`dir` and adds surface the M2 result says is
   not free. Zero-callable namespaces must be explicit even when entry lists
   are bounded; bound the `filtered_exports` list after N entries (counts stay
   exact) so a large store cannot bloat the start response. This extends the
   selection metadata already preserved on resolved refs (`fc848ed0`); it is
   *not* a new attach API — sessions freeze their bundle at start, and a
   separate attach verb would contradict that design.
2. **A specific, teaching error at the call site.** Distinguish three cases
   that today collapse into one message:
   - *namespace not attached* — current behavior, unchanged;
   - *attached, but this export was filtered by grant policy* — new message
     naming the filter and the fix, in the house style of
     `private_tool_unauthorized` / `transitive_call_unauthorized`, e.g.:
     `paged_audit/reconcile-totals is public in an attached prelude but was removed
     from this session by the role's finite upstream_tools grant; see
     filtered_exports in the session start result.` The hint must point at
     the attach status, never at `ns-publics`/`apropos`;
   - *compiled source has no such public var* — current message and text,
     unchanged (see replay-stability note below).
   **Corrected site (implementation-readiness review):** this error is
   rendered at *analysis* time, not evaluation — `unknown_export_error/2`,
   `lib/ptc_runner/lisp/analyze.ex:1497`, emitted when a prelude namespace
   is known but the ref is not among its (already grant-filtered) exports.
   Threading metadata to `EvalContext` alone would miss it entirely; a
   qualified ref to a filtered export never survives analysis to reach an
   eval dispatch site. The projection report must therefore reach the
   analyzer's prelude scope (the same input that currently makes the
   namespace "known" and the export absent). Implementation shape: branch
   on filtered-ref membership *before* falling through to the existing
   `unknown_export_error/2` render, leaving the default path byte-identical
   (see the replay-stability constraint below).
3. **Turn metadata stamp.** Record the filtered surface per session in the
   turn log, symmetric to `masked_namespaces` presentation provenance, so
   gate audits detect an emptied or reduced surface mechanically.

Plus one boot-time affordance: **warn when a role/seed combination reduces a
seeded prelude to zero callable exports**, in the spirit of the existing
"role grant can't reach evidence tools" boot warning (`3045c48d`).
Reduced-but-nonempty surfaces are a legitimate outcome of a deliberately
narrow role and would make the warning chatty — log those at debug/boot
diagnostics only. Empty-only is sufficient for the observed failure mode:
both demo-3 instances were zero-callable cases (`paged_audit`'s single
public export filtered; all six `paged_base` exports filtered), so the
empty-only default would have converted both into config fixes before
launch.

### Implementation shape (one projection, three consumers)

`Policy.filter_prelude/2`
(`mcp_server/lib/ptc_runner_mcp/sessions/policy.ex:168`) already owns the
authority decision and prunes both `exports` and `source_index`
(`policy.ex:270`). Do not re-run or duplicate that logic per consumer:

1. Add `Policy.project_prelude(prelude, grant)` returning
   `{filtered_prelude, projection_report}`; `filter_prelude/2` becomes (or
   delegates to) it, so the authority decision stays in exactly one place.
2. Store the projection report on session state at start.
3. Feed `lisp_session_start` structured content and the turn-metadata stamp
   from that same report.
4. Teach the analyzer's prelude scope to consult the report's filtered refs
   before `unknown_export_error/2` falls through to its existing render.
5. Boot warning: compute per-role projections of seeded preludes at boot;
   warn only on zero-callable results.

One invariant to state, not just implement: **session-visible compiled
source is projected; store introspection is not.** `filter_prelude/2`
already prunes the compiled `source_index` alongside exports, while
`prelude/read`'s store tools are a separate, grant-independent path. That
split is what keeps "introspection stays open" true while sessions execute
against the projected surface — the projection report is the record of the
difference between the two, which the system currently computes and throws
away.

## Validation

- Attaching under a finite grant that filters N exports: the start result
  lists the N refs with reasons; `ns-publics`/`dir` remain the truthful
  reduced set; store introspection output is byte-unchanged.
- Calling a grant-filtered export yields the new teaching error naming the
  grant and pointing at the attach status — not the store-discovery hint.
- Calling a genuinely nonexistent public var keeps the **current message
  byte-for-byte** — concretely, the default `unknown_export_error/2` branch
  (`analyze.ex:1497`) is untouched; only a new pre-check on filtered-ref
  membership branches away from it. The accepted 20260704 evidence contains
  that error class (`paged_base/opt is not a public export …`), and the
  bench replay harness (`evidence-replay-20260706`) asserts error-text
  stability for replayed accepted stages. The new grant-filtered message class is replay-safe
  because no accepted-run evidence contains a grant-filtered call (verified:
  20260704 predates role grants; demo-2's stages never called store-prelude
  exports).
- Turn events carry the filtered-surface stamp; an audit query over the turn
  log can flag "attached namespace with zero callable exports" without
  reading model output.
- Boot warning fires for a role/seed combination that produces an emptied
  callable surface, and stays silent otherwise.
- With no finite grants configured, all surfaces and messages are unchanged.

## Non-Goals

- **No session-aware store introspection.** `prelude/forms` and friends stay
  grant-independent; a `callable_in_current_session` field on store reads
  would mix the store and session layers.
- **No new discovery exports.** A `prelude/callable?` helper was considered
  and rejected: `(ns-publics 'ns)` already answers the question with session
  truth in one call, and M2 measured what added public surface costs. With
  the teaching error and attach status in place, the probing loop this
  helper would serve disappears.
- **No change to the authority cut.** Filtered exports stay uncallable;
  nothing here widens authority or adds a bypass.
- **Not the root fix.** Exact upstream-requirement metadata for dynamic
  `tool/call` exports remains
  [`dynamic-upstream-requirement-metadata.md`](dynamic-upstream-requirement-metadata.md)'s
  scope. This layer stays useful after that lands: some export will always
  be legitimately filtered under some grant, and it should say why.

## Bench-Side Counterparts (recorded here for cross-reference)

Not this repo's work, tracked in the bench: gate_policy v4 adds a
callable-export preflight probe run under the stage's own role token,
asserting the specific exports that stage's task requires, plus a preflight
failure on unapplied sealed role-amendment deltas. Those checks catch
config-caused emptiness before launch; this plan makes the runner explain
any emptiness that remains.
