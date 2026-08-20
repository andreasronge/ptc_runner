# Design an agent workflow

> **Audience:** application authors turning a real task into their first
> multi-stage agent design.

Design a small support-inbox agent in three runnable steps: grant the data,
move the rules into code, then split the work between specialists.

Each step answers one design question — where does the data live, where do
the business rules live, and how is work divided between agents. The
configuration guides explain each surface exhaustively; this page shows why a
design uses them.

Materialize the three projects and supply an
[OpenRouter](https://openrouter.ai/keys) key:

```console
ptc init support-triage --example support-triage
```

Set `OPENROUTER_API_KEY` in the generated `support-triage/.env`. Each project
costs well under a cent to run with the tutorial's `deepseek` alias.

## Step 1: ask one bounded question

The smallest agent shape is a single bounded run: grant the data, ask the
question, read the answer. The first manifest declares no tools at all — the
tickets are granted as mission `data`:

```json
"missions": {
  "default": {
    "components": [],
    "data": {"tickets": [{"id": "T-1001", "...": "..."}]}
  }
}
```

and the entire trusted workflow delegates to the shipped loop:

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

The model reads the advertised `data/tickets`, writes one PTC-Lisp program
that filters it, and returns the ids. Open the Viewer to read that program:

```console
ptc viewer support-triage/01-one-question.ptc-project.json
```

The design decision here is what the mission does **not** contain. There is no
filesystem, no working directory, and no tool the model could wander into: the
mission holds exactly the six tickets and nothing else. When a question can be
answered from data you already have, granting the data is simpler and safer
than connecting a tool that reaches it.

## Step 2: move the rules into mission code

The second question the inbox scenario forces: where do the SLA thresholds and
priority rules live? Putting them in the task prompt makes them suggestions the
model may drift from. Exposing them as one-call-per-rule tools makes the model
relay intermediate results through its context. The second project instead
ships them as a prompt-visible mission component, `triage.clj`:

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

Mission component exports are advertised to the model by default; the
component's `{:visibility :prompt}` metadata only makes that default
explicit. The model now composes `triage.rules/breached?` and
`triage.rules/priority` with the granted data in a single program — filter,
score, sort, return — and the scores are exactly what the deterministic
policy computes. The model
decides *how to use* the rules; it cannot *reinterpret* them. That split is
the core of code-mode design: judgment in the model, policy in reviewable
code. [Customize agent components](components-and-preludes.md) covers the
component and signature rules this step relies on.

## Step 3: split authority between specialists

The final step routes each breached ticket to a team. Classification is
model judgment, but routing is policy — and the routing stage needs none of
the raw ticket pool. So the third manifest declares two named missions with
different grants:

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

The trusted workflow runs one loop in each mission, passing only the triage
result forward, and validates the final report against the manifest's
`result_schema` contract:

```clojure
(defn run [input]
  (let [ranked (returned-value
                 (agent.core/run-outcome (get input "triage_task")
                                         {"mission" "triage" "max_turns" 4})
                 "triage")]
    (return
      (agent.core/run-result-value
        (str (get input "escalation_task") "\n\n" (quarantined (pr-str ranked)))
        {"mission" "escalation" "max_turns" 4}))))
```

The `quarantined` helper marks the handoff: ticket subjects and bodies are
customer-authored, so the workflow wraps them in an `<untrusted_tickets>`
block (stripping any smuggled closing marker) and the task names the block as
data, not instructions. A stage boundary is also a trust boundary — the agent
loop marks its own tool observations as untrusted automatically, but text a
workflow splices into a task string is the workflow's responsibility.

```console
ptc run support-triage/03-specialists.ptc-project.json
```

A run returns a contract-valid report — every escalation names a schema-listed
team, and an invalid candidate would have received bounded correction feedback
instead of reaching you:

```json
{"escalations":[{"first_action":"send the refund-policy summary","id":"T-1004",
"priority":81,"team":"payments"},{"first_action":"page the on-call engineer",
"id":"T-1005","priority":52,"team":"sre"}],"summary":"..."}
```

Two design rules carry this step. Specialists are missions, not prompts: the
escalation model cannot read the ticket pool, because its mission was never
granted it — the workflow decides exactly what crosses the boundary. And
downstream consumers get contracts, not parsing: the schema is enforced by the
runtime, so the report's shape is a property of the run, not a hope about the
model. The correction loop is described in the
[agent library reference](../agent-library-reference.md).

## Where to go next

[Choose a workflow shape](agent-workflow-patterns.md) names the recurring
shapes these steps used — and the ones they didn't, such as parallel fan-out
and plan/act phases. [Customize an agent](building-agents.md) covers replacing
the loop's prompts and policy. For a longer course that builds a
multi-specialist agent scenario chapter by chapter, see the
[PtcRunner tutorial series](https://github.com/andreasronge/ptc_runner_tutorial).
