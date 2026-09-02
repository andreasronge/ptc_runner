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

Each project has a project document in this directory. All three select the
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
