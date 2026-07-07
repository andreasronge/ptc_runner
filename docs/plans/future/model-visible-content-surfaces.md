# Model-Visible Content Surfaces - Plan

**Status:** future plan, gated. This is not approval to add a broad
`content/*` namespace. The first implementable slice is inline truncation
metadata and exact hints at the point where truncation is shown, plus reuse of
the existing `log/` introspection substrate. Add no new namespace unless the
hint-only path fails measured tasks.

## Context

Every model-facing surface has the same tension: the runner must keep context
bounded, but the model sometimes needs to inspect more than the default preview.
This shows up for evidence content, eval results, printed output, turn
summaries, tool-call summaries, diffs, and logs.

The current default behavior is useful but coarse. A large value gets a bounded
preview, and the turn log can usually prove that an item or tool was touched.
It often cannot prove which span the model actually saw, whether a search was
used instead of a read, or whether a later claim was grounded in the visible
part of a prior result.

The shipped paginated-read work already answers one tempting generalization:
large source traversal is a tool concern, not a retained-result concern. See
[`../chunked-tool-results-and-data-prelude.md`](../chunked-tool-results-and-data-prelude.md).
Large sources should be exposed through bounded paginated tools, and page
position should remain ordinary program data.

The archived turn-log/prelude derivation plan also settled the authority shape
for self-improvement: derived analysis must preserve the two-grant rule. See
[`../archive/turn-log-and-prelude-derivation.md`](../archive/turn-log-and-prelude-derivation.md).
Any model-visible prior-turn surface must build on that rule rather than invent
a second authority path.

## Working Principle

Default views should orient; explicit reads should substantiate.

The default presentation should be brief, stable, and good enough for ordinary
use. When the model needs more, it should have explicit bounded ways to drill
down, and those drill-down actions should be visible in the trace.

The model-editable layer may provide navigation helpers over stable primitives,
but must not replace runner-owned automatic rendering. Defaults, automatic turn
summaries, and provenance records remain infrastructure.

Do not make the model infer stable artifact addresses from budget text such as
`Turn 3 of 5`. That text is useful for loop orientation, but it is not a
dereference contract. If recovery exists, the renderer should provide the exact
opaque ref or exact call form beside the truncated value.

## Scope Rule

Only create refs for content that cannot safely or honestly exist as an
ordinary PTC-Lisp value.

In scope:

- runner-truncated prior-turn artifacts;
- printed output that was compacted in the public step envelope;
- bounded evidence artifacts retained by the runner or host;
- turn-log records where recovering prior knowledge is different from reading
  the source again.

Out of scope:

- large external sources that can be paged by their source tool;
- ordinary program values already present in the eval;
- "hold this large tool result and slice it later" designs;
- refs to prelude source or public docs where existing `doc`, `meta`, `source`,
  `dir`, and paginated source tools already answer the need.

For ordinary in-program values, the answer is still `def`, `let`, `subs`,
`take`, `drop`, `slice`-style helpers, or a focused prelude function. A second
ref world there adds discovery cost without adding authority or provenance.

## Architecture: Core First, Prelude Facade

Do not build a second turn-log access stack. The existing `log/` introspection
surface is the starting point.

`PtcRunner.TraceLog.Introspection` already ships the main shape this plan wants:
a host-shipped `log/` prelude over host-owned read-only tools, usable without
MCP. It supports in-memory sinks, JSONL paths, turn-log directories, and loaded
event lists; returns paged envelopes for sessions, turns, programs, and tool
calls; computes projections host-side so the sandbox pays only for each bounded
result; and fails closed when the required host tools are not granted.

The first implementation question is therefore not "add `turns/*`?" It is:
can the model-facing need be met by better truncation hints and existing `log/`
introspection, without requiring the model to discover another helper?

A separate `turns/*` namespace is justified only if experiments show that
current-session recovery needs a smaller, more discoverable API than `log/`,
and only if it reuses the same projection, paging, holder, grant, and trace-log
machinery.

## Existing Reusable Pieces

Reuse these rather than duplicating them:

- `PtcRunner.TraceLog.TurnEvent` for the canonical turn-event shape shared by
  `Session` and `SubAgent`;
- `PtcRunner.TraceLog.record_turn_event/1`, memory sinks, JSONL collectors, and
  `TraceLog.recording?/0` for emission;
- `PtcRunner.TraceLog.MemorySink` for bounded in-memory retention with
  oldest-first eviction;
- `PtcRunner.TraceLog.Introspection.Holder` for host-side ownership of loaded
  event lists, lifecycle tied to the grant owner, and grant-time size caps;
- `PtcRunner.TraceLog.Introspection.tools/2` for host-bound `log_*` closures;
- the `log/` prelude source from `Introspection.prelude_source/0`;
- the shared page envelope: `"items"`, `"next_cursor"`, `"has_more"`,
  `"limit"`;
- existing filters: tags, driver, status, from, and to;
- existing projections for sessions, turns, programs, tool calls, counters,
  catalog ops, and duplicate-call analysis via `args_hash`.

What is already done:

- direct non-MCP use works through `PtcRunner.Lisp.run/2` with
  `prelude: Introspection.prelude_source()` and
  `tools: Introspection.tools(source)`;
- `mix ptc.repl --log-prelude` attaches the same surface to the REPL;
- SubAgent and Session turns both emit canonical turn events;
- large log analysis has an alternate upstream-backed example while preserving
  the semantic `log/` API.

What is not done:

- full omitted-span recovery for result/print/tool payloads. Turn events store
  bounded, sanitized previews, not the original full result bytes;
- a retained-artifact store that keeps recoverable payloads separately from the
  audit log;
- dereference provenance for page/search over retained payloads;
- per-artifact grant rules for recovering private upstream/evidence results;
- current-session convenience helpers that avoid requiring the model to first
  discover a correlation id.

## Prelude Facade

Any new model-facing convenience should be a host-shipped prelude over core
retained-artifact primitives, not an MCP-server-only feature.

The model-facing API can live in a prelude because its job is ergonomic:
listing turns, choosing refs, paging, searching, and composing higher-level
views. The authority-bearing work must stay in runner-owned code:

- retaining compacted artifacts;
- enforcing grants and parent/child visibility;
- applying eviction policy;
- returning bounded pages/search hits;
- logging provenance for every drill-down.

That split keeps the feature available through both direct embedding APIs and
MCP:

```text
PtcRunner.SubAgent.run/2 or PtcRunner.Session.eval/3
  -> records turn events through TraceLog
  -> optionally records recoverable artifacts into a retained-artifact store
  -> attaches log/ or a tiny current-session facade when enabled
  -> the prelude calls core-backed primitives
  -> every dereference records provenance through TraceLog

ptc_runner_mcp
  -> configures the same core retained-artifact store and prelude selection
  -> exposes the same behavior through MCP session roles
```

The wrong dependency direction is a `turns/` prelude that only works by calling
`ptc_runner_mcp` server tools. MCP may expose configuration and role policy, but
core `ptc_runner` owns the retained-artifact API so non-MCP SubAgent and
Session callers get the same semantics.

Without the retained-artifact store, `log/` or a current-session facade can
still list metadata and bounded previews from turn events, but it cannot
honestly recover omitted spans. The content-recovery part of the API must not
ship until the core store exists.

## Model-Facing Slice 1: Inline Truncation Hints

The first user-visible change should happen exactly where the model already
looks: execution feedback for result, println, and memory previews.

When a visible value is truncated, append a short, stable hint:

```clojure
user=> {:count 3178, :rows [{:id 1, ...} ...]}
;; result truncated at 1200 chars
;; Select or print specific fields instead of refetching the source.
;; If the value is already bound, slice the bound value locally.
```

During Treatment A, do not mention any recovery call that is not shipped. If a
prior-turn artifact was compacted and no retained-artifact store exists, say so
plainly:

```clojure
user=> {:count 3178, :rows [{:id 1, ...} ...]}
;; result truncated at 1200 chars
;; Full prior-turn content is not recoverable in this run.
;; If you need more detail next time, bind the value and print/select specific fields.
```

Only after a recoverable retained-artifact ref exists should the renderer
include the exact suggested form inline. The model should not need to know the
namespace, current turn number, session id, or retry semantics:

```clojure
user=> {:count 3178, :rows [{:id 1, ...} ...]}
;; result truncated at 1200 of 18420 bytes
;; Inspect next retained span:
;; (log/artifact-page "turn:12:result" {:offset 1200 :limit 1200})
```

This still allows a callable recovery surface later, but the discovery burden
stays near zero: the renderer gives a concrete form only when it is relevant.
No turn-number arithmetic, no "find your session id first", and no extra
always-visible namespace.

## Model-Facing Slice 2: Better Defaults

Before adding any ref surface, improve the existing bounded preview. The model
should learn whether it needs a drill-down from the default view.

Example default rendering for a truncated eval result:

```clojure
{:ok true
 :value_preview "{:count 3178, :missing_end_station_id 248, ..."
 :preview {:bytes 18420
           :shown [0 1200]
           :truncated true
           :hint "Use def/let to bind large values, then select fields or slice the bound value before refetching."}}
```

If Treatment B later ships retained-artifact recovery, the same shape may add a
concrete next form:

```clojure
{:ok true
 :value_preview "{:count 3178, :missing_end_station_id 248, ..."
 :preview {:bytes 18420
           :shown [0 1200]
           :truncated true
           :hint "Retained content is available for this truncated value."
           :next "(log/artifact-page \"turn:12:result\" {:offset 1200 :limit 1200})"}}
```

For small friction cases, this may be enough:

```clojure
;; If the value is already in this eval, bind it once and slice locally.
(let [rows (tool/call {:server "files" :tool "read_page" :args {:offset 0}})]
  {:head (take 3 (get rows "lines"))
   :tail_hint "call the paginated source with the next offset if needed"})
```

Treatment A below must test whether preview metadata and bind/slice hints close
the repeated-read gap before new primitives are added.

## Model-Facing Candidate: Current-Session Facade

If inline hints plus `log/` introspection are still not discoverable enough, the
smallest next surface is a current-session facade over the same backing tools.
This may be a few new `log/` helpers, or a separate `turns/*` namespace if
measured discovery evidence justifies it.

The useful behavior is access to the current session's own retained turn
artifacts. It distinguishes two operations that currently blur together:

- re-reading evidence asks the source system again;
- inspecting a prior turn asks the session log what already happened.

Example from the model's perspective if such a facade is eventually justified:

```clojure
;; See recent turns and which artifacts are recoverable.
(turns/list {:limit 5})
;; => [{:turn 12
;;      :program_preview "(let [events ...])"
;;      :result_preview "{:count 3178, :missing_end_station_id 248, ...}"
;;      :artifacts [{:kind :result :ref "turn:12:result"
;;                   :bytes 18420 :shown [0 1200] :truncated true}]}]

;; Recover one bounded span of a compacted result.
(turns/page "turn:12:result" {:offset 1200 :limit 800})
;; => {:ref "turn:12:result"
;;     :range [1200 2000]
;;     :bytes 18420
;;     :text "...bounded span..."
;;     :truncated_before true
;;     :truncated_after true}
```

These names are illustrative, not a namespace decision. An implementation
should first try equivalent `log/` helpers or a thin current-session wrapper
over `TraceLog.Introspection`. If later evidence and turn refs share the exact
same retention, permission, provenance, and failure shape, then a shared
`content/*` facade can be considered.

## Prelude-Level Presentation

Once stable primitives exist, the model-editable layer can provide ordinary
prelude helpers over them:

```clojure
(view/brief "turn:12:result")
(view/first-tail "turn:12:prints")
(view/around "turn:12:result" "missing_end_station_id")
(view/coverage-report ["turn:12:result" "turn:14:result"])
```

These helpers are navigation strategies, not trusted rendering. A defective
helper can claim coverage, but the runner can compare that claim against the
actual spans paged or searched.

Automatic turn summaries should remain brief and runner-owned by default. A
small named-mode override may be useful, but arbitrary prelude-rendered
automatic summaries would be easy to make noisy or misleading. Richer turn data
stays explicit through `log/` or the measured current-session facade.

## Future Extension: Presentation Over Trusted Metadata

It may be useful later to let a prelude influence how turn status and
truncation guidance are presented to the model. That should be presentation
only, not authority.

The runner should still own and emit the authoritative metadata:

```clojure
{:turn {:current 3 :max 5 :remaining 2}
 :truncation [{:field :result
               :shown [0 1200]
               :bytes 18420
               :ref "turn:12:result"}]}
```

A host-shipped or derived prelude could then provide optional helpers such as:

```clojure
(view/turn-status renderer/metadata)
(view/truncation-help renderer/metadata)
```

But the prelude must not be able to suppress, falsify, or replace the
runner-owned fields in traces or default feedback. Turn budget text,
truncation metadata, exact artifact refs, retry warnings, and provenance remain
infrastructure. Prelude presentation can make them easier to read; it cannot
be the source of truth.

This is a later extension after inline truncation hints are measured. It should
not be part of Treatment A.

## Replay Stability

Default rendering is replay surface. Treatment A changes text that models see,
so it must not land as an invisible renderer drift.

Treatment A must ship either:

- behind an explicit boot/profile flag, or
- with a prompt/rendering pin bump and a replay-classification note that says
  which historical diffs are expected.

Once shipped in an accepted run, these surfaces become byte-stable replay
contracts:

- truncation hint strings;
- preview metadata keys and value shapes;
- any retained-artifact page envelope;
- stable errors such as `:content_evicted`;
- exact suggested call-form formatting.

Future changes to those strings or shapes need the same explicit gate. Small
presentation edits are not harmless: they enter the replay corpus as soon as a
gated run uses them.

## Provenance Requirements

Every explicit drill-down must add a turn-log entry that records:

- the ref dereferenced;
- operation type: metadata, page, search, sections, or coverage;
- byte/character ranges returned;
- search query and hit ranges, when applicable;
- whether the content came from a fresh source read or from retained session
  state;
- whether the result was complete, truncated, or unavailable.

Search hits are knowledge without full reading. The provenance model must not
pretend that a search hit gives coverage over the entire artifact.

Coverage claims must be checkable against actually returned spans. This is what
makes prelude navigation helpers testable in the prelude-derivation loop.

## Authority Requirements

Refs are capability-bearing values. A ref string can flow into tool args, child
SubAgents, logs, and later turns, so dereference must fail closed unless the
current evaluator has the right grants.

The first slice should use a two-grant rule:

1. a turn-log-read grant allows inspection of retained turn records;
2. the recovered artifact must also be allowed by the policy that governs the
   original content class, or by an explicit host decision that retained
   self-session artifacts are readable through the turn-log grant alone.

That second choice must be explicit per artifact kind. For example, recovering
the current session's printed output may be acceptable under `turn_log: read`,
while recovering a private upstream tool result may require both `turn_log:
read` and the relevant upstream/evidence grant.

Child SubAgents must not automatically inherit parent-turn visibility. If a
child can read parent turns, that must be a declared grant boundary with
turn-log-visible provenance. Value-position isolation lessons from Capability
Prelude V1 apply directly: possessing a string that looks like a ref is not
enough.

## Retention Requirements

The runner must not promise dereference unless it has a bounded retention story.

The first slice needs explicit host-configured caps:

- maximum retained bytes per session;
- maximum retained bytes per artifact;
- maximum retained artifact count;
- TTL or oldest-first eviction policy;
- whether evidence payloads, tool results, prints, and summaries share a pool
  or have separate pools.

Retention must respect content-class policy at write time, not only at
dereference time. If an evidence source, upstream result, or host policy redacts
or bounds a payload before it reaches the model-facing envelope, the retained
artifact store must not secretly keep the omitted full payload. A later
`turn_log: read` grant must not become a retroactive window into content the
original policy deliberately bounded.

Evicted refs must fail closed with a stable value, not silently degrade into a
new source read or an empty page:

```clojure
(turns/page "turn:12:result" {:offset 0 :limit 1000})
;; => {:ok false
;;     :reason :content_evicted
;;     :ref "turn:12:result"
;;     :message "retained content for turn:12:result is no longer available"}
```

Retention is the main cost of the feature. Without this section implemented,
the current-session facade is only a preview/introspection API, not a content
recovery API.

## Treatment Ladder

This should graduate through measured cells, not land as a broad abstraction.

Current prior: known Stage 3 forensics point at within-turn duplicate reads
caused by hint-taught re-read behavior, print-cap paging, and escaped-preview
rendering. They do not yet show bound-but-lost cross-turn recovery as the
motivating mechanism. Treat that as a falsifiable prior: mine sealed demo-2 and
demo-3 traces before building Treatment B.

1. **Classify repeated reads.** Mine M1-style traces before implementation.
   Separate never-bound within-turn duplicate reads from bound-but-lost
   cross-turn recovery. These imply different fixes.
2. **Treatment A: inline truncation hints.** Add preview metadata, shown
   ranges, omitted-byte counts, stable next-action hints, and bind/slice
   guidance directly beside truncated feedback. Do not advertise unshipped
   recovery calls. If retained-artifact recovery exists in a later cell, include
   the exact call form; otherwise include only local select/slice guidance or an
   honest "not recoverable in this run" message. This is the gate for all later
   work.
3. **Treatment B: current-session facade.** Extend `log/` or add a narrow
   wrapper for current-session prior-turn listing, metadata, bounded page, and
   search over retained artifacts, with retention caps and two-grant checks.
4. **Treatment C: model-editable view helpers.** Add prelude helpers over
   the current-session facade, with coverage reporting compared against logged
   spans.
5. **Treatment D: generalize only on evidence.** Introduce a shared
   `content/*` facade only if at least two concrete ref kinds demonstrate the
   same retention, grant, provenance, and failure semantics.

Treatment B/C should not run if Treatment A closes the motivating gap. A richer
primitive that increases discovery cost without improving provenance or
correctness should be demoted rather than promoted.

## Development Plan

Develop this on experiment branches, not directly on `main`.

Recommended branch sequence:

1. `exp/truncation-hints-a` - Treatment A only.
2. `exp/retained-artifacts-b` - retained-artifact recovery, only if A fails its
   gate.
3. `exp/view-helpers-c` - presentation helpers, only after B has a stable
   primitive shape.

Treatment A should be independently mergeable or discardable. It must not carry
hidden retained-artifact work.

### Treatment A Solution Outline

Goal: improve the renderer's teaching signal with no new namespace and no
unshipped recovery calls.

Implementation shape:

- Add an opt-in rendering flag/profile for truncation hints. Keep the default
  byte-identical until the experiment is selected.
- Thread the flag through the existing SubAgent/Session/MCP rendering paths
  that produce model-visible result, println, and memory previews.
- Treat the shipped MCP session hint path as existing behavior, not a blank
  slate. `PtcRunnerMCP.Sessions.Projection.append_value_hints/4` already
  composes the default `(describe *1)` truncation hint, the opt-in
  `--collection-hint` path, and history-cap suppression.
- For MCP session output, Treatment A must either preserve those hints exactly
  when the new flag is off, or deliberately replace them behind the new flag
  with one composed hint policy. It must not append a second independent hint
  layer that duplicates or contradicts `append_value_hints/4`.
- Extend the truncation metadata available to the renderer: field kind
  (`result`, `println`, `memory`), shown range or shown char count, and whether
  total bytes are known.
- When a visible field is truncated, append a short stable hint that teaches:
  bind with `def`/`let`, select specific fields, slice the bound value, and do
  not refetch unless fresh data is required.
- If the truncated value is known to be a prior-turn compacted artifact and no
  retained-artifact store is enabled, render the honest "not recoverable in
  this run" hint.
- Do not mention `log/artifact-page`, `turns/page`, or any recovery call in
  Treatment A.
- Record enough structured metadata in turn logs to measure hint exposure and
  hint compliance without parsing free text where possible.

Focused tests:

- flag off: existing renderer output is byte-identical;
- flag off: existing `lisp_session_eval` truncation feedback still includes the
  shipped `(describe *1)` hint exactly as before;
- flag on: truncated result feedback includes the new hint;
- flag on: non-truncated feedback does not include the hint;
- flag on: println and memory truncation use the correct field wording;
- flag on: MCP session hint composition covers the existing collection hint,
  history-cap suppression, and result-truncation hint cases without duplicate
  or conflicting advice;
- Treatment A output never suggests unshipped recovery calls;
- replay classification covers expected renderer diffs when the flag is on.

### Treatment A Experiment

Before model E2E, mine sealed traces and classify repeated reads:

- never bound within the same turn;
- bound but lost across turns;
- print-cap paging;
- escaped-preview rendering;
- genuine fresh-data refetch.

The current prior is that known repeated reads are within-turn/hint-driven, not
cross-turn recovery. Record the mined counts before running new treatments.

Run baseline vs Treatment A on the same task set and compare:

- repeated source reads;
- hint compliance;
- assistant turns;
- tool calls;
- correctness;
- discovery/catalog churn;
- replay diff class.

Treatment A passes only if it reduces repeated reads or improves correctness
without increasing discovery churn enough to offset the gain.

### Direct SubAgent Model E2E

Run the first model E2E without MCP. The direct `PtcRunner.SubAgent.run/2` path
isolates the renderer and hint behavior from MCP role/session plumbing, which
is noise for Treatment A.

Use the repo's existing `deepseek` model alias rather than a raw provider model
id. That keeps the experiment aligned with `PtcRunner.LLM.DefaultRegistry` and
local `.env` overrides.

E2E shape:

- same task set, same tools, same model alias;
- baseline renderer/profile off;
- Treatment A renderer/profile on;
- turn logging enabled for both cells;
- no retained-artifact recovery and no MCP server.

Use tasks that exercise the failure mode:

- a tool returns a large value whose visible result is truncated;
- the answer depends on a tail or middle fact;
- refetching the same source is possible but wasteful;
- the desired behavior is to bind, select, slice, or print specific fields.

Measure from turn logs:

- repeated tool calls by `args_hash`;
- hint exposure;
- hint compliance;
- turns and tool calls;
- correctness;
- attempts to call unshipped recovery helpers.

Only after this direct SubAgent lane shows value should an MCP parity lane run.
MCP should verify transport/config parity, not decide whether Treatment A is
useful.

### Treatment B Solution Outline

Build this only if Treatment A fails to close the motivating gap and trace
classification shows bound-but-lost cross-turn recovery.

Implementation shape:

- Add a core retained-artifact store separate from the audit turn log.
- Store only payloads allowed by write-time content-class policy.
- Reuse `TraceLog.Introspection` concepts: host-side ownership, bounded
  retention, owner lifecycle, stable page envelope, and fail-closed errors.
- Add runner-owned primitives for metadata, bounded page, and search over
  retained artifacts.
- Extend `log/` first, or add a tiny current-session facade over the same
  backing tools only if discovery evidence requires it.
- Log every dereference as provenance: ref, operation, range, search query/hits,
  complete/truncated/unavailable status, and fresh-read vs retained-state
  source.
- Gate dereference with the two-grant rule and explicit parent/child visibility
  policy.
- Render exact recovery forms inline only when the store and grant path are
  active.

Focused tests:

- retention caps and eviction are deterministic;
- evicted refs return stable `:content_evicted`;
- write-time redaction prevents storing disallowed full payloads;
- dereference fails closed without required grants;
- current-session and cross-session access obey parent/child policy;
- page/search provenance appears in the turn log;
- `log/` reuse avoids a parallel turn-log implementation.

### Merge Gates

For any branch:

- `mix precommit` passes;
- replay diffs are classified;
- flag-off behavior is byte-identical for existing surfaces;
- docs and examples describe only shipped behavior;
- experiment notes record task set, flag/profile, metrics, and outcome.

Do not merge Treatment B or C just because the implementation works. They need
positive evidence against the pre-registered Treatment A gate.

### Autonomous Implementation Runbook

Treatment A is suitable for an autonomous Codex goal if the goal is scoped to
renderer hints, tests, and the direct SubAgent E2E harness. It should not try to
implement retained-artifact recovery, `turns/*`, or `content/*`.

Recommended goal:

```text
Implement Treatment A from docs/plans/future/model-visible-content-surfaces.md:
opt-in inline truncation hints for model-visible renderer output, preserving
flag-off byte stability and existing MCP session hint behavior, plus focused
tests and a direct non-MCP SubAgent E2E experiment harness using the `deepseek`
model alias.
```

Autonomy rules for the run:

- create or use an experiment branch named `exp/truncation-hints-a`;
- read `AGENTS.md`, this plan, the adjacent paginated-read plan, and the
  archived turn-log/prelude derivation plan before editing;
- inspect the existing renderer paths before claiming a missing feature:
  SubAgent feedback, Session feedback, MCP session projection, trace-log
  recording, and model registry;
- keep Treatment A behind an explicit flag/profile so default output remains
  byte-identical;
- preserve the shipped MCP `lisp_session_eval` behavior when the flag is off,
  including `(describe *1)`, `--collection-hint`, and history-cap suppression;
- when the flag is on, compose one hint policy rather than layering duplicate
  hints;
- add no new model-facing namespace;
- add no retained-artifact store;
- do not mention `log/artifact-page`, `turns/page`, or unshipped recovery calls
  in Treatment A output;
- update docs only for behavior that is implemented in the branch;
- run focused tests as they are added;
- after each meaningful work item, run an independent Codex review over the
  changed branch and fix every actionable finding before continuing to the next
  work item;
- after all implementation and review issues are clean, run `mix precommit`;
- if `OPENROUTER_API_KEY` is present, run the direct non-MCP E2E harness with
  the `deepseek` alias; if it is absent, leave the harness and report the
  skipped live-model check explicitly;
- stop after Treatment A evidence is recorded. Do not continue into Treatment B
  unless a separate goal is created after reviewing the A results.

Suggested autonomous prompt:

```text
You are working in /Users/andreasronge/projects/ptc_runner.

Goal: implement Treatment A from
docs/plans/future/model-visible-content-surfaces.md. Stay strictly within
Treatment A: opt-in inline truncation hints, preservation of existing default
renderer behavior, focused tests, and a direct non-MCP SubAgent E2E experiment
harness using the existing `deepseek` model alias.

Before editing, read AGENTS.md and the relevant plan sections. Verify existing
code paths instead of assuming they are missing. In particular, inspect
SubAgent/Session model-visible feedback, MCP session projection
(`PtcRunnerMCP.Sessions.Projection.append_value_hints/4`), trace-log recording,
and `PtcRunner.LLM.DefaultRegistry`.

Implementation constraints:
- keep default/flag-off output byte-identical;
- preserve existing MCP session hints when flag off, including `(describe *1)`,
  `--collection-hint`, and history-cap suppression;
- when flag on, compose a single non-conflicting hint policy;
- no new `turns/*` or `content/*` namespace;
- no retained-artifact store;
- no unshipped recovery calls in model-visible hints;
- use existing repo patterns and delete/refactor rather than add compatibility
  shims where a cleanup is necessary.

Verification:
- add focused tests for flag-off byte stability, flag-on result/println/memory
  hints, MCP hint composition, and absence of unshipped recovery calls;
- add or document a direct SubAgent E2E harness that can compare baseline vs
  Treatment A with turn logging enabled and model alias `deepseek`;
- run focused tests while developing;
- after each meaningful work item, run an independent Codex review and fix all
  actionable findings until the review is clean before continuing;
- run `mix precommit` before final, after the review loop is clean;
- run the live DeepSeek E2E only if OPENROUTER_API_KEY is available, otherwise
  report it as skipped.

Stop conditions:
- stop and report if implementing Treatment A requires retained-artifact
  recovery or a new namespace;
- stop after Treatment A implementation, tests, and experiment notes. Do not
  implement Treatment B/C/D in this run.
```

## Metrics

Measure:

- repeated source reads;
- assistant turns;
- tool calls;
- missed tail/middle facts;
- byte-span coverage;
- search-vs-read provenance;
- invalid ref/dereference attempts;
- evicted-ref handling;
- hint compliance: whether the model follows the suggested next action;
- whether coverage reports match actual paged spans;
- whether new namespaces increase discovery churn.

The success claim should be narrow: fewer duplicate source reads and better
auditability on tasks where prior-turn recovery matters, without hurting tasks
that only need ordinary paginated tools or local binding.

## Non-Goals

- No broad `content/*` namespace in the first slice.
- No parallel turn-log implementation beside `TraceLog.Introspection`.
- No refs for ordinary in-program values.
- No retained large-source abstraction that bypasses paginated tools.
- No automatic prelude-rendered summaries replacing runner-owned defaults.
- No dereference without retention caps and grant checks.
