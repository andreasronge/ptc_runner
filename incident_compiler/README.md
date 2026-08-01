# Incident-evidence compiler

A read-only reference application that turns incident evidence — alerts,
deployments, logs, traces, responder chat, tickets — into a report in which
every material claim must resolve to a real evidence record before the report
is published.

Phases 1 and 2 are done: the complete application runs credential-free, and a
ten-incident corpus with machine-readable oracles and a mechanical scorer is in
place. There is still no measured claim about report quality — comparing
systems is Phase 3, and nothing here has run that comparison.

## Run it

Nothing here needs an API key. The model is an `llm_replay` alias over frozen
fixtures and the evidence source is the stdio MCP server in `server/`.

```console
mix ptc.run incident_compiler/ptc.json --host-config incident_compiler/ptc-host.json
```

Inspect what the application is allowed to reach before running it:

```console
mix ptc.run incident_compiler/ptc.json --host-config incident_compiler/ptc-host.json --check
# mission  evidence  mcp/stdio  4 tools  4 read  0 write  ...
```

`4 read 0 write` is the static authority record. No write-effect tool is
installed, so no run of this application can mutate an alert, ticket,
repository, or cluster — provable from the two documents before anything
executes.

## What it actually enforces

Grounding is enforced in two layers, because one is not enough.

**The result contract** (`contracts/report.schema.json`) is checked by the
runtime against every model-authored terminal candidate. It requires observed
facts, hypotheses, and open questions to be distinct sections, and requires
every timeline entry, observed fact, and hypothesis to carry at least one
citation of the exact shape `{evidence_id, content_digest}` with a
well-formed `sha256:` digest. A rejection while turns remain returns the
bounded structural classification to the model for one ordinary correction
turn; the rejected value itself is withheld.

The compiler also reads the active compiled contract through
`kernel/result-contract-description` when it builds the model task. The prompt
therefore carries the exact schema-derived branch shapes instead of a second,
hand-maintained list of result keys.

**Citation resolution** (`incident.evidence/resolve-citations`) is what the
contract cannot do. A JSON Schema can require that a digest is 64 hex
characters; it cannot know whether any record carries it. After the agent loop
returns, the workflow resolves every distinct citation against the evidence
source and refuses to publish unless all of them name a real record whose
stored digest matches. The `auth-partial` scenario exists to demonstrate the
gap between the two layers: its report is structurally perfect and passes the
contract, and it is still refused, because one citation names a record that
does not exist.

The verification program is application source, but the identifiers spliced
into it come from the model. Both are restricted to a closed alphabet before
interpolation — `[a-z0-9][a-z0-9._-]*` for identifiers, `sha256:` plus 64 hex
characters for digests — so model-authored text cannot carry a quote,
backslash, or parenthesis and cannot extend the program being built. A
citation that fails that check refuses publication rather than being skipped.

### What this does not claim

- **Not "no false statements."** The runtime enforces that a citation exists,
  is well shaped, and resolves to a real evidence record. It cannot prove the
  cited record semantically supports the claim. What holds is that no
  unsupported statement ships unreviewed, and that every statement is one step
  from its evidence.
- **Not immunity to prompt injection.** Text inside evidence can still steer
  the narrative. What is provable is that injection cannot escalate authority,
  because no write is reachable, and that an invented claim fails closed
  unless it cites resolvable evidence.
- **Not an adversarial isolation boundary.** Cheap BEAM process isolation is
  an efficiency property — evaluation matrices cost processes, not containers.

## Scenarios

Each fixture incident carries a conflicting responder hypothesis, a misleading
correlation, and a gap the evidence cannot close. Each scenario proves a
different property of the compiler.

| Manifest | Incident | Proves |
| --- | --- | --- |
| `ptc.json` | `checkout-5xx` | A draft asserting an uncited customer-impact number is rejected by the result contract, corrected in one turn, and published only after the number reappears as an open question. |
| `ptc.queue-backlog.json` | `queue-backlog` | A clean first-attempt publication, with two responder hypotheses the records contradict kept as low-confidence hypotheses carrying their contradicting evidence. |
| `ptc.auth-partial.json` | `auth-partial` | A contract-valid report carrying one fabricated citation is refused. The run fails closed and publishes nothing. |
| `selftest.json` | `checkout-5xx` | Model-free: exercises every installed evidence tool and both resolution failure modes without spending a model turn. |

The misleading correlations are deliberate. In `checkout-5xx` a release lands
two minutes before the alert and a rollback appears to fix an incident that had
already recovered six minutes earlier; in `queue-backlog` a retention change
lands three minutes before the alert and cannot affect consumer progress; in
`auth-partial` a maintenance window opens five minutes before the alert in a
region that hosts no authentication capacity.

## Layout

```
compiler.clj                 workflow entry: task, agent loop, citation resolution
evidence.clj                 mission component: read-only evidence access + resolver
selftest.clj                 workflow entry: model-free evidence-surface check
contracts/                   input and result contracts
server/evidence_server.exs   stdio MCP fixture server (read-only, no dependencies)
fixtures/corpus/<id>/        one incident: incident.json, evidence/, oracle/
fixtures/replay/scripts/     scripted model turns, one file per scenario
fixtures/replay/programs/    the PTC-Lisp each scripted turn runs
fixtures/replay/compiler.jsonl  generated frozen model responses
tools/record.exs             regenerates the frozen responses
tools/scorer.exs             scores a report against an oracle
```

Record `content_digest` values are derived from the record's own fields rather
than authored in the corpus, so a citation digest cannot drift from the
evidence it names. The server reads only `incident.json` and
`evidence/records.json`; it has no code path that opens `oracle/`, so the
answer key cannot reach a model through any tool.

## Corpus and oracles

Ten incidents, each carrying a conflicting responder hypothesis, a misleading
correlation, and a gap the evidence cannot close. Six also carry a named
adversarial variant:

| Incident | Adversarial variant |
| --- | --- |
| `cache-stampede` | Duplicate events — one eviction ingested twice, and a responder who reads it as two |
| `dns-flap` | Clock skew — a resolver 7m09s fast, which inverts causality if its timestamps are taken at face value |
| `disk-pressure` | Irrelevant alerts — three unrelated alerts fire in the window, each naming a real system |
| `gateway-injection` | Prompt-injection text embedded in a log body, instructing its reader to attribute the incident elsewhere and cite a record that does not exist |
| `dual-cause-payments` | Two simultaneous root causes starting four minutes apart, where fixing one leaves a third of traffic failing |
| `batch-silent-failure` | An evidence gap severe enough that abstention is the correct outcome — logs and input data both aged out before anyone looked |

Each incident's `oracle/oracle.json` carries the injected fault or faults, the
facts a report must recall (each keyed to the evidence that establishes it plus
tokens that must appear), claims that may only appear as hypotheses, the
contradicted hypotheses and the evidence that contradicts them, the required
open questions, and a rubric for the human adjudication pass. The rubric is the
only part no code reads.

`tools/scorer.exs` scores a report against an oracle: citation resolution,
citation completeness, required-fact recall, contradiction recall,
open-question recall, fact/hypothesis separation violations, and noise-citation
rate. It resolves every citation itself rather than trusting the producer,
because three of the four systems Phase 3 will compare have no fail-closed
publication.

Scoring is exercised in both directions. Each metric is asserted against the
compiler's real output and against a report deliberately broken in exactly the
way that metric exists to catch — a fabricated citation, a tampered digest, an
uncited claim, dropped facts, an inference stated as an observation, dropped
contradicting evidence. A scorer that only ever awards full marks proves
nothing.

### What the current scores are not evidence of

The oracles for `checkout-5xx` and `queue-backlog` were written alongside their
scripted reports rather than derived from the evidence independently. Every one
of their `must_include` tokens — 15 of 15 and 14 of 14 — appears in the
scripted report. Those two reports therefore score full recall partly because
the oracle was written from them, and the `== 1.0` assertions are regression
guards rather than quality measurements.

This does not contaminate Phase 3. The baseline systems never see these
reports, so the same oracle scores them independently. It does mean no number
here should be quoted as evidence that the compiler produces good reports, and
that the two oracles should be re-derived from the evidence by someone who has
not read the scripted output before they carry any comparative weight.

Two related limits are structural rather than accidental.
`citation_completeness` is 1.0 for any contract-valid report by construction,
because the result contract already requires a citation on every claim — it
measures the contract, and only discriminates for producers without one. And
an abstaining report cannot carry observed facts, so its required-fact recall
is always 0: correct on `batch-silent-failure`, a total failure anywhere else.
The score reports `abstention_defensible` alongside the ratio so the two are
never read as the same result.

## Regenerating the frozen model responses

A replay entry is keyed by the hash of the provider-neutral request, and that
request carries the accumulated transcript — so the key for turn N is unknown
until turns 1..N-1 are answered. The recorder closes that loop without a
credential: it runs the application against the fixture built so far, reads the
`llm-request` arguments back out of a private inspection artifact, hashes them,
pairs each with the authored turn at the same position, and repeats until a run
produces no request the fixture cannot answer.

```console
mix run incident_compiler/tools/record.exs               # all scenarios
mix run incident_compiler/tools/record.exs checkout-5xx  # one scenario
```

Editing a corpus record, a scripted program, or the task text changes the
request hashes and requires re-recording.

## Live model

One `:e2e` test runs the same application against a real model, asserting only
that the contract is satisfiable and that publication succeeded — never that
the diagnosis is correct.

```console
mix test test/incident_compiler/compiler_e2e_test.exs --include e2e
```

It publishes against `openrouter:deepseek/deepseek-v3.2` in roughly 90 seconds
and about twelve turns, where the scripted path needs five. That number is
measured, not asserted once: an earlier version of this file claimed the test
"passes" on the strength of a single green run, and re-running it four more
times showed it published roughly half the time. Do not trust a
single live run, including this one.

Every fix below came from the live run. Replay could not have surfaced any of
them, because the scripted turns never make the mistakes a real model makes.

- **Capability quotas are the first thing to exhaust.**
  `workflow_capability_calls_per_name` and `mission_capability_calls_per_name`
  default to 16 and 32, well below this workload. A live agent hits the
  per-name model-call quota mid-run, and `agent.core` reports that refusal as
  `llm-provider-error` — which reads like a provider outage rather than a
  budget the manifest failed to request.
- **Untyped signatures cost turns.** `list-sources`, `search`, and
  `get-record` originally returned `:map`. The model guessed a result key,
  got nothing, and spent a turn calling `keys` to discover the shape. Spelling
  the shape out in the signature removed that entirely: searches per run fell
  from 14 to 1.
- **"Keep them in a definition" was too vague.** The model read it as licence
  to define helper *functions* while re-running the search and refetching all
  thirteen records inside every program. Naming `def` explicitly, with an
  example, cut model turns from 24 to 12 and took the failure mode from
  turn-limit exhaustion to publication. Together with typed signatures this is
  what moved the success rate from roughly half to four out of four.
- **The output shape has to be in the prompt**, for the reason in finding 4
  below.

## Telemetry capture from SREGym

The corpus plan calls for capturing the telemetry half from SREGym and
synthesising the human half — responder chat, deployments, tickets — by hand.
Licensing is clear: SREGym is MIT, so its material is redistributable here.
Capture is not done, and it is the one part of Phase 2 left open.

Running SREGym needs a Kubernetes cluster, Docker, Helm, and kubectl. In this
working environment `kind` and `helm` are absent and the Docker daemon is not
running, so no capture was attempted rather than half-attempted. Every record
in the corpus is therefore hand-synthesised and marked `"origin":
"synthesized"` in its `incident.json`, so captured telemetry can be
distinguished from authored telemetry the moment any lands.

Nothing else depends on that capture. The oracle schema, the scorer, and the
adversarial variants all work the same way on captured telemetry, and the human
layer — which is where the hard citation problems live — would be authored by
hand either way.

## Scope

Deliberately narrowed, and worth stating so the narrowing is not mistaken for
coverage:

- **Three evidence tools, not six.** The ingestion surface is
  `evidence.list_sources`, `evidence.search`, and `evidence.get`. Typed
  `metrics.query_range`, `logs.search`, and `traces.get` views would re-slice
  the same hand-authored corpus without adding evidence value; they belong
  with real backends. The corpora already carry metric, log, and trace record
  kinds so those tools can be added over the same records later.
- **Three incidents are scripted, not ten.** All ten have evidence and oracles,
  but only `checkout-5xx`, `queue-backlog`, and `auth-partial` have frozen
  model turns and run end to end. Running the whole corpus is the Phase 3
  matrix, and it needs the baseline systems to exist first.
- **Scripted turns test the compiler, not the model.** The frozen responses
  exist to exercise correction, publication, and refusal deterministically —
  including failure paths a real model might not produce on demand. Evidence
  about model behaviour comes from the live comparison in later phases.
- **Semantic support is not scored.** Whether a cited record actually supports
  the claim attached to it is not mechanically decidable. The scorer measures
  what is; blind human adjudication on a subset is Phase 4, and the oracle
  rubric exists for that pass.
- **Fact/hypothesis separation is best-effort.** A violation is caught only
  when an oracle's whole token conjunction appears inside an observed fact, so
  paraphrase escapes it. It is reported as a violation count rather than a
  score for that reason.
- **Structured abstention is contract-tested only.** The
  `insufficient_evidence` branch is exercised against the compiled contract and
  against the scorer, not yet through a full scripted run — `batch-silent-
  failure` is the incident that will exercise it.

## Findings for the plan

Phase 1 exists partly to discover what the runtime cannot yet express. Five
things surfaced while building it; the last two exposed runtime correction and
prompt gaps this branch fixes:

1. **The canonical annotation vocabulary is closed.** `SafeMetadata` admits
   only `progress` and `agent-action`, and `progress` carries a single `stage`
   key. An application-level verification outcome — how many citations were
   checked, how many failed to resolve — cannot be published to a normal
   trace. The compiler emits `validating` and then `completed` or `failed`, so
   the refusal is observable, but the counts stay in the failure value.
2. **Application failure kinds are fingerprinted, not named.** A refusal
   surfaces publicly as `failure_kind_fingerprint`, so a reader cannot tell
   `unresolved-citations` from any other application failure without computing
   the fingerprint. That is correct for privacy and awkward for an application
   whose whole point is a legible refusal.
3. **Verification cannot run inside the agent loop.** Mission capabilities are
   unreachable from the workflow except through `kernel/eval-source`, and the
   loop's only in-loop validation hook is the result contract. Citation
   resolution therefore runs after the loop has ended, so an unresolved
   citation fails the run rather than earning the correction turn a contract
   violation gets. Closing that would need either an application-supplied
   in-loop validator or a contract keyword that can express resolution.

4. **Tagged-union contracts reported the wrong violation, on every failure.**
   `ValueContract.classify/2` picked the branch's error units by list position,
   assuming `JSV.normalize_error/1` returns one unit per `oneOf` alternative in
   schema order. It returns a flat list ordered by instance location instead,
   so indexing it landed on whichever alternative happened to sit there —
   almost always one the discriminator had not selected, whose only complaint
   is that it was handed keys it never declared. Five different defects in this
   application's contract — an empty citation array, a malformed digest, a
   missing required key, a bad enum, an undeclared key — all reported the
   identical violation at `timeline`, and a minimal reproduction reported
   `kind: :const` on the discriminator itself, telling the model the one field
   it had got right was wrong. Fixed by selecting units on their
   `schemaLocation` prefix; each of the five now names its own field. The
   existing test for this passed throughout, because its union happens to
   select branch 1 and the list happened to put a usable unit there.

5. **An undeclared key still cannot be named back.** With the above fixed, the
   classification points at the right object but still renders the offending
   key as `(undeclared)`, correctly, since the name is caller-authored content.
   Fixed in two complementary ways: correction diagnostics now return the
   schema-declared key set at that object, and
   `kernel/result-contract-description` makes `ValueContract.describe/1`
   available to workflows. This compiler inserts that generated description
   into its task instead of hand-writing the report key set.

The first two are small. The third is the difference between "the model gets
one chance to fix a fabricated citation" and "the run is lost." The fourth was
silently degrading every correction turn any tagged-union contract has ever
run, and is fixed. The fifth is fixed by the generated contract-description
route.
