# Findings handoff: correction feedback, analysis ergonomics, prelude layering

**Status:** findings and proposals; written 2026-08-01 on branch
`worktree-incident-evidence-compiler`, revised the same day after
[PR #1162](https://github.com/andreasronge/ptc_runner/pull/1162) merged as
`3dddb84c`. Findings 4 and 5 and the prelude-layering section are resolved in
`main`. Finding 2's fix is written but not yet landed. The rest are unstarted.

These surfaced while building the incident-evidence compiler reference
application and then investigating its own traces. Most of them share a theme
worth naming up front: **the runtime's evidence and correction machinery is
drawn for a human operator at a terminal, and the agent-developer persona —
someone building and debugging a PTC application programmatically — falls in
the gap each time.** The exception is the last section, which is an
architecture invariant that was undocumented until a change violated it.

## Where things stand

| # | Finding | Status |
| --- | --- | --- |
| 1 | Correction cannot name an undeclared key; counters do not descend | open, [issue #1161](https://github.com/andreasronge/ptc_runner/issues/1161) |
| 2 | Tagged-union violations reported another branch's fault | fixed in `c236b981`, **not yet in `main`** |
| 3 | `ValueContract.describe/1` exists and is unreachable | open |
| 4 | Analysis preludes turn a rejected query into an empty result | **fixed in `main`** (#1162) |
| 5 | No shared pagination traversal | **fixed in `main`** (#1162) |
| 6 | Private inspection is interactive-only | open, needs a design decision |
| 7 | Canonical annotation vocabulary is closed | open |
| 8 | Application failure kinds are fingerprinted, not named | open |
| 9 | Verification cannot run inside the agent loop | open |
| — | Leaf preludes must not depend on leaf preludes | **withdrawn** — see below |

## 1. Correction cannot name an undeclared key

Tracked in [issue #1161](https://github.com/andreasronge/ptc_runner/issues/1161)
with a full reproduction; summarized here because finding 3 is its cheapest
partial remedy.

A live agent run lost its entire turn budget to this. The model wrote timeline
entries keyed `timestamp`/`description` where the contract declares
`observed_at`/`statement`. It received `timeline[9].(undeclared)` on five
consecutive correction turns — the position, never the name — and
`missing_required` stayed `[]` throughout because that field is computed at the
root object only and does not descend into array items. Both halves of the
failure were withheld: what it added, and what it omitted.

The redaction itself is correct. The key name is caller-authored content.

**Proposed:** emit the **declared key set at the violating path**. Those names
come from the compiled schema, not the caller, so they disclose nothing and let
a model diff its own object against what is allowed. Secondarily, make
`missing_required`/`undeclared_key_count` descend, or drop them in favour of
per-path violations — reporting `undeclared_key_count 0` beside an
undeclared-key violation is actively misleading.

## 2. Tagged-union violations reported another branch's fault — fixed, unlanded

**Still only on this branch.** `c236b981` is not an ancestor of `main` and the
`schemaLocation` selection is absent from `main`'s `ValueContract`. This needs
its own PR.

`ValueContract.classify/2` selected a union's error units by list position,
assuming `JSV.normalize_error/1` returns one unit per `oneOf` alternative in
schema order. It returns a flat list ordered by instance location with all
alternatives interleaved, so indexing landed on an arbitrary branch — usually
one the discriminator had not selected, whose only complaint is that it was
handed keys it never declared.

Every violation in a tagged-union contract therefore reported the same wrong
thing. Five distinct defects in the incident compiler's contract all classified
identically as `:boolean_schema` at `timeline`; a minimal reproduction reported
`kind: :const` on the discriminator, telling a correcting model that the one
field it had got right was wrong.

Fixed by selecting units on their `schemaLocation` prefix, matching both the
branch root and nested locations — a keyword failing inside the branch reports
a nested location, while the branch's own `required`/`additionalProperties`
failure reports the root.

Worth carrying forward as a testing lesson: the pre-existing test for this
behaviour passed before and after the fix. Its union selects branch 1, and the
flat list happened to carry a usable unit at that position. Coverage of a
union-selection rule needs a case that selects **branch 0**.

## 3. `ValueContract.describe/1` is unreachable

The function renders a contract's shape from the compiled schema, and its own
documentation states the motivation exactly:

> A task prompt that paraphrases its own result schema drifts from it, and the
> drift only surfaces as a rejected result after a live run has been paid for.

Nothing in `lib/` calls it. One test references it. No capability exposes it to
a workflow.

Consequence: every application with a closed contract hand-writes its key set
into the prompt and carries precisely the drift the function exists to prevent.
`incident_compiler/compiler.clj` does this today, and adding it was what
finally let a live model satisfy the contract.

**Proposed:** expose it through a workflow capability alongside
`kernel/validate-result`, so an application generates its prompt shape from the
compiled contract instead of restating it. This is also the cleanest partial
answer to finding 1: a model that has the declared shape in front of it does
not need the offending key named back.

## 4. Analysis preludes turn a rejected query into an empty result — fixed

Resolved in `main` by #1162. `log.core` and `inspection.core` now call
`cap/unwrap!` directly instead of carrying private copies that returned the
envelope. An over-limit query fails the form; a rejected query is no longer
indistinguishable from an empty trace. Covered by a regression asserting
`(log/runs {"limit" 101})` fails.

The original report follows.


`log.core` and `inspection.core` each define a private `unwrap` that returns
the error envelope on failure. A caller then reads `(get response "items")` as
`nil`, and `count` reports `0`.

Observed directly:

```clojure
(count (get (log/turns run-id {"limit" 200}) "items"))   ;; => 0
```

The trace holds 112 events. The limit exceeds the hard maximum, the query is
rejected, and **a rejected query is indistinguishable from an empty trace.**

The repo already ships the correct primitive, whose docstring names this hazard:

> `unwrap!` … a caller that forgets treats an error map as ordinary data. This
> fails instead, so an unhandled provider error stops the program rather than
> flowing onward as a plausible-looking result.

Both analysis preludes predate or ignore it. These are the two preludes a human
or agent uses to investigate an incident in the runtime, which is where a
silently-empty result is most likely to be believed.

**Proposed:** fail on the error envelope. This is a defect in the primitive and
no higher layer can repair it — a prelude composing `log.core` inherits the
silent `nil`. It is a behaviour change for existing callers: what silently
returned nothing now fails loudly. It changes the bundle hash and therefore the
pinned analysis-profile digest.

## 5. No shared pagination traversal — fixed

Resolved in `main` by #1162, in a stronger form than proposed. `cap/collect-pages`
is the one traversal; `log.analysis` and `inspection.analysis` are new ergonomics
components wrapping it as `all-*`. It takes a required `max-pages` and reports
`complete? false` rather than returning a prefix that looks whole, and it
additionally validates `snapshot_hash` across pages, failing `:snapshot-changed`
instead of concatenating items from two different snapshots. `cap/with-cursor`
now clears an existing cursor when passed `nil`, so a stale cursor in the caller's
options cannot pin the traversal to one page.

The original report follows.


`docs/trace-log-contract.md` specifies every collection query identically:
`items`, an opaque `next_cursor` bound to source, operation, and normalized
filters, plus `truncated`/`omitted_count` and deterministic ordering. One
traversal serves all of them. `cap/with-cursor` exists but deliberately stops
short — "Traversal stays explicit in the caller" — so every call site
hand-rolls the loop, and both analysis preludes duplicate the helper privately.

The cost is not only verbosity. A page is capped well below the size of an
ordinary agent run, so the natural first query analyses a partial page and
returns a plausible answer:

```clojure
(def evs (get (log/turns run-id {"limit" 50}) "items"))
(frequencies (map #(get % "type") evs))   ;; 50 of 112 events, silently
```

A prototype traversal (uncommitted, see below) reads all 112 across 3 pages and
reports `{"complete?" true "pages" 3}`. It takes a required `max-pages` and
reports `complete? false` rather than returning a prefix that looks whole,
matching the repository's stance against silent caps.

**Proposed:** ship it, but see the layering section — the prototype is in the
wrong component.

## 6. Private inspection is interactive-only

`inspection-analysis-v1` requires terminal attachment and `--private-terminal`,
and rejects `--eval`, `--load`, scripts, stdin, and `--format jsonl`. The
`log-analysis-v1` profile has a documented "JSON Lines for coding agents" mode;
the private profile excludes it.

The private plane is where the answers are. Every substantive finding from
debugging the incident compiler came from it and none from the canonical trace,
which is sanitized by design:

| Finding | Source |
| --- | --- |
| Model refetching all records every turn | `evaluation-source` |
| Untyped signatures causing wasted `keys` probing | `evaluation-source` + messages |
| The five-rejection correction loop | `llm-request` messages |
| Wrong key names in timeline entries | `evaluation-source` |
| Finding 2 itself | correction feedback inside the transcript |

An agent with filesystem access reads the raw artifact instead, which loses the
correlation validation that is the private profile's main safety feature —
artifacts are otherwise checked against the corresponding run in the immutable
canonical trace, and malformed, replaced, uncorrelated, or oversized input
rejects the whole source. **The gate is not containing the access; it is
ensuring the access happens unvalidated.**

**Proposed:** admit `-e` and `--format jsonl` on the private profile when an
explicit owner-only sink is named — `--private-sink PATH`, reusing the
`PrivateDirectory` 0600 machinery that `--private-output` already uses. Private
values land in that file; stdout carries only the safe analysis-trace records
the profile already emits, which never include evaluated source, returned
private values, prints, or REPL history. The authorization check becomes "an
authorized sink exists" rather than "a terminal is attached." A human still
names the sink.

This touches the CLI surface owned by
[`stable-cli-contract.md`](stable-cli-contract.md) and should be sequenced with
it.

## 7. Canonical annotation vocabulary is closed

`SafeMetadata.annotation?/2` admits only `progress` with a single `stage` key
and `agent-action` with `turn`/`kind`. An application-level verification
outcome — how many citations were checked, how many failed to resolve — cannot
reach a normal trace. Rejected annotations fail silently from Lisp, since
`workflow.event/annotate` discards the response.

The incident compiler emits `validating` then `completed`/`failed` so its
refusal is observable at all, and keeps the counts in the failure value.

**Proposed:** either a bounded application-annotation type with a closed value
grammar (bounded name, small integer counters), or accept the limit and
document that application-level outcomes belong in the result value. Making
`annotate` fail on rejection would at least surface authoring mistakes.

## 8. Application failure kinds are fingerprinted, not named

A refusal surfaces publicly as `failure_kind_fingerprint`, so a reader cannot
distinguish `unresolved-citations` from any other application failure without
computing the fingerprint. Correct for privacy, awkward for an application
whose entire point is a legible refusal.

**Proposed:** allow a manifest to declare a small closed vocabulary of its own
failure kinds, admitting those to the public taxonomy while everything else
keeps fingerprinting. Unspecified is fine too; recorded because it recurs.

## 9. Verification cannot run inside the agent loop

Mission capabilities are unreachable from a workflow except through
`kernel/eval-source`, and the loop's only in-loop validation hook is the result
contract. Application-defined verification therefore runs after the loop ends,
so an unresolved citation fails the run outright while a contract violation
earns a correction turn.

For the incident compiler this is the difference between "the model gets one
chance to fix a fabricated citation" and "the run is lost."

**Proposed:** an application-supplied in-loop validator invoked where
`kernel/validate-result` is today, returning the same bounded structural
classification. Larger than the others and worth its own design.

## Leaf preludes must not depend on leaf preludes — withdrawn

**This section's conclusion was wrong and is retained only as a record.**
Reviewed in `prelude-composition-and-reuse.md` (since retired) and settled by
#1162, which established the opposite: components compose freely through
declared acyclic dependencies, and `log.core`/`inspection.core` now depend on
`cap`.

The central claim below — that "whoever assembles the closure … must name every
member" — is false. `Library.resolve_components/1` expands the closure
transitively, and both named paths (`Manifest.components/2` and
`AnalysisProfile.assemble/3`) use it. Only raw `compile_bundle/1` callers need a
closed set. The remaining consequences were bookkeeping: one line in
`@namespaces`, one pinned digest, one test. #1162 also removed the ordering trap
those checks carried, deriving profile identity from the compiled environment
and validating declared sets order-independently.

The guidance actually recorded in `docs/guides/kernel-maintainer.md` is:

> Components may compose other components through declared acyclic
> dependencies. Edges should point toward lower-level reusable behavior …
> Evaluated source can call every public export in the resolved bundle,
> including `:discoverable` exports omitted from model prompts, so every new
> edge is also a callable-surface review.

The original argument follows.

Only three of the fourteen shipped components declare dependencies:

```
agent.prompt → kernel
agent.core   → agent.feedback, agent.native, agent.prompt, agent.retry,
               kernel, llm, result, workflow.event
agent.main   → agent.core
```

Every other component is a leaf: `kernel`, `cap`, `result`, `llm`,
`workflow.event`, `agent.native`, `agent.feedback`, `agent.retry`, `log.core`,
`inspection.core`.

The pattern is direction. Leaves are capability-facing primitives — each wraps
host capabilities and provides the ordinary Lisp API for them. The three
non-leaves are composition layers built on top. Every edge points from a higher
layer down to a primitive; none points sideways between two primitives.

`PtcRunner.Kernel.compile_bundle/1` requires a **closed** set:
`Library.component/1` does not expand dependencies, and `BundleCompiler`
rejects any set whose declared dependency IDs are not all present. Whoever
assembles the closure — a manifest's component list, or a profile's
`@component_ids` — must name every member.

Adding `"log.core" => ["cap"]` to share a helper broke that. `log.core` is a
primitive, `cap` is a primitive, and the edge went sideways. Consequences:

- `compile_bundle([log_core_component])` fails with
  `missing_component_dependency`, so any caller installing the base alone
  breaks. `TraceCapabilityTest` asserts exactly this, and it exists because the
  next assertion is the payoff: assembling a mission from that bundle with no
  grants fails with the precise list `["trace-counters", "trace-get-run",
  "trace-list-runs", "trace-list-turns"]`. **Authority is derivable from the
  compiled artifact**, and only for a closed base.
- The analysis profile's `@component_ids` and `@namespaces` both change, and
  both feed the profile digest, so the attested identity of `log-analysis-v1`
  moves for a reason unrelated to what it does.
- The reachable namespace widens for every consumer of the base.

The correct shape is already specified in `docs/trace-log-contract.md`:

```
log.analysis
  depends: log.core
  requires: trace-counters
```

> Higher-level preludes may compose it. … Preludes may change ergonomics,
> projections, defaults, or analysis policy. They cannot expand the source
> grant, bypass bounds/sanitization, or acquire private trace access.

"May change ergonomics … defaults" describes finding 5 precisely. A new
`log.analysis` depending on `log.core` is the same shape as
`agent.main → agent.core`, keeps the primitive a closed leaf with an unchanged
hash, and makes the layer swappable as the contract intends.

**Guidance to record somewhere durable** — the maintainer guide is the natural
home:

> A shipped prelude that wraps host capabilities is a leaf and stays one.
> Shared helpers go into a component that depends on the leaves, never into a
> dependency between them. A leaf must compile as a closed set of one, because
> that is what makes its required capabilities derivable from the compiled
> bundle.

## Uncommitted work on this branch

The finding 4 and 5 prototype still in
`priv/preludes/kernel/log.core.clj` and `inspection.core.clj` is **obsolete**.
#1162 shipped both fixes in better form, so these modifications now regress
`main` and should be discarded rather than landed.

The union fix for finding 2 (`c236b981`) is the one piece of this branch's work
that is still needed and still unlanded.

## Suggested order

1. ~~**Finding 4 alone** into the primitives.~~ Done in #1162, together with 2.
2. ~~**Findings 5 + the layering section**: build `log.analysis`.~~ Done in
   #1162.
3. **Finding 2**: land `c236b981`, which is written and tested but not in
   `main`.
4. **Finding 3**: expose `describe/1`. Small, and it is the cheapest partial
   remedy for finding 1.
5. **Finding 1** proper, tracked in #1161.
6. **Finding 6**, sequenced with the stable CLI plan.
7. Findings 7–9 as separate design work.

## Related documents

- [`stable-cli-contract.md`](stable-cli-contract.md) — owns the CLI surface
  finding 6 touches.
- [`../../trace-log-contract.md`](../../trace-log-contract.md) — normative for
  paging, bounds, and the `log.analysis` layering.
- [`../../guides/kernel-maintainer.md`](../../guides/kernel-maintainer.md) —
  now carries the component-composition, profile-contract, and profile-ID
  versioning guidance that the withdrawn section proposed.
- [`../../guides/components-and-preludes.md`](../../guides/components-and-preludes.md)
  — now documents dependency scoping, that evaluated source sees the whole
  bundle, and the `cap` / `*.core` / `*.analysis` layering.
- `incident_compiler/README.md` — records findings 1, 7, 8, and 9 as they were
  hit, with the live-run evidence.
