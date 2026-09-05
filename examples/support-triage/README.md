# Support-triage examples

Materialize a copy of this directory with
`ptc init support-triage --example support-triage`, then run the commands
below from the directory that copy sits in.
`ptc docs designing-agent-workflows` walks these three projects in order and
explains each design decision; `ptc docs agent-workflow-patterns` names the
recurring workflow shapes they demonstrate.

The three projects grow one scenario — a small support-ticket inbox — from a
single bounded question into a two-specialist workflow with a result contract:

1. `01-one-question` grants the tickets as mission data and asks one question.
   The model writes one program over `data/tickets`; no tools are involved.
2. `02-domain-api` adds `triage.clj`, a prompt-visible mission API holding the
   deterministic SLA and priority policy. The model composes those functions
   and the data in one program instead of relaying tool calls.
3. `03-specialists` splits the work across two named missions with different
   grants — `triage` holds the tickets and the scoring policy, `escalation`
   holds only the routing policy — and validates the final report against a
   result contract.

Each step has a project document in this directory. All three select the
trusted `deepseek` model alias and require a non-empty `OPENROUTER_API_KEY`.
Keep the generated comment-only `.env` and export the variable, or replace its
comment with a non-empty assignment in that file. Assigned file values override
exported values, including empty assignments:

```console
ptc init support-triage --example support-triage
export OPENROUTER_API_KEY=...
ptc run support-triage/01-one-question.ptc-project.json
ptc run support-triage/02-domain-api.ptc-project.json
ptc run support-triage/03-specialists.ptc-project.json
```

Every project document here sets `artifacts.inspection` and `viewer.private`
to `true`, because reading the PTC-Lisp the model wrote is the point:

```console
ptc viewer support-triage/03-specialists.ptc-project.json
```

That evidence contains prompts, responses, and generated source; a project
that should not retain it sets both settings back to `false`.

Each step directory is the complete project at that point, so later steps
repeat earlier files rather than referencing them; diff two step directories
to see exactly what a design decision added.

`ptc-host.json` is the shared operator document these examples install from;
`ptc docs host-configuration` explains its fields.

`03-specialists/workflow.clj` wraps the ranked tickets in an
`<untrusted_tickets>` block before they enter the escalation task, because
ticket text is customer-authored. The block tells the model to treat that text
as data; it does not stop a misleading ticket from producing a wrong team or
priority. The mission grant prevents the escalation model from calling a
capability or reading the wider ticket pool directly. It does not filter the
handoff, so this example provides no data-flow guarantee. The scheduled live
test checks each escalation's id, priority, team, and first action against the
policy; only the summary prose goes unchecked.

## Watch a denied capability

`mission-boundary-check` is not a fourth design step. It is a deterministic
check on the grants step 03 declares. It reuses the same two mission
definitions, selects no provider, and names no host document, so it needs no
key and no network:

```console
ptc run support-triage/mission-boundary-check.ptc-project.json
```

```json
{"denied":{"mission":"escalation",
           "mission_component":"invalid_form: unknown namespace triage.rules/",
           "mission_data":"runtime_error: data/tickets is not a granted data name. Granted: (none)"},
 "granted":{"mission":"triage","probe_priority":55,"tickets_visible":6}}
```

`mission-boundary-check/check.clj` sends the same two `(program ...)` literals
to both missions. One counts `data/tickets`; the other calls
`triage.rules/priority`. Both belong to the `triage` grant and neither to the
`escalation` one, so the two refusals have different shapes. The data
reference is a runtime refusal that also lists the data names that mission does
hold, which here is none. The component call never compiles, because that
namespace is not in the escalation bundle at all. The source is identical
either way, so the grant is what decided, not the program.

The check exits 0 while the boundary holds and fails with exit status 5 if
either program ever answers inside `escalation`, or if a refusal arrives that
is not the one a missing grant produces. Those are the regressions it exists
to catch. `ptc validate` prints the same two grant sets without running
anything:

```console
ptc validate support-triage/mission-boundary-check.ptc-project.json
```
