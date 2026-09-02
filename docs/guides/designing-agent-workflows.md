# Design an agent workflow

Build a small support-inbox agent in three runnable steps: grant the data, move
the rules into code, then split the work between two specialists.

Materialize the three projects and export an
[OpenRouter](https://openrouter.ai/keys) key. Each run costs well under a cent.

```console
ptc init support-triage --example support-triage
export OPENROUTER_API_KEY=...
```

## Step 1: ask one bounded question

The smallest agent is one run over data you already hold. The first manifest
grants the tickets as mission `data` and declares no tools:

```json
"missions": {
  "default": {
    "components": [],
    "data": {"tickets": [{"id": "T-1001", "...": "..."}]}
  }
}
```

The whole trusted workflow delegates to the shipped loop:

```clojure
(defn run [input]
  (agent.core/run (get input "task") {"max_turns" 3}))
```

```console
ptc run support-triage/01-one-question.ptc-project.json
```

```json
{"ok":true,"value":["T-1001","T-1004"]}
```

The model reads `data/tickets`, writes one program that filters it, and returns
the ids. Open the Viewer to read that program:

```console
ptc viewer support-triage/01-one-question.ptc-project.json
```

The decision in this step is what the mission leaves out. It holds six tickets
and nothing else: no filesystem, no working directory, no tool to wander into.
When you already have the data, grant the data.

## Step 2: move the rules into mission code

Where do the SLA thresholds and priority rules live? In the task prompt they
are suggestions the model can drift from. As one tool per rule they make the
model relay every intermediate value through its context. The second project
ships them as a mission component, `triage.clj`:

```clojure
(defn priority
  "Priority score from 0 to 100: SLA breach, wait time, and refund risk."
  {:signature "(ticket :map) -> :int"}
  [ticket]
  ...)
```

```console
ptc run support-triage/02-domain-api.ptc-project.json
```

```json
{"ok":true,"value":[{"id":"T-1004","priority":81},{"id":"T-1001","priority":75},
{"id":"T-1006","priority":58},{"id":"T-1005","priority":52}]}
```

Mission exports are advertised to the model, so it composes
`triage.rules/breached?` and `triage.rules/priority` with the data in one
program: filter, score, sort, return. The scores are what the code computes.

The model decides how to use the rules and cannot reinterpret them.
[Inspect and customize components](components-and-preludes.md) covers the
component and signature rules this step relies on.

## Step 3: give each specialist only what it needs

The last step routes each breached ticket to a team. Classifying a ticket is
model judgment. Routing is policy, and the routing stage has no use for the raw
ticket pool. So the third manifest declares two missions with different
grants:

```json
"missions": {
  "triage": {
    "components": [{"id": "triage.rules", "path": "triage.clj"}],
    "data": {"tickets": ["..."]}
  },
  "escalation": {
    "components": [{"id": "escalation.policy", "path": "escalation.clj"}]
  }
}
```

The workflow runs one loop per mission, passes only the ranked result forward,
and validates the final report against the manifest's `result_schema`.
`returned-value` and `quarantined` are not shipped built-ins; they are helpers
defined in this example's `03-specialists/workflow.clj`:

```clojure
(defn run [input]
  (let [ranked-outcome (agent.core/run-outcome
                         (get input "triage_task")
                         {"mission" "triage" "max_turns" 4})
        ranked (returned-value ranked-outcome "triage")
        report (agent.core/run-result-value
                 (str (get input "escalation_task")
                      "\n\nBreached tickets, highest priority first:\n"
                      (quarantined (pr-str ranked)))
                 {"mission" "escalation" "max_turns" 4})]
    (return report)))
```

Ticket text is written by customers, so `quarantined` wraps it in an
`<untrusted_tickets>` block before it enters the second task. The block asks
the model to treat that text as data.

What holds regardless is the grant: the escalation mission has no tickets and
no tools. The example's README says what its live test checks in the report.

```console
ptc run support-triage/03-specialists.ptc-project.json
```

```json
{"escalations":[
  {"id":"T-1004","priority":81,"team":"payments",
   "first_action":"send the refund-policy summary"},
  {"id":"T-1001","priority":75,"team":"payments",
   "first_action":"verify the charge with finance before replying"},
  {"id":"T-1006","priority":58,"team":"support",
   "first_action":"reply with the account-recovery checklist"},
  {"id":"T-1005","priority":52,"team":"sre",
   "first_action":"page the on-call engineer"}],
 "summary":"Four breached tickets were classified and escalated."}
```

Two rules carry this step.

- A specialist is a mission. The escalation model cannot read the ticket pool
  because it was never granted it.
- A consumer gets a contract. The runtime enforces the schema, so the shape of
  the report is a property of the run.

An invalid candidate receives correction feedback while turns remain; the
[agent library reference](../agent-library-reference.md#agent-core-run)
describes that loop.

## Where to go next

[Choose a workflow shape](agent-workflow-patterns.md) names the shapes these
steps used and the ones they did not, such as parallel fan-out and plan/act
phases. [Customize an agent](building-agents.md) covers replacing the loop's
prompts and policy. The
[PtcRunner tutorial series](https://github.com/andreasronge/ptc_runner_tutorial)
grows a multi-specialist agent chapter by chapter.
