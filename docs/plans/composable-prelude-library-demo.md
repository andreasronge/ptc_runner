# Composable Prelude Library Demo — Overview Plan

## Status

Proposed next experiment after the MCP-native editing-mechanism run in the
external `../../ptc-bench-comparison` repo.

The completed 2026-07-03 run proved the plumbing claim: separate MCP-only model
processes, human-gated at every stage, completed analyst -> proposer ->
reviewer -> editor -> validator and ended in a real `PreludeStore` write that
fresh validation attached and exercised. Its convergence result was useful but
partial: the loop independently derived delta-only authoring,
substrate-side source mutation, and checksum verification, but did not derive
the sealed form-keyed `prelude/edit` design, read-side form introspection, or
staleness guard. One position-blind retry changed a string literal while
fixing a compile error, which is itself evidence for form-aware editing.

This plan uses the now-implemented `prelude/edit`, `prelude/form`, and declared
prelude dependencies to test the next North Star claim: preludes should behave
like composable capability libraries, not monolithic prompt bundles.

Minimum implementation pin for the external run is `5055deac`, which adds
read-only prelude introspection and session-mode `catalog_ops`. Later pins are
fine, but the run must verify both capabilities through MCP before model
stages.

## Objective

Demonstrate and measure a split-prelude workflow:

- `paged_base`: pagination, bounded folding, sampling, profiling, and generic
  table/data helpers.
- `paged_audit`: audit workflow helpers and guidance that depend on
  `paged_base` through `requires_preludes`.

Then run the self-improvement loop over evidence and ask whether it proposes a
change to the correct layer: base/library vs. audit/workflow.

The value claim is not merely that two preludes can attach. That is already
covered by declared dependencies. The value claim is that a model can inspect a
layered capability surface, understand which layer owns a missing or costly
behavior, and author a change through the typed prelude surface without
copy-paste growth.

## Preconditions

1. Pin the current `ptc_runner` commit at run design time and record it in the
   external run directory. Do not upgrade mid-run.
2. Rerun Stage 0 preflight at that pin:
   - HTTP MCP server starts with sessions and prelude writes enabled.
   - one process writes a throwaway prelude;
   - a fresh process attaches and calls it;
   - a declared-dependency smoke writes `base@1`, writes `audit@1` with
     `requires_preludes`, then fresh-attaches `audit` only and observes the
     transitive base pin.
3. Confirm lifecycle evidence is preserved:
   - per-boot server logs or append-only logs;
   - boot ledger with pid, commit, seed checksum, and turn-log path;
   - per-stage turn-log snapshots;
   - inter-stage store fingerprints.
4. Confirm session-mode `catalog_ops` appears in MCP turn logs. Discovery-cost
   measurement must use the structural ledger, not inference from program text.
5. Confirm read-only MCP sessions with a configured prelude store and no
   separate runtime prelude expose `prelude/form`, `prelude/forms`,
   `prelude/form-deps`, and related read introspection without exposing
   `prelude/write`, `prelude/edit`, or `prelude/set-default`.

## Experiment Shape

### Stage 0 — Preflight

Fresh server/store at the pinned commit. Validate independent write/attach,
declared prelude dependencies, `prelude/edit`, `prelude/form`, and
`prelude/forms` through MCP.

Also validate stale-parent behavior through MCP. At `5055deac`, `prelude/write`
honors `parent_checksum`/`parent_version` and fails stale writes closed, while
`prelude/edit` edits the current candidate and does not expose caller-supplied
expected-base fields.

### Stage 1 — Split Prelude Setup

Human-seed the split prelude pair for this run:

- `paged_base@1` contains reusable data access and bounded aggregation.
- `paged_audit@1` declares `requires_preludes ["paged_base"]` and contains
  only workflow-level helpers/cues.

Keep public surfaces intentionally small. The M2 observability prelude result
showed that broad helper surfaces can cost more in discovery than they save.
Record the public-export budget and the reason each export is public.

### Stage 2 — Analyst Evidence

Fresh MCP-only process reads prior run evidence through an evidence upstream.
The evidence should include:

- the completed editing-mechanism run summary;
- Stage 4/5 turn metrics: 15 evals before first write, one retry, one
  position-blind string-literal deviation;
- M2 discovery-cost evidence, especially helper-surface overhead and print-only
  / preview-driven waste;
- split-prelude export surfaces and form metadata via read-only prelude
  introspection.

Recommendation sections from prior notes should be redacted before serving
evidence to the proposer. The A/B table and observed findings are evidence; the
operator's "what to do next" bullets would steer the layer choice.

Hold the `prelude/edit` expected-base verifier finding out of proposer evidence
by default. Include it only if the pre-registered answer key explicitly treats
the missing expected-base contract as an acceptable
`ptc_runner`-engineering-request answer.

The analyst separates observed facts from proposed changes.

### Stage 3 — Proposer

Fresh read-only MCP-only process reads analyst evidence and inspects both
preludes.
The proposal must classify the target layer:

- base/library change;
- audit/workflow change;
- documentation/surface-trimming change;
- `ptc_runner` engineering request.

The proposal must explain why the change belongs in that layer and which
existing forms it reuses.

Before Stage 2 starts, pre-register the expected correct layer and rationale in
the run directory. The Stage 2 evidence bundle should support more than one
plausible layer so layer selection is not dictated by a single highlighted
finding.

### Stage 4 — Reviewer

Fresh MCP-only reviewer accepts, rejects, or requests revision. Review focus:

- correct layer;
- no copy-paste growth across preludes;
- no benchmark-specific leakage;
- evidence-backed claim about discovery cost or editing cost;
- feasibility under current `prelude/edit` and dependency semantics.
- stale-base risk.

### Stage 5 — Editor

Fresh MCP-only write-capable process uses `prelude/edit` rather than
full-source `prelude/write` or in-session string splicing.

Required measurements:

- evals before first edit/write attempt;
- compile retries;
- edit result checksum and base version;
- touched form names;
- whether `prelude/edit` prevented the prior position-blind retry class.

If the accepted edit changes `paged_base`, the run must also perform a gated
companion re-pin of `paged_audit`; otherwise `paged_audit@1` continues to
attach the old base checksum and validation can silently test unchanged code.

After any editor write, the orchestrator should compare the edit result's
`base_version` and `parent_checksum` with the prelude version/checksum the
editor last inspected. A mismatch is a stale-prepared-edit event and should
stop at the human gate, because current `prelude/edit` cannot pin an expected
base itself.

### Stage 6 — Validator

Fresh read-only process attaches the changed top-level prelude and validates:

- transitive dependency pins resolve;
- a base-layer change is visible through the top-level audit attach closure
  after the companion re-pin;
- changed behavior works;
- unchanged layer contracts still pass;
- public surface remains trimmed;
- store snapshot/fingerprint matches expected checksums.

## Form-Keyed Epilogue Measurement

Run one small replay against the same historical `reconcile-totals` insertion
used in the 2026-07-03 editing-mechanism run, but this time through
`prelude/edit`.

Compare directly against the prior baseline:

- prior recipe: 15 evals before first write;
- prior retry count: 1;
- prior deviation: position-blind qualifier stripping inside a string literal;
- prior drift: zero out-of-region drift after checksum-verified readback.

Expected value of `prelude/edit`:

- no whole-source or anchor-string authoring;
- touched forms explicit in the edit request/result;
- no source-wide qualifier replacement;
- parent/base checksum visible in the result.

Treat the one-shot replay as qualitative unless repeated 3-5 times. The
structurally guaranteed claims are no whole-source authoring, touched forms in
the edit request/result, and parent checksum visibility.

## Measurements

Primary:

- Correct-layer proposal: did the loop choose `paged_base`, `paged_audit`, docs,
  or a `ptc_runner` request for the right reason, scored against the
  pre-registered key?
- Editing structure: typed edit request, explicit touched forms, no
  whole-source or anchor-string authoring.
- Editing quality: retries and deviations vs. prior baseline of one compile
  retry plus one position-blind string-literal deviation.
- Surface economy: number of public exports and discovery turns before the
  first useful call.
- Validation: fresh attach of dependent prelude succeeds and behavior matches
  expected checks.

Secondary:

- `catalog_ops` count from MCP session turn logs;
- one-shot replay eval count vs. prior baseline of 15, treated as qualitative
  unless repeated 3-5 times;
- print-only / preview-driven turns;
- evidence-reading turns before first substantive analysis;
- whether reviewer detects stale-base or wrong-layer risk.

Staleness probe:

- write version N;
- bump the target prelude to N+1;
- submit a stale `prelude/write` with version N's parent-version/checksum;
- require fail-closed behavior through the stale-base guard.

Do not claim caller-prepared `prelude/edit` staleness unless `ptc_runner` first
adds an explicit expected-base contract to `prelude/edit`; that contract is not
present at `5055deac`.

Non-metrics:

- Bike-share benchmark score. This is a library-composability and editing
  mechanism demo, not a new audit-task performance claim.

## `ptc_runner` Follow-Ups This Demo Should Drive

1. **Audited upstream discovery.** Stage 2 showed that evidence-path discovery
   and boundary hygiene are coupled. Attempts that lacked first-party evidence
   listing pressure-tested the launcher and repeatedly reached host discovery
   surfaces before the accepted run used a neutral manifest workaround.
   `ptc_runner` should provide bounded, turn-log-visible upstream discovery:
   protocol-native resource listing where upstream MCP servers support it, and
   a conventional `list`/`glob` tool shape for file-like evidence lanes that do
   not.
2. **Session-selected capability namespaces.** Promote the future direction in
   `docs/plans/future/prelude-selected-capability-namespaces.md` from cleanup
   idea to a concrete design candidate. Per-session capability visibility would
   be declared in session start and auditable in turn logs, unlike process-level
   CLI allow/deny flags.
3. **Session-mode `catalog_ops`.** Confirm the structural measurement remains
   present in the actual MCP session path used by the demo.
4. **Evidence-reading / eval-preview tax.** The prior run lost multiple turn
   budgets to bounded previews and paged evidence reads. The next loop should
   either propose a prelude/workflow improvement or produce a concrete
   `ptc_runner` request such as result handles, artifact paging/search, or
   better preview controls with audit logging.
5. **Surface-trimming guidance.** If split preludes still increase discovery
   cost, the loop should propose moving value into fewer public exports,
   namespace docstrings, or better introspection summaries rather than adding
   more helpers.
6. **`sample` / `fold-pages` loop duplication.** `paged_base/sample` duplicates
   the page cursor loop used by `fold-pages`, and `paged_audit/reconcile-totals`
   depends on `sample`. Do not naively implement `sample` in terms of
   `fold-pages` unless `fold-pages` first gains early termination semantics;
   otherwise a bounded sample becomes a full scan. The conservative library fix
   is to extract the shared cursor/page loop into a private helper used by both
   public functions.

## Success Criteria

Minimum success:

- split preludes write and attach through declared dependencies;
- a fresh process can validate the dependent prelude;
- fresh read-only analysis/proposal/review stages can inspect stored prelude
  forms without write authority;
- the loop completes a gated MCP-only cycle and writes or edits the intended
  layer with `prelude/edit`.

Strong success:

- the loop proposes the correct layer without human steering;
- `prelude/edit` shows the structural improvements expected over the
  2026-07-03 recipe baseline;
- discovery cost is measured structurally and falls after surface trimming.

Sharp negative result:

- the split surface works mechanically but the model cannot select the correct
  layer, or the discovery tax outweighs reuse. That would mean the next
  `ptc_runner` work is not more prelude machinery, but better discovery,
  summarization, or surface design.
