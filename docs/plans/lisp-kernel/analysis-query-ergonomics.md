# Plan: make the trace analyzer answerable by an agent

**Status:** all five items implemented 2026-08-02 on branch
`worktree-incident-evidence-compiler`. Written and revised the same day after
review; the body below is the proposal as reviewed, kept for the reasoning.

| Item | Commit |
| --- | --- |
| 1 — self-describing rejections | `64f86c57` |
| 3 — annotation `evaluation_id` + `annotation_type` filter | `d15d4c96` |
| 2 — `failure_kind` filter + counter breakdown | `c224d9ac` |
| 4 — `fields` projection | `7471890f` |
| 5 — `long` | `572cdbdf` |

Decisions the plan left open, settled during implementation and written into
[`../../trace-log-contract.md`](../../trace-log-contract.md) rather than left
in this disposable document:

- **Item 2's filter semantics.** `failure_kind` matches as an opaque bounded
  string with no vocabulary validation, because a declared vocabulary lives in
  the frozen bundle of the run that *produced* the trace, not in the trace.
  The plan's "only a named kind is filterable" is withdrawn — it asserted a
  property with no mechanism behind it.
- **Item 2's counter rule.** Fingerprinted failures get their own counter
  rather than a synthetic key inside `failure_kinds`, and the reconciliation
  is the inequality `sum(failure_kinds) + failure_kind_fingerprinted <=
  errors`, because other failure classes carry no taxonomy.
- **Item 4's pagination trade-off.** Projection applies after byte-fit, so a
  narrow projection never changes which runs land on a page, at the cost of
  not fitting more of them.
- **Item 5.** The plan expected "document it as absent" to be the likely
  answer. `int` enforcing the signed 32-bit range is what argued the other
  way: the natural `(int (* 100 ratio))` works in development and fails past
  2^31 with nothing to reach for. Divergence recorded as DIV-54.

Verified end to end against `openrouter:deepseek/deepseek-v3.2` rather than
fixtures alone. One composite query now answers what previously could not be
asked at all:

```clojure
(log/runs {"failure_kind" "unresolved-citations"
           "fields" ["status" "failure_kind" "llm_calls"]})
(log/turns run-id {"annotation_type" "citations-verified" "limit" 20})
;=> {"checked" 12 "mismatched" 3 "unresolved" 0}
```

25% of that run's citations were ungrounded — and `mismatched 3, unresolved 0`
says the model cited real records with hallucinated digests, which is a
different failure from inventing records and is only visible because the two
counters are separate.

Review corrected four things and they are folded in above: the annotation
`evaluation_id` must be added before the payload is size-checked, not after;
`validate_keys/2` has four call sites, not three, and the one this plan most
needs — `list_runs` — was the missing one; there is no existing identifier rule
for query keys to inherit, so item 1 must define one; and item 2's "only a
named kind is filterable" was a sentence with no mechanism behind it.

Every item below was hit while driving `log-analysis-v2` against real traces
from a live model in one session, not derived from reading the source. The
motivating claim is narrow: a human at a REPL can shrug off an opaque rejection
and go read `trace_log.ex`; an agent cannot, and burns a turn each time. If the
analyzer is to be the default way an agent inspects a run, the rejection path
matters as much as the happy path.

Read [the trace-analysis handoff](analysis-tooling-handoff.md) for what the
tooling already does and [`../../trace-log-contract.md`](../../trace-log-contract.md)
for the normative event and paging contract.

## What was hit, in the order it cost time

| # | Gap | Cost |
| --- | --- | --- |
| 1 | Rejections are one opaque atom | a wasted turn per mistake, no way to learn the contract |
| 2 | No `failure_kind` filter | fetch every run, fold client-side |
| 3 | No annotation filter, and annotations are not turn-scoped | fetch turns per run, filter in Lisp |
| 4 | Run summaries carry ~30 fields with no projection | tokens spent on prelude graphs to answer "which runs failed" |
| 5 | `long` is unbound | a percentage needs a workaround |

Items 1–3 are the ones that decide whether an agent can drive this unaided.
Item 4 is a cost problem, item 5 is a papercut.

## 1. Rejections must name what was wrong

**Observed.** `(log/turns "run-id" {"limit" 200})` returns
`{:details "invalid trace query" :kind :provider_error :reason :invalid_request}`.
Nothing says the bound is 100, and nothing says which argument failed. I found
`@max_limit 100` (`trace_log.ex:43`) by reading the source.

**Why it is cheap.** The information already exists at the rejection site and
is thrown away. `validate_keys/2` (`trace_log.ex:2286`) is handed the exact
allowed list at four call sites and collapses the failure to a bare
`{:error, :invalid_query}`:

| Operation | Line | Allowed keys |
| --- | --- | --- |
| `list_runs` | 583 | `limit cursor status run_id trace_id tags name model provider from to` |
| `get_run` | 604 | `run_id` |
| `list_turns` | 627 | `run_id limit cursor status evaluation_id capability` |
| `counters` | 647 | `status run_id trace_id tags name model provider from to` |

`page_options/3` knows the limit bound and does the same. Ten-plus sites return
the same atom and `TraceCapability.normalize_query_result/1` maps all of them to
one string.

**Change.** Carry a bounded reason with the error:

- `{:error, {:invalid_query, %{unknown_keys: [...], accepted_keys: [...]}}}`
  from `validate_keys/2`.
- `{:error, {:invalid_query, %{argument: "limit", bound: 1..100}}}` from
  `page_options/3`.
- `TraceCapability` renders it into `details` alongside the existing message.
  This needs an **exact clause placed before the existing catch-all**
  (`trace_capability.ex:125`), or a structured error falls through to
  `provider_error(:internal, "trace source unavailable")` and the change makes
  diagnosis worse, not better. The `TraceLog` result specs must also stop
  declaring error reasons as atoms.

**Bounds.** Echoing an unknown key means putting caller-authored content into
an error string, and **no identifier rule exists today to lean on** —
`validate_keys/2` checks only `JSONValue.map?/1` and allowlist membership. So
the rule has to be defined here rather than inherited: echo a key only if it is
a string matching a bounded identifier pattern, cap the number echoed, and send
anything else (non-string keys, over-long keys, a non-map `arguments`) down the
existing generic fail-closed path reporting a count alone.

The invariant at risk is **bounded fail-closed rendering, not payload-free
canonical events** — a provider rejection is not a canonical event and never
reaches a trace. That distinction matters because it sets how strict the rule
must be: strict enough that an error string cannot carry unbounded caller text
into a log, not as strict as the trace vocabulary.

**Test.** A rejected query names the offending key and lists the accepted set;
a rejected limit names the bound; a non-string, over-long, or oversized key set
reports a count and echoes nothing; a structured error does not fall through to
the internal-error clause.

## 2. Filter runs by failure kind

**Observed.** After `d963ffc1` put `failure_kind` in `run-stopped` and the run
summary, grouping four runs by kind still meant `all-runs` then a fold. At four
runs that is fine; the tooling exists for corpora.

**Change.** Accept `failure_kind` in the `list_runs` (line 583) and `counters`
(line 647) allowlists and match it in `filter_runs/2`, beside the existing
`status`. Add a `failure_kinds` breakdown to `counters/1`, which today returns
a fixed set (`events`, `runs`, `errors`, `evaluations`, and the two
capability-call counts) and no failure information at all.

**Bounds — needs deciding before implementation.** "Only a named kind is
filterable" is a sentence, not a rule: accepting any bounded string does not
enforce it, and the query layer has no access to a run's declared vocabulary
anyway (the declaration lives in the frozen bundle of the run that *produced*
the trace, not in the trace). Two workable options:

1. Match `failure_kind` as an opaque string against whatever the `run-stopped`
   event recorded. Simple, no vocabulary needed; an unknown kind returns an
   empty page like any other non-matching filter.
2. Validate against `SafeMetadata`'s framework list only, and reject anything
   else. Rejects typos, but also rejects every legitimate application kind.

Option 1 is the honest one — the trace is the authority for what it contains —
and the sentence should be dropped rather than defended.

**Counter semantics — also undecided.** A `failure_kinds` breakdown must state
whether it omits successful and still-open runs, whether fingerprinted failures
appear under a single bucket or not at all, and whether the buckets are
required to sum to the failed-run count. Pick one and write it into
[`../../trace-log-contract.md`](../../trace-log-contract.md); a counter whose
total does not reconcile is worse than no counter.

## 3. Make annotations queryable and turn-scoped

**Observed.** Joining verification counts to runs required, per run, an
`all-turns` page fetch and a Lisp `filter` on
`(get-in e ["data" "annotation_type"])`. Two separate gaps:

- `list_turns` has no `annotation_type` filter.
- Annotations carry no `evaluation_id`. `runtime_tools.ex` builds
  `%{annotation_type: type, data: data, provenance: :workflow}` and nothing
  adds one. `d478cf38` threaded `evaluation_id` onto capability events for
  exactly this reason and did not cover annotations, so
  `(log/turns id {"evaluation_id" e})` returns the turn's capability calls but
  not the annotation emitted inside it.

**Change.** Thread `evaluation_id` into the annotation payload the same way
`d478cf38` threads it into capability events — from the innermost open
evaluation, not inferred from `sequence` order, for the same reason recorded
there. Add `annotation_type` to the `list_turns` allowlist (line 627) and to
`turn_matches?/2`.

**The field must go into `payload` before it is measured.** `annotate/4`
(`runtime_tools.ex:286`) builds `payload`, sizes it with
`RetainedSize.bytes_with_cap(payload, limit)`, and only emits if the result is
within `event_payload_bytes`. Adding `evaluation_id` anywhere after that
measurement — for instance inside `Events.emit/4` — emits a payload larger than
the one that passed the check, silently breaking the bound. Add it to the map
at construction, so the existing check covers it.

**Sequencing.** These are independent and the `evaluation_id` half is the more
valuable: without it, no annotation can be attributed to a turn at all. Do that
first even if the filter waits.

**Cost.** Existing traces do not gain the field, the same cost `d478cf38`
accepted.

## 4. Project run summaries

**Observed.** `log/runs` returns roughly thirty fields per run, including
`workflow_prelude`/`mission_prelude` dependency graphs and
`connector_snapshots`. Answering "which runs failed and why" pays for all of
it, on every page, inside an agent's context budget.

**Change.** Accept an optional `fields` argument on `list_runs` (allowlist at
line 583) — a bounded list drawn from the projection's own key set — and return
only those keys plus `run_id`. Reject an unknown field name through the
mechanism in item 1, so the error names the available fields.

**Alternative considered.** A fixed "summary" projection alongside the full
one. Rejected: it needs a second contract to version and every caller wants a
different subset. Field selection reuses the key set that already exists.

**Specification needed before implementation:**

- The selectable set must be a named constant, not `Map.keys/1` of a sample
  projection, or the accepted set drifts silently as `run_metadata/3` changes.
- State the list rules: element type, maximum length, and whether duplicates
  are rejected or collapsed.
- State where the projection applies relative to pagination. It must be after
  page selection, or a `fields` list changes which runs land on a page.
- **Cursor stability.** `fields` participates in the `query_id` digest
  automatically, since `page_options/3` digests
  `Map.drop(arguments, ["cursor", "limit"])` — so a cursor cannot leak across
  projections. But the digest is over the raw list, so `["status", "run_id"]`
  and `["run_id", "status"]` produce different `query_id`s for the same
  projection and a cursor from one is rejected by the other. Canonicalize
  (sort and dedupe) before digesting.

## 5. `long` is unbound

**Observed.** `(long (* 100 (/ x y)))` fails with
`Undefined variable: long` in an analysis session.

**Change.** Decide deliberately, do not add a Clojure name reflexively. The
question is whether the analysis profile should carry numeric coercion at all
or whether `quot`/`int` already covers it. See
[`../../clojure-conformance-gaps.md`](../../clojure-conformance-gaps.md) for
how divergences from Clojure are recorded; if `long` is intentionally absent,
that is where it belongs, not here.

## Sequencing

1. **Item 1** first. It is self-contained, it is the one an agent hits first,
   and it makes every later item's error path legible for free.
2. **Item 3's `evaluation_id`** next — it is the only item that changes what a
   trace records, so it wants the longest soak before anything depends on it.
3. **Items 2 and 3's filters** together; they touch the same two functions
   (`validate_keys/2` allowlists and `turn_matches?/2`) and splitting them
   means editing both twice.
4. **Item 4** last of the substantive work; it is the largest contract change
   and the only one with an open question.
5. **Item 5** whenever, or never, on the evidence of the decision above.

## What this plan does not address

Recorded so they are not mistaken for oversights:

- **Nothing verifies a declared vocabulary against the code that emits it.**
  A new `(fail (result/error :new-kind ...))` silently fingerprints. Tracked
  in [`agent-developer-findings.md`](agent-developer-findings.md) under
  findings 7 and 8.
- **`failure_taxonomy` runs at one call site**, so mission and subordinate
  failures still fingerprint regardless of item 2.
- **Finding 9, in-loop verification**, is untouched and remains the largest
  open item on this branch.
