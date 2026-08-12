# Incident-evidence compiler reference application

**Status:** future, proposed; written 2026-07-31. Not scheduled; no approved
implementation work. Phase 1 may start on the current runtime at any time and
does not depend on the stable CLI plan.

PtcRunner has runtime demos (`examples/`) but no reference application that
solves a recognizable business problem end to end. This plan defines one: a
read-only compiler that turns incident evidence — alerts, deployments, logs,
traces, responder chat, tickets — into a reviewable report in which every
material claim must resolve to source evidence before release.

One artifact serves four purposes: proof the runtime solves real problems,
marketing evidence, an integration test across the manifest/MCP/contract
surface, and a customer-discovery instrument.

## The claim under test

The application exists to make one narrow claim demonstrable:

> Given identical incident evidence, the same model, and the same read-only
> tools, the compiler produces a report that is faster to verify, contains
> fewer unsupported material claims, and runs under statically provable
> read-only authority.

It deliberately does not claim better incident diagnosis, immunity to prompt
injection, or autonomous improvement.

Wording guardrails, fixed now because the demo will be scrutinized:

- The runtime enforces that a citation exists, is well shaped, and resolves to
  a real evidence record. It cannot prove the citation semantically supports
  the claim. Say "no unsupported statement ships unreviewed, and every
  statement is one click from its evidence" — never "no false statements."
- Injected text inside evidence can still steer report narrative. What is
  provable: injection cannot escalate authority (no write is reachable), and
  an invented claim fails closed unless it cites resolvable evidence. Say
  that; never "immune to prompt injection."
- Cheap BEAM isolation is an efficiency and evaluation-cost property, not an
  adversarial security boundary. Position it as "evaluation matrices cost
  processes, not containers."

## Why this domain

Selected 2026-07-31 from market research (verifiable-output demand, incumbent
gap) and from this repository's own evidence: the repo-analyst experiment
showed that runtime-enforced evidence contracts with a correction turn were
the intervention that moved publication validity (4/4 invalid drafts
corrected, 9/10 contract-valid publications). Incident evidence merges the two
strongest earlier candidates — enforced-citation extraction and incident
triage — and attaches a real compliance driver (DORA/NIS2 incident
reporting).

The regulatory overlay is deliberately **not** the application's identity.
`--format dora-final` is one output template among several (generic
postmortem, SEV review). Developers read GitHub; operational-resilience
buyers do not. Compliance monetization belongs to a separate closed product
and is out of scope here.

## Shape

A manifest-authored application on the current runtime (`mix ptc run` today;
a `ptc init` template once the stable CLI plan delivers `init`):

- **Ingestion** through read-only MCP tools only: `evidence.list_sources`,
  `evidence.search`, `evidence.get`, `metrics.query_range`, `logs.search`,
  `traces.get`, and constrained Kubernetes get/list. No write-effect tool is
  installed, so the manifest's static tool-authority record proves the
  compiler could never mutate an alert, ticket, repository, or cluster.
- **Normalized timeline** with stable per-record identity:
  `evidence_id`, `observed_at`, `source`, `content_digest`, payload.
- **Fact/hypothesis separation** in the report structure: observed facts,
  root-cause hypotheses, and open questions are distinct, contract-enforced
  sections.
- **Fail-closed publication.** Signed result contracts withhold a report when
  a required field or material claim lacks an event-level citation; the model
  receives the bounded structural classification and spends an ordinary turn
  correcting it (the `agent.main` correctable-terminal mechanism).

Prompts in the shared orchestration layer stay domain-blind per repository
policy; incident vocabulary lives only in this application's own components
and tool descriptions.

### Abstraction feedback

Boilerplate that this application repeats from `repo-analyst` — evidence and
citation result contracts, timeline normalization, correctable terminal
drafts — is a signal that the abstraction belongs in a shipped prelude.
Record each instance; lifting is its own slice with its own review.

## Phases

Ordered so the application exists before the benchmark does. The benchmark
cannot reveal that the report format is wrong or that the contract grammar
cannot express "material claim"; only building the application can.

### Phase 1. Compiler against three hand-authored fixtures

Build the complete application against three small, curated, deterministic
fixture incidents (fixture MCP server, scripted model where possible, live
model behind `:e2e`). Each fixture includes at least one adversarial element:
a conflicting responder hypothesis, a misleading deployment correlation, and
one missing-evidence gap that must produce an explicit open question rather
than a claim.

**Exit gate:** a credential-free run compiles each fixture into a
contract-valid report; withholding and correction are observable in the
trace; the static tool-authority record shows no write effect; one
`:e2e` live-model run passes.

### Phase 2. Fixture corpus

Capture ~10 SREGym-Lite scenarios (SREGym is MCP-native with Prometheus,
Loki, and Jaeger backends) and freeze the telemetry into deterministic
fixtures. SREGym supplies only the telemetry half; the human layer —
responder chat, deployments, tickets — is synthesized by hand, and that is
where the hard citation problems live. Add adversarial variants: clock skew,
duplicate events, irrelevant alerts, prompt-injection text embedded in a log,
one incident with two simultaneous root causes.

Fixture layout: per-incident `evidence/` (typed records with digests) and
`oracle/` (injected fault, required claims, known timeline, hypotheses,
contradictions, rubric). Verify redistribution licensing for anything
captured from third-party benchmarks; do not vendor CC BY-NC material
(e.g. ITBench trajectories) into this MIT repository.

**Exit gate:** the corpus replays deterministically; oracle files are
sufficient to score citation completeness and required-fact recall
mechanically.

### Phase 3. Four-system pilot, then set bars

Run four systems on ~10 cases with the same model, evidence, token budget,
and output schema:

1. deterministic baseline (sort events, fill template);
2. direct LLM (all evidence in one prompt);
3. conventional tool agent — pre-registered config, the model's native
   tool-calling loop over the same read-only MCP servers, chosen to be the
   least contestable baseline; and
4. the PtcRunner compiler.

Set release bars only after this pilot. The repo-analyst E4 record shows why:
at a floor-effect baseline the aggregate accepted a known-defective
candidate, and ARFBench's frontier score (62.7%) says incident-evidence tasks
are far from ceiling. Absolute targets chosen before measurement are coin
flips. The primary claim is relative: support precision materially above the
same-model conventional agent, with paired bootstrap confidence intervals.

**Exit gate:** all four systems produce scoreable output; baselines are above
the floor on required-fact recall; bars for Phase 4 are committed in writing
before the full matrix runs.

### Phase 4. Release evidence matrix

The full corpus across three noise seeds (~60 paired cases), scored on:
citation completeness (mechanical), required-fact recall (mechanical),
timeline accuracy, fact/hypothesis separation, abstention quality, cost,
latency, and authority (successful writes must be exactly zero). Semantic
support precision is adjudicated blind by at least two practitioners on a
subset; timed human-verification claims ship later or as anecdote, never as a
release-gate number.

**Exit gate:** the published result reports the pre-committed bars, paired
confidence intervals per incident, and every metric that failed — a bounded
comparison honest about its own power, in the style of the repo-analyst
record.

### Phase 5. Qualification packet second act

Reuse the frozen corpus as the case set for a component-level A/B: two
compiler versions differing in exactly one component hash, evaluated through
the candidate-evaluation chain, emitting a release packet with component
hashes, tool-authority diff, paired outcomes, contract failures, and cited
failure traces. This demonstrates content-addressed agent identity on a real
application at near-zero marginal cost, and is the honest, shippable form of
the self-improvement work: suggested candidates, human promotes.

## Non-goals

- No DORA/compliance product identity, hosted service, billing, or tenancy.
- No autonomous promotion of candidate components; the repo-analyst plan owns
  that research separately.
- No claim of better root-cause localization (RCAEval baselines may be run
  later, secondary only).
- No live third-party integrations (PagerDuty, GitHub, Datadog) before the
  fixture-based journeys are complete and demand exists.
- No new Kernel authority: the application uses installed read-only MCP
  sources and existing contract machinery only.

## Related documents

- [`lisp-kernel/product-readiness.md`](../lisp-kernel/product-readiness.md) —
  remaining runtime product work; this plan does not gate on it.
- [`lisp-kernel/stable-cli-contract.md`](../lisp-kernel/stable-cli-contract.md)
  — delivers `ptc init` templating this application later adopts.
- `repo-analyst-self-improvement.md` (branch
  `exp/self-improvement-loop-closure`) — evidence-contract and
  candidate-evaluation mechanisms this application reuses.
- [Manifests and capabilities](../../guides/manifests-and-capabilities.md) —
  tool effects, signed contracts, and authority validation.
- External: [SREGym](https://github.com/SREGym/SREGym),
  [ARFBench](https://github.com/DataDog/ARFBench),
  [RCAEval](https://github.com/phamquiluan/RCAEval).
