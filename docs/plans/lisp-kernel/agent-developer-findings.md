# Findings handoff: correction feedback, analysis ergonomics, prelude layering

**Status:** findings and proposals; written 2026-08-01 on branch
`worktree-incident-evidence-compiler`, revised 2026-08-02 and again on
2026-08-03 after this branch rebased onto `main`. Findings 4 and 5 and the
prelude-layering section are resolved in `main` by
[PR #1162](https://github.com/andreasronge/ptc_runner/pull/1162) (`3dddb84c`).
Findings 2, 3, and 6 are resolved there too, none of them by this branch's work:
`main` landed its own union fix, `describe/1` predates the branch split, and
finding 6 shipped in `ba983f95`. Finding 1 is still open in
[#1161](https://github.com/andreasronge/ptc_runner/issues/1161). Findings 7–9
are unstarted.

Read [the trace-analysis handoff](analysis-tooling-handoff.md) first — it is
the entry point for this branch and records what shipped, what is unlanded, and
what is still worth looking at.

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
| 2 | Tagged-union violations reported another branch's fault | fixed in `637958c1`, **not yet in `main`** |
| 3 | `ValueContract.describe/1` exists and is unreachable | fixed on this branch |
| 4 | Analysis preludes turn a rejected query into an empty result | **fixed in `main`** (#1162) |
| 5 | No shared pagination traversal | **fixed in `main`** (#1162) |
| 6 | Private inspection is interactive-only | **fixed in `ba983f95`** |
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

**Still only on this branch.** `637958c1` is not an ancestor of `main` and the
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

## 3. `ValueContract.describe/1` is unreachable — fixed, unlanded

The function renders a contract's shape from the compiled schema, and its own
documentation states the motivation exactly:

> A task prompt that paraphrases its own result schema drifts from it, and the
> drift only surfaces as a rejected result after a live run has been paid for.

Previously, nothing in `lib/` called it. One test referenced it and no
capability exposed it to a workflow.

Fixed by exposing the compiled description through the workflow-only
`kernel/result-contract-description` function alongside
`kernel/validate-result`. It returns `nil` when no result contract is active.
The incident compiler now inserts this generated shape into its task instead
of restating the schema's keys. Runner and REPL integrations expose the same
route, and an agent-boundary regression proves the generated shape reaches the
model request.

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

## 6. Private inspection is interactive-only — fixed

Resolved in `ba983f95` by `--private-unattended`, a second authorized private
destination beside the attached terminal. Exactly one must be supplied. Under it
the profile admits `-e`/`--load`/script/stdin and `--format jsonl`. The check
lives in `AnalysisSessionBuilder`, so an embedding host gets the same option.

**The reasoning in the original report below was wrong on two counts**, and both
took several rounds to find:

The gate was never containing the access. The Viewer already served the same
private records non-interactively and fully validated —
`ViewerAdapter.pin_inspection/2` runs `InspectionArtifact.load/1` and
`validate_correlations/2` — through `GET /api/inspection/runs/:run_id`. There
was no integrity gap to close.

Nor was the terminal check access control. `isatty/1` cannot distinguish a
human's terminal from a pseudo-terminal allocated by `script(1)`, `tmux`, or
`ssh -t`; verified that an agent's non-interactive shell under
`script -q /dev/null` reports both streams as terminals and opens the private
profile. A same-UID caller can also read the artifact directly. The check is an
accident guard — it keeps private values out of a log or transcript by mistake —
and that is now documented in `AnalysisSessionBuilder`'s moduledoc so nobody
designs against it as a boundary again.

A five-draft design for an owner-only sink file was written and deleted. It was
defending against an adversary the trust boundary excludes, and its blocker list
kept proposing resolutions the code contradicted.

`stable-cli-contract.md` was amended in two places, since it had recorded the
code-owned profile as keeping an explicit-terminal rule.

**Former blocker, now fixed.** `inspection-analysis-v2` used to return
`memory_exceeded` for any evaluation, which made this feature unusable end to
end. The cause was unrelated to private analysis: every capability callback
closed over the whole mission environment, and the flat spawn copy into the
sandbox duplicated it once per callback, inflating the pre-eval baseline until
the heap budget was gone. Fixed in `f8d7cea9`; the `mix run` versus `mix test`
split was marginality, not environment. See
[the trace-analysis handoff](analysis-tooling-handoff.md) for the measurements.
Private querying now works end to end through
`mix ptc.repl --private-unattended`.

The original report follows.


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

## Branch work

The finding 4 and 5 prototype was superseded by #1162, which shipped both fixes
in better form. Those obsolete modifications are not part of this branch.

<<<<<<< HEAD
Finding 2 landed on `main` independently as `selected_branches/3`, which also
resolves branch identity through `evaluationPath`. This branch's version was
superseded and dropped when it rebased; only its regression tests were kept.

The fix for finding 1 is written on `pre-rebase-2026-08-03` but does not apply
to `main`, which rebuilt the violation model to report structured `segments`
behind `CommandContractAuthority` rather than path strings. Re-landing it means
re-implementing it on that structure, not replaying the commit — which is why
it was skipped rather than merged during a conflict resolution. #1161 remains
the tracking issue.
=======
The fixes for findings 1–3 are the branch work that is still needed and still
unlanded, along with finding 6's `--private-unattended` destination and the
sandbox tool-grant fix that made it usable.
>>>>>>> b31361ad (docs(plans): make the handoff docs accurate for a cold start)

## Suggested order

1. ~~**Finding 4 alone** into the primitives.~~ Done in #1162, together with 2.
2. ~~**Findings 5 + the layering section**: build `log.analysis`.~~ Done in
   #1162.
<<<<<<< HEAD
3. ~~**Finding 2**: land the union fix.~~ Landed on `main` independently; this
   branch's version was dropped as superseded.
4. ~~**Finding 3**: expose `describe/1`.~~ Predates the branch split.
5. **Finding 1** proper, tracked in #1161. Needs re-implementing on `main`'s
   `segments`/`CommandContractAuthority` violation model.
=======
3. **Finding 2**: land `637958c1`, which is written and tested but not in
   `main`.
4. ~~**Finding 3**: expose `describe/1`.~~ Done on this branch (`9e497012`).
5. ~~**Finding 1** proper, tracked in #1161.~~ Done on this branch
   (`bb2be8cf`); the issue is still open and references neither commit.
>>>>>>> b31361ad (docs(plans): make the handoff docs accurate for a cold start)
6. ~~**Finding 6**, sequenced with the stable CLI plan.~~ Done in `ba983f95`;
   the CLI plan was amended rather than sequenced against.
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
