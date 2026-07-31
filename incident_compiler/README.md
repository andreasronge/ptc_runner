# Incident-evidence compiler

A read-only reference application that turns incident evidence — alerts,
deployments, logs, traces, responder chat, tickets — into a report in which
every material claim must resolve to a real evidence record before the report
is published.

This is Phase 1: the complete application running against three hand-authored
fixture incidents, credential-free. It is not yet a benchmark, and it makes no
measured claim about report quality.

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
fixtures/incidents/          three hand-authored evidence corpora
fixtures/replay/scripts/     scripted model turns, one file per scenario
fixtures/replay/programs/    the PTC-Lisp each scripted turn runs
fixtures/replay/compiler.jsonl  generated frozen model responses
tools/record.exs             regenerates the frozen responses
```

Record `content_digest` values are derived by the server from the record's own
fields rather than authored in the corpus, so a citation digest cannot drift
from the evidence it names.

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

It passes against `openrouter:deepseek/deepseek-v3.2` in roughly 90 seconds and
about twenty turns, where the scripted path needs five. Getting there required
four fixes, and all four came from the live run rather than from replay:

- `workflow_capability_calls_per_name` and `mission_capability_calls_per_name`
  both default to low values relative to this workload. A live agent exhausts
  the per-name model-call quota mid-run, and `agent.core` surfaces that
  refusal as `llm-provider-error`, which reads like a provider outage rather
  than a budget the manifest failed to request.
- The task text now tells the model that one program can fetch many records
  and keep them in a definition. Without it the model spent one turn per
  record, which is the round-trip cost the runtime exists to remove.
- The task text now states the report's exact key set, for the reason in
  finding 4 below.

## Phase 1 scope

Deliberately narrowed, and worth stating so the narrowing is not mistaken for
coverage:

- **Three evidence tools, not six.** The ingestion surface is
  `evidence.list_sources`, `evidence.search`, and `evidence.get`. Typed
  `metrics.query_range`, `logs.search`, and `traces.get` views would re-slice
  the same hand-authored corpus without adding evidence value; they belong
  with real backends. The corpora already carry metric, log, and trace record
  kinds so those tools can be added over the same records later.
- **No oracle files.** Scoring citation completeness and required-fact recall
  mechanically is Phase 2 work. Nothing here scores the report's content.
- **Scripted turns test the compiler, not the model.** The frozen responses
  exist to exercise correction, publication, and refusal deterministically —
  including failure paths a real model might not produce on demand. Evidence
  about model behaviour comes from the live comparison in later phases.
- **Structured abstention is contract-tested only.** The
  `insufficient_evidence` branch is exercised against the compiled contract,
  not through a full scripted run.

## Findings for the plan

Phase 1 exists partly to discover what the runtime cannot yet express. Four
things surfaced while building it:

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

4. **An `additionalProperties` violation cannot be corrected from its own
   feedback.** The result-contract classification names the path of an
   undeclared key but replaces the key itself with `(undeclared)`, because the
   name is caller-authored content. That redaction is right, and it leaves the
   model told *where* it erred and not *what* it added — against a live model
   this produced `timeline[9].(undeclared)` on five consecutive correction
   turns until the run died at its turn limit. The workaround is for the
   application to publish its own key set in the prompt, which this one now
   does. It works, and it means every application with a closed contract must
   restate that contract in prose or spend its correction budget guessing.

The first two are small. The third and fourth are worth carrying into the
abstraction-feedback discussion: the third is the difference between "the
model gets one chance to fix a fabricated citation" and "the run is lost," and
the fourth is a correction protocol that cannot correct the most common closed-
schema failure without help the runtime does not provide.
