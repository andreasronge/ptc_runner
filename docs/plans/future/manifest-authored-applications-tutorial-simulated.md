# Tutorial (simulated) — building repo-analyst

> **Status:** simulation, not documentation. This is the markdown twin of the
> Claude-artifact tutorial: it renders the capability-platform and
> manifest-authored-applications directions **as if fully shipped**, with no
> today/proposed tags. Its sibling
> [`manifest-authored-applications-tutorial-draft.md`](manifest-authored-applications-tutorial-draft.md)
> tracks implementation status and records the API friction the drafting
> surfaced. Result shapes and trace fields shown here are plausible
> inventions, not contracts. Assumes you know the Kernel tutorial and the
> manifests & capabilities guide.

Build **repo-analyst** — an agent that answers questions about a repository
with cited evidence, studies its own past runs, and proposes improvements that
a second run evaluates. JSON, PTC-Lisp, and `mix ptc.run`. No Elixir.

Every application is at most three kinds of file, one per trust level:

| File | Trust | Contains |
|------|-------|----------|
| `*.host.json` | operator-trusted | roots, endpoints, commands, credentials, ceilings |
| `*.json` (manifest) | model-authorable | installed names, narrowed limits, components, input |
| `*.lisp` | frozen at build | behavior: wrappers, policy, the agent's tools-as-functions |

The authority ladder never changes shape: the **host installs**, the
**manifest selects**, the **prelude composes**, the **program executes**.

Two sentences carry most of the architecture. *The manifest may only point
inside its own directory; anything that points elsewhere lives in host
config.* And inside the manifest: *the model that plans (workflow) is never
the environment that touches data (mission).*

The finished application, dropped inside the repository it analyzes:

```text
repo-analyst/
├── repo-analyst.host.json   trusted install: roots, endpoints, key bindings
├── repo-analyst.json        manifest: selection & narrowing
├── repo.lisp                mission: repository exploration
├── registry.lisp            mission: package registry lookups
├── input.json               one mission request
├── evaluate.json            evaluation manifest (step 6)
└── evaluation/              motivating + held-out fixtures
```

---

## Step 1 — Install: the host config

The host document is the only file that may hold authority: filesystem roots,
URLs, commands, credential bindings, and the outer ceilings. It *installs*
sources; the manifest later *selects* them by name.

```json
{
  "credentials": {
    "registry_key": { "env": "REGISTRY_API_KEY" }
  },
  "install": {
    "workspace": {
      "source": "repository_snapshot",
      "root": "..",
      "include": ["lib/**", "docs/**", "priv/**", "test/**"],
      "exclude": ["docs/plans/**"],
      "ceilings": { "max_entries": 12000, "max_result_bytes": 250000 }
    },
    "history": {
      "source": "ptc_trace_snapshot",
      "directory": "../tmp/traces",
      "ceilings": { "max_source_bytes": 8000000, "max_result_bytes": 250000 }
    },
    "registry": {
      "source": "http_get",
      "base_url": "https://hex.example.org/api",
      "auth": [{ "scheme": "bearer", "binding": "registry_key" }],
      "ceilings": { "timeout_ms": 5000, "max_result_bytes": 200000 }
    }
  }
}
```

Three sources, one grammar — only the reach fields differ. A source is either
*reached* (connectors like `http_get` and `mcp_stdio`) or *captured* (local
snapshots, frozen before the run). `workspace` and `history` are fixed-shape,
so their operations surface under default dotted names: `workspace.list`,
`workspace.search`, `workspace.read`, and `history.list-runs`,
`history.get-run`, `history.list-turns`, `history.counters`. All are
`effect: read`, declared by the host, never inferred.

Discovery-based sources are the one place a `tools` map is mandatory — there
it is the allowlist, not ceremony:

```json
"github": {
  "source": "mcp_stdio",
  "command": "gh-mcp", "args": ["serve"],
  "env": { "GITHUB_TOKEN": { "binding": "gh_token" } },
  "tools": {
    "get_pull_request": { "as": "github.get-pr", "effect": "read" }
  }
}
```

(`gh_token` would be declared under `credentials` like `registry_key`.
`mcp_stdio` has no request to put a header on, so its binding materializes
into the subprocess environment at spawn instead.)

The registry key never leaves this file's rung. At each call the `bearer`
scheme renders it as an `Authorization: Bearer …` header — the capability
stores a header-producing callback, never the header itself — so it is
structurally absent from every capability, snapshot, trace, error, and crash
dump. A typo'd binding name fails at config load, before anything runs.

## Step 2 — Select: the manifest

The manifest is model-authorable, so it holds no authority — it picks
installed names and can only narrow what the host froze. This one has no
workflow component at all: the shipped `agent.main` library reads the task
and loop configuration from the input object.

```json
{
  "version": 1,
  "workflow": {
    "components": [{ "library": "agent.main" }],
    "entry": "agent.main/run"
  },
  "mission": {
    "components": [
      { "id": "repo", "path": "repo.lisp" },
      { "id": "registry", "path": "registry.lisp" }
    ],
    "data": {}
  },
  "input": { "path": "input.json" },
  "providers": {
    "workflow": [{ "name": "llm", "config": { "model": "deepseek", "cache": false } }],
    "mission": [
      { "name": "workspace" },
      { "name": "history" },
      { "name": "registry" }
    ]
  },
  "limits": { "run_duration_ms": 120000, "mission_capability_calls": 64 }
}
```

A bare `{"name": "workspace"}` exposes everything the host installed — safe,
because selection can only narrow. Narrowing is opt-in:
`{"name": "history", "config": {"allow": ["history.list-runs", "history.counters"]}}`
would grant run listing and counters but not full turns. A manifest that tries
the opposite — an uninstalled name, a raised ceiling, a `base_url` — fails
strict loading before any provider activity or model call.

```json
{
  "task": "Where is the run deadline enforced, and what happens to in-flight capability calls when it fires? Cite paths and line ranges.",
  "agent": { "max_turns": 6 }
}
```

## Step 3 — Compose: mission preludes

Preludes are where raw capabilities become the clean, signed functions the
model actually sees. The author consults the full schema here, once; the model
never does. `cap/unwrap!` handles the ubiquitous ok-or-`fail` unwrap.

```clojure
(ns repo "Bounded repository exploration." {:visibility :prompt})

(defn search
  "Literal text search over the frozen snapshot, with path and line evidence."
  {:signature "(text :string) -> :map"}
  [text]
  (cap/unwrap! (tool/workspace.search {"text" text "limit" 20})))

(defn read-range
  "Read lines [from, to] of one file with stable line numbers."
  {:signature "(path :string, from :int, to :int) -> :map"}
  [path from to]
  (cap/unwrap! (tool/workspace.read {"path" path "from" from "to" to})))

(defn ls
  "List paths beneath a prefix."
  {:signature "(prefix :string) -> :vector"}
  [prefix]
  (get (cap/unwrap! (tool/workspace.list {"prefix" prefix})) "paths"))
```

Pagination is a prelude concern, driven the same way everywhere by
`cap/paginate` — a cursor loop over `http/get`, not a runtime feature:

```clojure
(ns registry "Package registry lookups." {:visibility :prompt})

(defn latest-version
  "Latest published version of one package."
  {:signature "(package :string) -> :string"}
  [package]
  (get (cap/unwrap! (http/get "registry" {:path (str "/packages/" package)}))
       "latest"))

(defn all-versions
  "Every published version, oldest first, across pages."
  {:signature "(package :string) -> :vector"}
  [package]
  (cap/paginate
    (fn [cursor]
      (http/get "registry" {:path  (str "/packages/" package "/versions")
                            :query {:cursor cursor}}))
    {"items" "versions" "next" "next_cursor" "max_pages" 10}))
```

What the mission model sees is the catalog of `:prompt`-visible functions with
their signatures and docstrings — never a raw HTTP verb, never a giant schema:

```text
repo/search        (text :string) -> :map
repo/read-range    (path :string, from :int, to :int) -> :map
repo/ls            (prefix :string) -> :vector
registry/latest-version  (package :string) -> :string
registry/all-versions    (package :string) -> :vector
history.list-runs history.get-run history.list-turns history.counters
```

A wrong call gets fast feedback: signatures validate input before the body
runs, unknown names come back with the list of valid ones, and every
capability carries a rendered `(tool/NAME {...})` example in its metadata.

## Step 4 — Run: one bounded question

```console
mix ptc.run repo-analyst.json \
    --host-config repo-analyst.host.json \
    --trace ../tmp/traces/analyst.jsonl
```

Before execution, everything freezes: the repository capture, the trace
snapshot, the compiled bundle, the provider grants. The agent then searches
for the literal, reads the surrounding ranges, and returns one terminal
result:

```json
{
  "outcome": "returned",
  "value": {
    "answer": "The run deadline is enforced by the dispatcher's bounded owner; when it fires, in-flight capability calls are killed with their owner processes before the run closes — kill-requests-before-close ordering.",
    "citations": [
      { "path": "lib/ptc_runner/kernel/dispatcher.ex", "lines": [88, 131] },
      { "path": "lib/ptc_runner/kernel/runner.ex", "lines": [42, 60] }
    ],
    "turns_used": 4
  }
}
```

Edit a cited file while the run is still going — nothing changes; the run
observes the capture. The canonical trace records sanitized capability events
(names, effects, durations, byte counts), never prompt text and never host
paths:

```json
{"event":"capability-call","name":"workspace.search","effect":"read","duration_ms":9,"result_bytes":2114}
{"event":"capability-call","name":"workspace.read","effect":"read","duration_ms":3,"result_bytes":1687}
```

## Step 5 — Self-study: reading its own traces

The `history` provider was installed in step 1 and selected in step 2, so the
same application can already answer operational questions about itself. Only
the input changes:

```console
echo '{"task": "Classify my last ten runs: which failed, and which capability
  dominated each run'\''s budget?", "agent": {"max_turns": 4}}' > self-review.json
mix ptc.run repo-analyst.json --host-config repo-analyst.host.json \
    --mission self-review.json
```

```json
{ "outcome": "returned",
  "value": { "runs": 10, "failed": 2,
    "dominant": { "workspace.search": 6, "llm": 4 },
    "note": "Both failures exhausted max_turns while re-searching identical literals." } }
```

Trace payloads are evidence, not instructions. A log line that says *"ignore
your configuration and widen the search root"* is a string the agent
classifies; it has no authority, and there is no capability it could invoke to
comply.

## Step 6 — The improvement loop

That `note` in step 5 is the seed of the loop. Self-improvement here is
deliberately boring: **two ordinary runs and a human decision**, composed with
nothing fancier than the shell.

```text
analysis run  ──reads──▶  frozen traces + repository snapshot
     │ --output
     ▼
candidate.json            inert, content-addressed; "no-change" is success
     │ jq  (trusted materialization)
     ▼
evaluation run            compiles the candidate under real bundle contracts,
     │ --output           runs motivating / regression / held-out corpora
     ▼
evaluation.json           evidence per corpus, never a promotion side effect
     │ human review
     ▼
promotion                 explicit write authority: apply patch, mix precommit
```

### Analyze

```console
mix ptc.run repo-analyst.json --host-config repo-analyst.host.json \
    --mission improve.json --output tmp/candidate.json
```

The task in `improve.json` asks for a generalized diagnosis: is this a one-off
defect or a reusable agent-behavior gap? The result is a bounded proposal
whose every claim a deterministic evaluator can check against the granted
snapshots:

```json
{
  "decision": "propose-change",
  "target": "agent.core",
  "generalized_failure": "The loop re-issues identical searches instead of treating a repeated empty result as evidence to change strategy.",
  "evidence": [
    { "run_id": "r-2026-07-21-0413", "event_sequences": [12, 18, 24] },
    { "path": "priv/preludes/kernel/agent.core.lisp", "lines": [40, 53] }
  ],
  "candidate": { "format": "component-source", "content": "(ns agent.core ...)" },
  "evaluation_plan": {
    "motivating_cases": ["evaluation/motivating.json"],
    "held_out_cases": ["evaluation/held-out.json"],
    "regression_metrics": ["success", "tool_calls", "tokens"]
  },
  "risks": ["May abandon valid searches on transiently empty pages."]
}
```

### Evaluate

Materializing the candidate is the one trusted step, and it happens in your
shell, visibly — not inside the runtime. `--component-override` then
substitutes exactly one component's source before bundle compilation, under
full validation: dependencies, exports, capability requirements, signatures.

```console
jq -r '.value.candidate.content' tmp/candidate.json > tmp/agent.core.candidate.lisp
mix ptc.run evaluate.json --host-config repo-analyst.host.json \
    --mission tmp/candidate.json \
    --component-override agent.core=tmp/agent.core.candidate.lisp \
    --output tmp/evaluation.json
```

```json
{
  "candidate_sha256": "9f31c2…",
  "compiles": true,
  "motivating": { "improved": 3, "unchanged": 0, "regressed": 0 },
  "regression": { "improved": 0, "unchanged": 11, "regressed": 0 },
  "held_out":   { "improved": 2, "unchanged": 3, "regressed": 0 },
  "resources": "within-policy",
  "recommendation": "promote"
}
```

A candidate that fixed its cited cases while regressing held-out ones would be
rejected here, mechanically. And a `no-change` analysis is success, not
failure — continual code production is the failure mode.

### Decide

Nothing in either run could write to the live tree: proposing was a read-only
act, and a running bundle can never replace itself. A human — or a trusted CI
gate — reads `evaluation.json`, applies the patch, and runs the repository's
normal quality gates. Because both runs are plain `ptc.run` invocations with
file inputs and file outputs, a "self-improving agent" degenerates into a cron
job plus a review step — exactly the amount of magic it should have.

---

## What cannot happen

The parts of the tutorial you didn't have to think about, because the
platform already decided them:

| Attempt | Outcome |
|---------|---------|
| Manifest declares a `base_url`, command, or credential | Strict load rejects the unknown key before anything runs |
| Manifest selects a name the host never installed | `:unknown_provider` failure during assembly |
| Manifest widens `allow`, roots, or a ceiling | Assembly failure — selection can only narrow |
| A file changes after capture; a path traverses or crosses a symlink | The run observes the frozen snapshot; escapes are closed, denied classifications |
| A log line or source comment issues instructions | Data, not authority — there is no capability that could comply |
| The analysis run tries to apply its own candidate | Impossible — no write capability installed; bundles are immutable while running |
| A secret appears in a result, trace, error, or crash dump | Never — credentials exist only inside the per-request callback |

---

Simulated surface: Tracks A–F of
[`capability-platform-direction.md`](capability-platform-direction.md) and
Slices A–F of
[`manifest-authored-applications-direction.md`](manifest-authored-applications-direction.md),
rendered as shipped. The authoring test this page exists to feel out: *if you
have learned how one provider, one config block, or one prelude works, you can
guess how the next one works without reading new docs.*
