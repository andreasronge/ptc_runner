# Tutorial draft — your first manifest-authored application

> **Status:** design probe, not documentation. This is what the end-user
> tutorial *would* look like if the capability-platform and
> manifest-authored-applications directions land as written. Its purpose is to
> feel the API from the author's chair and surface friction early. Steps are
> tagged **[today]** (runs against current `main`) or **[proposed: …]**
> (references the track/slice that would make it real). Appendix A lists the
> friction this draft surfaced — that appendix is the actual deliverable.

## What you will build

`repo-analyst` — an agent that answers questions about a repository with cited
evidence. You grow it in six steps:

1. a hello-world workflow (no model, no providers);
2. an agent loop with a granted file;
3. bounded repository search and ranged reads;
4. an external HTTP API with a credential;
5. reading its own past run traces; and
6. a two-run improvement loop: propose a change, evaluate it, decide.

At no point do you write Elixir, register a provider in code, or add a Mix
task. Everything is JSON, PTC-Lisp, and `mix ptc.run`.

## The three files you will always see

Every application in this tutorial is at most three kinds of file:

| File | Trust | Contains |
|------|-------|----------|
| `*.host.json` | operator-trusted | endpoints, commands, local roots, credentials, ceilings |
| `*.json` (manifest) | model-authorable | which installed names to use, narrowed limits, components, input |
| `*.lisp` | frozen at build | behavior: wrappers, policy, the agent's tools-as-functions |

The rule that makes the split predictable: **the manifest may only point
inside its own directory; anything that points elsewhere — a URL, a command,
a repository root, a secret — lives in host config.** You will not need host
config until step 3.

---

## Step 1 — Hello, workflow **[today]**

Create a directory with two files.

`ptc.json`:

```json
{
  "version": 1,
  "workflow": {
    "components": [{"id": "analyst.workflow", "path": "workflow.lisp"}],
    "entry": "analyst.workflow/run"
  },
  "input": {"value": {"question": "hello"}}
}
```

`workflow.lisp`:

```clojure
(ns analyst.workflow "Entry point." {:visibility :prompt})

(defn run [input]
  {"echo" (get input "question")})
```

Run it:

```console
mix ptc.run ptc.json
```

The Kernel compiles the bundle, calls `(analyst.workflow/run data/input)`, and
prints the public result as JSON. No model was involved; a manifest without an
`llm` provider is a deterministic program.

## Step 2 — An agent loop with a granted file **[today]**

Replace the workflow body with the shipped agent loop and grant one bounded
file root. The mission component turns the raw capability into a clean,
signed function the model can call.

`ptc.json` grows three sections:

```json
{
  "version": 1,
  "workflow": {
    "components": [
      {"id": "analyst.workflow", "path": "workflow.lisp", "dependencies": ["agent.core"]},
      {"library": "agent.core"}
    ],
    "entry": "analyst.workflow/run"
  },
  "mission": {
    "components": [{"id": "analyst.files", "path": "files.lisp"}],
    "data": {}
  },
  "input": {"value": {"question": "Summarize notes/brief.txt"}},
  "providers": {
    "workflow": [{"name": "llm", "config": {"model": "deepseek", "cache": false}}],
    "mission":  [{"name": "file-read", "config": {"root": "notes", "max_bytes": 65536}}]
  }
}
```

`workflow.lisp`:

```clojure
(ns analyst.workflow "Agent entry point." {:visibility :prompt})

(defn run [input]
  (agent.core/run (get input "question") {"max_turns" 4}))
```

`files.lisp`:

```clojure
(ns analyst.files "Mission access to the granted file root." {:visibility :prompt})

(defn read-text
  "Read one UTF-8 file beneath the granted root."
  {:signature "(path :string) -> :string"}
  [path]
  (let [response (tool/fs-read {"path" path})]
    (if (= :ok (get response :status))
      (get-in response [:value "content"])
      (fail response))))
```

Note the placement rule you just used without thinking about it: `llm` is a
**workflow** provider, file access is a **mission** provider. The model that
plans is never the environment that touches data.

## Step 3 — Repository search and ranged reads **[proposed: Slices A + B]**

Whole-file reads stop scaling the moment the agent must *find* things. The
repository snapshot provider adds three primitives — list, search, ranged
read — over one immutable capture taken before the run starts.

A repository root is authority outside the manifest directory, so this is
where host config first appears.

`repo-analyst.host.json`:

```json
{
  "credentials": {},
  "install": {
    "workspace": {
      "source": "repository_snapshot",
      "root": "..",
      "include": ["lib/**", "docs/**", "test/**"],
      "exclude": ["docs/plans/**"],
      "ceilings": {"max_entries": 12000, "max_result_bytes": 250000}
    }
  }
}
```

A native provider has a fixed shape, so its three operations surface under
predictable default names — `workspace.list`, `workspace.search`,
`workspace.read` — with `effect: read`. (An explicit `tools` map with `as`
renames stays available, and stays *mandatory* for discovery-based sources
like MCP, where the map is the allowlist.)

The manifest selects the installed provider by name. Selection can only
narrow — it cannot add a root, widen the include set, or raise a ceiling:

```json
"providers": {
  "workflow": [{"name": "llm", "config": {"model": "deepseek", "cache": false}}],
  "mission":  [{"name": "workspace"}]
}
```

Omitting `allow` exposes everything the host installed for that provider —
safe, because the host already froze the outer bound. Write
`{"name": "workspace", "config": {"allow": ["workspace.search", "workspace.read"]}}`
when you want less.

`repo.lisp`, the mission wrapper the model actually sees:

```clojure
(ns repo "Bounded repository exploration." {:visibility :prompt})

(defn search
  "Literal text search. Returns matches with path and line evidence."
  {:signature "(text :string) -> :map"}
  [text]
  (cap/unwrap! (tool/workspace.search {"text" text "limit" 20})))

(defn read-range
  "Read lines [from, to] of one file with stable line numbers."
  {:signature "(path :string, from :int, to :int) -> :map"}
  [path from to]
  (cap/unwrap! (tool/workspace.read {"path" path "from" from "to" to})))
```

`cap/unwrap!` is the blessed helper for the ubiquitous
"`:ok` → value, otherwise `(fail response)`" pattern from step 2.

Run with both files:

```console
mix ptc.run repo-analyst.json --host-config repo-analyst.host.json
```

Ask `"Where is the run deadline enforced, and what happens when it fires?"`
and the agent can now search for the literal, read the surrounding range, and
answer with `path:line` citations — without a prelisted answer and without
loading whole files into context.

Everything is frozen before execution: edit a file mid-run and the run keeps
observing the capture. Symlinks, traversal, and absolute paths are closed off
by the provider, not by prompt instructions.

## Step 4 — An external API with a credential **[proposed: Tracks A + D]**

The same host-config grammar installs remote providers; only the
`source` fields change. Add a second provider and a credential binding:

```json
{
  "credentials": {
    "api_key": {"env": "EXAMPLE_API_KEY"}
  },
  "install": {
    "workspace": { "source": "repository_snapshot", "...": "as above" },
    "registry": {
      "source": "http_get",
      "base_url": "https://api.example.org",
      "auth": [{"scheme": "bearer", "binding": "api_key"}],
      "ceilings": {"timeout_ms": 5000, "max_result_bytes": 200000}
    }
  }
}
```

The manifest adds `{"name": "registry"}` to its mission providers, and a
prelude turns the raw GET into a named function — pagination and shaping live
here, in Lisp, not in the runtime:

```clojure
(ns registry "Package registry lookups." {:visibility :prompt})

(defn latest-version
  "Latest published version of one package."
  {:signature "(package :string) -> :string"}
  [package]
  (let [body (cap/unwrap! (http/get "registry" {:path (str "/packages/" package)}))]
    (get body "latest")))
```

The key never appears in the manifest, the prelude, the trace, or an error.
The model sees `registry/latest-version`; it cannot see or choose the host.

An MCP server is the same shape with `"source": "mcp_stdio"`, a `command`
instead of a `base_url`, and a mandatory `tools` allowlist — learn one column
of the grammar and you have learned them all.

## Step 5 — Reading its own past runs **[proposed: Slice C]**

Give every run a trace, and install the trace directory as a provider:

```console
mix ptc.run repo-analyst.json --host-config repo-analyst.host.json \
  --trace tmp/traces/analyst.jsonl
```

```json
"history": {
  "source": "ptc_trace_snapshot",
  "directory": "tmp/traces",
  "ceilings": {"max_source_bytes": 8000000, "max_result_bytes": 250000}
}
```

The manifest selects `history` as a mission provider and the agent can now
ask operational questions about itself: which past runs failed, which
capability calls dominated, where turns were wasted. The trace queries are
the existing canonical, sanitized ones — traces carry no prompt text and no
instruction authority. A log line that says "ignore your instructions" is
evidence to classify, not a command.

## Step 6 — Close the loop: propose, evaluate, decide **[proposed: Slices D + F]**

Self-improvement here is deliberately boring: it is **two ordinary runs and a
human decision**, composed with nothing fancier than the shell.

**Run 1 — analyze.** The analyst mission reads failed traces (step 5) and the
sources they implicate (step 3), and returns a structured decision as its
terminal result — `no-change` and `insufficient-evidence` are first-class
outcomes, not failures. `--output` persists exactly the public result,
atomically, no clobber:

```console
mix ptc.run repo-analyst.json --host-config repo-analyst.host.json \
  --trace tmp/traces/analyst.jsonl --output tmp/candidate.json
```

```json
{
  "decision": "propose-change",
  "target": "priv/preludes/kernel/agent.core.lisp",
  "evidence": [
    {"run_id": "…", "event_sequences": [12, 18]},
    {"path": "priv/preludes/kernel/agent.core.lisp", "lines": [70, 96]}
  ],
  "candidate": {"format": "component-source", "content": "…"},
  "risks": ["…"]
}
```

**Run 2 — evaluate.** A second, generic manifest takes the candidate artifact
as its mission input and runs motivating, regression, and held-out cases under
fixed limits:

```console
mix ptc.run evaluate.json --host-config repo-analyst.host.json \
  --mission tmp/candidate.json --output tmp/evaluation.json
```

The evaluator compiles the candidate under the same bundle contracts as
production and reports evidence — improved, regressed, unchanged, per corpus —
never a promotion side effect. A candidate that fixes its cited cases while
regressing held-out cases is rejected here, mechanically.

**Decide.** A human (or trusted CI gate) reads `evaluation.json`, applies the
change, and runs the repository's normal quality gates. Nothing in either run
could write to the live tree; proposing was a read-only act, and the running
bundle could never replace itself.

Because both runs are plain `ptc.run` invocations with file inputs and file
outputs, "a self-improving agent" degenerates into a cron job plus a review
step — which is exactly the amount of magic it should have.

---

## Appendix A — Friction this draft surfaced

The point of the exercise. Ordered by how much each would improve the
tutorial, cheapest-relative-to-value first.

> **Update (2026-07-22):** all items below were adopted into the two
> direction documents; their wording is authoritative. The host-config
> top-level key is now `install` (item 4), and this draft's examples use it.

1. **`allow` should be optional (default: everything installed).** Narrowing
   is the manifest's only power, so allow-all is never an escalation. Today's
   proposed grammar makes the author name every tool three times: host `as`,
   manifest `allow`, prelude wrapper. Step 3 reads much better with
   `{"name": "workspace"}`.
2. **Default tool names for fixed-shape native providers.** A
   `repository_snapshot` always has exactly list/search/read; requiring the
   `tools` map there is ceremony. Keep the map mandatory where it is the
   security allowlist (MCP, OpenAPI discovery) and derive
   `<provider>.<op>` defaults elsewhere.
3. **Ship `cap/unwrap!` (and a blessed `cap/paginate`).** Every wrapper in
   every step repeats the `:status`-check-or-`fail` dance. One shared helper
   removes four lines from every function the tutorial shows, and answers
   capability-direction open question 6 with "yes".
4. **`providers` means two different shapes.** Host config: a map of
   name → installation. Manifest: per-destination lists of selections. Same
   word, both files, different grammar — the single most likely tutorial
   confusion. Since 0.x allows breaking changes, consider renaming one (e.g.
   host `providers` → `install`, or manifest `providers` → `select`).
5. **Name-style collision: `fs-read` vs `workspace.search`.** Existing
   built-ins use hyphens, the direction docs use dots. Pick one convention
   (dots, per P8) and rename the built-ins before Slice B multiplies names.
6. **A shipped `agent.main` would delete step 2's `workflow.lisp`.** Nearly
   every agent app writes the same four-line entry that forwards input to
   `agent.core/run`. A generic installed library (task and config read from
   input, domain-blind) makes the smallest real agent = manifest + mission
   prelude, no workflow file. Zero new grammar — it is just a library.
7. **`--output` is load-bearing, not a convenience.** Every multi-run story
   (step 6, any evaluation pipeline, any cron) needs it; scraping stdout is
   the alternative. Land Slice D before, not after, the snapshot providers.
8. **Front-load Track F ergonomics.** A rendered `(tool/NAME {...})` example
   per capability and list-valid-names on unknown-name errors are what let the
   tutorial *not* explain calling conventions defensively — the model
   self-corrects instead.
9. **Candidate materialization needs one trusted channel.** Step 6's
   evaluation run must compile the candidate under real bundle contracts
   (Slice F's open decision). The smallest generic shape may be a runner-level
   override — e.g. `--component-override analyst.workflow=tmp/candidate.lisp`
   — trusted, explicit, auditable, and no new capability kind. Now recorded
   in the direction doc (V.3) as the recommended shape; the final decision
   gate stays at Slice F.
10. **The workflow/mission provider split needs its one-liner early.** It is
    the architecture's best idea and the tutorial's biggest up-front concept.
    "The model that plans is never the environment that touches data" carried
    step 2; some version of that sentence belongs in every doc's first page.
