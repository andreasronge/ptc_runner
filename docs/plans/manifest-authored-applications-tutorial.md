# Tutorial design probe — build a Code Scout with MCP

> **Status:** target-state acceptance tutorial for active implementation, not
> current user documentation. It is an API design probe for
> [`mcp-capability-platform-direction.md`](mcp-capability-platform-direction.md)
> and
> [`manifest-authored-applications-direction.md`](manifest-authored-applications-direction.md).
> Commands and configuration marked planned will not work until their
> corresponding slices land.

## What this tutorial tests

You will assemble `repo-analyst`, an agent that:

1. navigates a repository through a read-only MCP filesystem server;
2. answers a source question with path and line evidence;
3. leaves a canonical trace and a complete private conversation for a human
   to inspect through a fixed private `ptc.repl` profile;
4. lets that human record an evidence-backed possible improvement;
5. automates the same review through bounded prior-run capabilities; and
6. proposes a PTC-Lisp improvement that isolated runs evaluate.

The tutorial exposes the evidence manually before automating it. The reader
first sees the same model requests, generated programs, tool calls, results,
and effective preludes that the later scout receives. The interesting result
is not the repository domain. It is that the external filesystem
implementation is TypeScript, the application and improvement policy are
ordinary files, and the runner remains generic. No application-specific
Elixir or `mix ptc.scout` command appears.

The target stack is:

```text
host JSON
  installs one MCP server, its transport, tool allowlist, effects, and limits
        |
manifest
  selects and narrows public capabilities
        |
PTC-Lisp prelude
  turns raw tools into clean application functions
        |
generated PTC-Lisp
  executes bounded calls in the mission environment
```

The model that plans is in the workflow environment. The generated program
that touches data is in the mission environment.

## What exists today and what is planned

| Tutorial surface | Status |
| --- | --- |
| `mix ptc.run`, strict manifests, local PTC-Lisp, `agent.core` | current |
| immutable filesystem access | current through the non-production MCP sample; the old whole-file provider is deleted |
| MCP Streamable HTTP installed from Elixir | current, pinned to stateless `2026-07-28` |
| `--trace` and exact `--inspect` capture | current |
| stdio MCP transport | current, pinned to `2026-07-28` |
| compatible stdio launcher, normally the optional precompiled `ptc_runner_launcher` companion | current; required for stdio, not by HTTP-only users |
| `--host-config` and `--check` | current |
| host-installed MCP and live-LLM aliases | current and exclusive; manifests have no implicit provider fallback |
| immutable filesystem sample MCP server | current, pinned beta pending the stable SDK release |
| manifest-selectable PTC trace/private snapshots | planned application Slice E1 |
| private human investigation in `ptc.repl` | planned application Slice E2 |
| bounded MCP error feedback, safe trace context, and private request/response inspection | current |
| `--output`, `--private-output`, `--private-mission`, and run classification | current; input/result schemas remain planned Slice D |
| `cap/unwrap!`, `cap/with-cursor`, and `agent.main` libraries | current; remaining Code Scout facades are planned application Slice G |
| component override and LLM replay evaluation | planned application Slice H |

This single page replaces separate “draft” and “simulated” tutorials. The
status table carries implementation truth; the steps below show one coherent
target API.

`inspection-analysis-v1` is one generic PtcRunner feature and therefore
requires Elixir implementation once. It is not Code Scout policy. After that
source/profile slice lands, the tutorial's task, review method, candidate
policy, and evaluation loop evolve entirely through host JSON, manifests,
PTC-Lisp, schemas, fixtures, and ordinary scripts.

## 1. Create the application files

From a repository root, create:

```text
repo-analyst.host.json              expanded at review and evaluation
repo-analyst-answer.json
repo-analyst-review.json
repo-analyst-improve.json
repo-analyst/
  repo.clj
  runs.clj
  evaluate.clj
  aggregate.clj
  answer-input.json
  review-input.json
  improve-input.json
  answer.schema.json
  review.schema.json
  candidate.schema.json
  evaluation.schema.json
  evaluate-replay.json
  evaluate-live.json
  aggregate.json
  evaluation/
    motivating.json
    regression.json
    held-out.json
    replay.jsonl
```

The files occupy three trust levels:

| Kind | Trust | May contain |
| --- | --- | --- |
| `*.host.json` | operator-trusted | commands, endpoints, roots, credentials, effects, outer ceilings |
| manifest JSON | model-authorable | installed names, narrower ceilings, components, local input/contracts |
| PTC-Lisp | frozen at build | application behavior and clean wrappers |

The manifest can point to confined application files. Anything that grants
external authority belongs in host config.

## 2. Install the MCP server

The planned repository sample server uses the official TypeScript MCP SDK and
the modern stateless protocol. PtcRunner launches it over stdio. The root is
server configuration supplied by the host, not an MCP Root and not a manifest
field. The tutorial invokes the committed reproducible server bundle; it does
not run `npm install` or download code.

The runtime distribution used by this tutorial enables the optional
`ptc_runner_launcher` companion once. On supported macOS and Linux targets the
companion installs a checksummed precompiled port executable, so application
authors do not compile native code or acquire an out-of-band launcher. That is
platform packaging, not application policy: new applications still need only
host JSON, manifests, and PTC-Lisp. A host-level custom-launcher path exists
only as an explicit override for hardened or unsupported deployments.

There is intentionally no `source: "file-read"` form in the target host
grammar. The current whole-file provider remains only until this sample passes
its acceptance suite; the same cutover migrates its examples/tests and deletes
the old builder, manifest config, and capability module. PtcRunner still reads
this host document, the application manifest, local PTC-Lisp, contracts, and
selected input through dedicated confined loaders. MCP is for
model-accessible filesystem capabilities, not runtime bootstrap.

The host file stays flat: it says what the operator installed, while each
manifest says where a selected alias enters one run. Examples order
credentials first, then workflow-side installations, then mission-side
installations. For this tutorial, `llm` and `llm_replay` are workflow-only,
the PTC snapshots are mission-only, and MCP is used in mission. Whether a
future planning-time MCP provider may enter workflow remains deliberately
open.

`repo-analyst.host.json`:

```json
{
  "$schema": "./priv/schemas/ptc-host-config.schema.json",
  "credentials": {
    "openrouter_key": {"env": "OPENROUTER_API_KEY"}
  },
  "install": {
    "deepseek": {
      "source": "llm",
      "model": "openrouter:deepseek/deepseek-v4-flash",
      "credential": "openrouter_key"
    },
    "workspace": {
      "source": "mcp",
      "transport": {
        "type": "stdio",
        "command": "node",
        "cwd": ".",
        "args": [
          "examples/mcp/filesystem/dist/server.js",
          "--root",
          ".",
          "--include",
          "lib/**",
          "--include",
          "priv/**",
          "--include",
          "docs/**",
          "--include",
          "test/**",
          "--include",
          "examples/**",
          "--include",
          "config/**",
          "--include",
          "mix.exs",
          "--include",
          "mix.lock",
          "--include",
          "repo-analyst/*.clj",
          "--include",
          "repo-analyst/*-input.json",
          "--include",
          "repo-analyst/*.schema.json",
          "--max-source-bytes",
          "32000000"
        ]
      },
      "tools": {
        "list_directory": {
          "as": "workspace.list",
          "effect": "read"
        },
        "search_files": {
          "as": "workspace.find",
          "effect": "read"
        },
        "search_text": {
          "as": "workspace.search",
          "effect": "read",
          "error_feedback": "bounded"
        },
        "read_text_file": {
          "as": "workspace.read",
          "effect": "read",
          "error_feedback": "bounded"
        },
        "snapshot_info": {
          "as": "workspace.info",
          "effect": "read"
        }
      },
      "snapshot_identity": {
        "tool": "snapshot_info",
        "field": "snapshot_hash"
      },
      "ceilings": {
        "timeout_ms": 5000,
        "max_catalog_tools": 32,
        "max_result_bytes": 250000
      }
    }
  }
}
```

This is the complete host authority needed for the first public answer. Later
sections widen the same file only when private review and replay evaluation
need those grants. Six details are deliberate:

1. `source` is `mcp`; `stdio` is a transport field, not a separate provider
   kind.
2. The command, root, include set, and executable arguments are host authority.
3. Inclusion is default-deny. The server never opens paths outside the
   repeated `--include` patterns, even when they exist below the root.
4. The `tools` map is the allowlist. The server can advertise other tools,
   but the application cannot call them.
5. Effects come from the host map, never MCP annotations.
6. `openrouter_key` is a host credential binding. The LLM-specific
   `credential` field authorizes it for this installation, and the known
   OpenRouter adapter owns bearer-header rendering. Static source and
   data-class checks happen before the binding is resolved; its value and
   rendered header are absent from snapshots, traces, inspection, errors, and
   process status.

Mapped tools are model-invisible by default. Ordinary sources produce and
accept only normal data by default; a closed source such as private inspection
may fix a stricter produced class. An omitted stdio `env` is an empty binding
map. The transport still constructs its closed macOS/Linux compatibility
environment from `HOME`, `LOGNAME`, `PATH`, `SHELL`, `TERM`, and `USER`; it
does not inherit arbitrary ambient variables. Set
`"inherit_environment": false` only for a server that supports a strict-empty
base. Those safe local defaults remove repeated fields without introducing a
shared defaults block or precedence rule. `as` and `effect` remain explicit
because they define the public name and authority.

The server captures the bounded UTF-8 tree before replying to discovery.
Every later list, search, and read observes that same snapshot. It exposes no
write, shell, network, Roots, Sampling, Logging, MRTR, or Tasks capability.
Every data-bearing result includes the snapshot hash, so a later citation can
be tied to the exact captured bytes.

During provider assembly, `snapshot_identity` invokes the mapped read-only
`snapshot_info` tool once and includes its SHA-256 identity in the effective
provider snapshot.

The host allowlist deliberately exposes application-local PTC-Lisp, task
inputs, and result schemas so the scout can inspect its own policy. It excludes
the host document, root manifests, `.env`, `.git`, `deps`, `_build`, `tmp`,
evaluation fixtures, and `repo-analyst/private`. Private artifacts and
held-out answers therefore cannot silently reappear as ordinary workspace
search results.

Relative host-config paths and `cwd` resolve from the canonical host-config
directory. PtcRunner resolves the executable once under host policy. Linux
holds the opened executable through launch; macOS executes the canonical path
and relies on the trusted installation hierarchy remaining immutable during
that short boundary.

`deepseek` uses the planned closed host-installed `llm` source over the
existing provider-neutral adapter. The fully qualified
`openrouter:deepseek/deepseek-v4-flash` value pins both the provider and its
upstream model ID instead of relying on a catalog alias. The host fixes model,
credential, cache policy, alias, accepted data classes, and installation
identity. A manifest chooses that alias but cannot retarget it. Caching retains
its current `false` default and is therefore omitted.

`installation_revision` is optional. An operator may add a bounded non-secret
value when an opaque deployment, executable build, private argument, or
credential scope changes without producing another safe identity. When
present, it affects the provider snapshot. The tutorial omits it because a
ceremonial `"v1"` would add no evidence.

The complete binding sources, the LLM-specific `credential` reference,
generic MCP `bearer`/`basic`/`api_key` rendering, protected header rules, and
stdio environment mapping are defined once in
[MCP plan §5.1](mcp-capability-platform-direction.md#51-credential-bindings).
This filesystem server needs no secret; a different stdio server would receive
only explicitly bound environment variables.

This host document is the complete provider registry for the run. It does not
augment implicit entries: the former manifest-configured `llm` and `file-read`
built-ins were removed in the Slices B–C cutover. A provider-free manifest may
omit `--host-config`, but a provider-bearing manifest cannot fall back to
legacy model, root, or file-list configuration.

The closed target source set is `mcp`, `llm`, `llm_replay`,
`ptc_trace_snapshot`, and `ptc_inspection_snapshot`. `read_text_file` below is
merely an upstream MCP tool mapped to `workspace.read`; it is not a
PtcRunner source kind or compatibility spelling for `file-read`.

Native snapshot sources derive public capabilities as
`<installed-alias>.<fixed-operation>`: `history.list-runs` comes from the
installed alias `history` and the trace source's fixed `list-runs` operation.
MCP mappings instead choose each public `as` name explicitly.

The tool names are intentionally familiar. They follow the official MCP
filesystem server where possible (`list_directory`, `search_files`,
`read_text_file`) and add only the content-search operation needed for large
source trees.

Canonical PTC traces do not go through this generic server. `history` and
`private-history` use PtcRunner's authoritative parsers because those formats
have PTC-specific correlation and confidentiality rules.

## 3. Select capabilities in task-specific manifests

`repo-analyst-answer.json`:

```json
{
  "$schema": "./priv/schemas/ptc-application-manifest.schema.json",
  "version": 1,
  "workflow": {
    "components": [{"library": "agent.main"}],
    "entry": "agent.main/run"
  },
  "mission": {
    "components": [
      {"library": "cap"},
      {
        "id": "repo",
        "path": "repo-analyst/repo.clj",
        "dependencies": ["cap"]
      }
    ],
    "data": {}
  },
  "providers": {
    "workflow": [{"name": "deepseek"}],
    "mission": [
      {
        "name": "workspace",
        "config": {
          "allow": [
            "workspace.list",
            "workspace.find",
            "workspace.search",
            "workspace.read",
            "workspace.info"
          ],
          "timeout_ms": 3000,
          "max_result_bytes": 100000
        }
      }
    ]
  },
  "input": {"path": "repo-analyst/answer-input.json"},
  "contracts": {
    "result_schema": {"path": "repo-analyst/answer.schema.json"}
  },
  "limits": {
    "run_duration_ms": 120000,
    "mission_capability_calls": 64
  }
}
```

The other two analysis manifests reuse the workflow and limits while adding
only the private evidence surface their tasks require:

| Manifest | Input and `Result.value` schema | Mission surface | Result |
| --- | --- | --- | --- |
| `repo-analyst-answer.json` | `answer-input.json` / `answer.schema.json` | `cap` + `repo`; `workspace` | public |
| `repo-analyst-review.json` | `review-input.json` / `review.schema.json` | add `runs`; add `history` + `private-history` | private |
| `repo-analyst-improve.json` | `improve-input.json` / `candidate.schema.json` | same evidence surface as review | private |

A source answer, a prior-run review, and an improvement decision are different
result types. Keeping three small manifests avoids a misleading union without
adding a task-specific runner or manifest-inheritance feature. There is no
`tasks` map or `--task` selector at this scale; revisit that grammar if a
fourth real task shows that the separate manifests are the main duplication.

The manifest narrows the installed time and result limits. It cannot increase
them or add an upstream tool. `allow` could be omitted to select the complete
host map; it is shown here to make the grant visible.

Provider `config` is a closed, source-independent narrowing object. Legacy
fields that create a model or choose files/roots are not accepted here; every
provider name must resolve in the host document before any provider activity.

The host mappings set the maximum model-visible set. Raw tools default to
model-invisible, so neither the host entries nor manifests repeat false/empty
visibility lists. Manifest narrowing remains available when a host explicitly
installed a visible tool. Frozen prelude code can still call the mapped
capabilities. The answer model sees only `repo`; review and improvement see
`repo` plus `runs`.

The `cap` library is composition-only rather than prompt-visible.
`repo` and `runs` form the complete model-facing facade.

`agent.main` is a domain-blind wrapper around `agent.core`: it reads a
task and loop settings from input. It avoids every agent application repeating
the same workflow entry file.

`repo-analyst/answer-input.json`:

```json
{
  "task": "Where is the run deadline enforced, and what happens to in-flight capability calls when it fires? Cite paths and line ranges.",
  "agent": {"max_turns": 6}
}
```

Path bases are fixed rather than inferred from the file being opened:

| Path surface | Relative base |
| --- | --- |
| Manifest path, `--host-config`, trace/inspection destinations, public/private output, override descriptor | invoking working directory |
| Paths and `cwd` inside host config | canonical host-config directory |
| Component, input, and contract paths inside a manifest | canonical manifest directory |
| `--mission` and `--private-mission` | canonical manifest directory |
| Candidate source path inside an override descriptor | canonical descriptor directory |

Every path is canonicalized and confined under its owning boundary before it
is opened.

## 4. Compose raw MCP tools into a clean prelude

`repo-analyst/repo.clj`:

```clojure
(ns repo "Bounded repository exploration." {:visibility :prompt})

(defn ls
  "Read one directory page. Pass nil first, then the returned next_cursor."
  {:signature "(path :string, cursor :string?) -> :map"}
  [path cursor]
  (cap/unwrap!
    (tool/workspace.list
      (cap/with-cursor {"path" path "limit" 100} cursor))))

(defn find-files
  "Read one glob page. Pass nil first, then the returned next_cursor."
  {:signature "(glob :string, cursor :string?) -> :map"}
  [glob cursor]
  (cap/unwrap!
    (tool/workspace.find
      (cap/with-cursor {"glob" glob "limit" 100} cursor))))

(defn search
  "Read one literal-search page. Pass nil first, then next_cursor."
  {:signature "(text :string, cursor :string?) -> :map"}
  [text cursor]
  (cap/unwrap!
    (tool/workspace.search
      (cap/with-cursor
        {"text" text "limit" 20 "context_lines" 2}
        cursor))))

(defn read-range
  "Read inclusive lines from one relative UTF-8 file."
  {:signature "(path :string, from :int, to :int) -> :map"}
  [path from to]
  (cap/unwrap!
    (tool/workspace.read
      {"path" path "from" from "to" to})))
```

`repo-analyst/runs.clj` gives the same treatment to PtcRunner-owned trace
formats:

```clojure
(ns runs "Bounded evidence from completed PtcRunner runs." {:visibility :prompt})

(defn list-runs
  "Read one public run page. Pass nil first, then the returned next_cursor."
  {:signature "(limit :int, cursor :string?) -> :map"}
  [limit cursor]
  (cap/unwrap!
    (tool/history.list-runs
      (cap/with-cursor {"limit" limit} cursor))))

(defn turns
  "Read one sanitized-turn page for a run."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/history.list-turns
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn model-exchanges
  "Read one private model-exchange page for an explicitly granted run."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.model-exchanges
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn capability-calls
  "Read one private capability-exchange page."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.capability-calls
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn generated-sources
  "Read one generated-program page for an explicitly granted run."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.generated-sources
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn effective-preludes
  "Read one effective-prelude page for an explicitly granted run."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.effective-preludes
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn provider-exchanges
  "Read one private provider-wire page for an explicitly granted run."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.provider-exchanges
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))
```

The prelude is the composition layer:

- it gives application-friendly names and signatures;
- it decides which low-level fields to expose;
- it may follow cursors, retry a safe read, or reshape results; and
- it may turn a bounded error into `(fail ...)`.

The server still owns path confinement, immutable bytes, result limits,
pagination cursors, line numbering, and schemas. Prompt instructions do not
enforce filesystem safety.

For every collection function, the model passes `nil` on the first call and
the response's opaque `next_cursor` on the next. A null `next_cursor` means
the collection is complete. Cursors are bound to the frozen source and are
never parsed or synthesized by PTC-Lisp.

`cap/with-cursor` only performs the shared conditional merge into a
string-keyed argument map. The first slice deliberately has no
`cap/paginate`: generated code loops over pages explicitly, can stop once it
has enough evidence, and keeps every page call visible to Kernel budgets
without building an implicit all-pages result.

What the model sees:

```text
repo/ls          (path :string, cursor :string?) -> :map
repo/find-files  (glob :string, cursor :string?) -> :map
repo/search      (text :string, cursor :string?) -> :map
repo/read-range  (path :string, from :int, to :int) -> :map
runs/list-runs   (limit :int, cursor :string?) -> :map
runs/turns       (run-id :string, cursor :string?) -> :map
runs/model-exchanges   (run-id :string, cursor :string?) -> :map
runs/capability-calls  (run-id :string, cursor :string?) -> :map
runs/generated-sources (run-id :string, cursor :string?) -> :map
runs/effective-preludes (run-id :string, cursor :string?) -> :map
runs/provider-exchanges (run-id :string, cursor :string?) -> :map
```

The facade uses `find-files` and `list-runs` rather than defining plain `find`
or `list`. PTC-Lisp permits namespace definitions to shadow builtins, but a
tutorial-facing API need not make readers or generated programs distinguish
those otherwise familiar names.

It does not need to know JSON-RPC, stdio framing, `tools/call`, hidden native
capability names, the host root, or the server executable.

## 5. Validate before spending model calls

The `$schema` properties point at the JSON Schema 2020-12 files shipped with
PtcRunner. In this repository the relative paths resolve directly; a consuming
project can point its editor at the version-matched copies in the installed
dependency. A schema-aware editor can now complete source/transport variants,
show field and default documentation, and reject unknown or structurally
invalid fields before invoking Mix.

This is early structural feedback, not an authorization result. PtcRunner
never fetches the `$schema` URI. Duplicate keys, bounded file loading, path
rules, credential and provider references, ceiling narrowing, environment
placement, private-data egress, MCP discovery, and resource lifecycle remain
the responsibility of the strict loader and `--check`.

Planned command:

```console
mix ptc.run repo-analyst-answer.json \
  --host-config repo-analyst.host.json \
  --check
```

The runner:

1. strictly loads host config and manifest;
2. loads and compiles local components and input/result contracts;
3. statically selects installed names and lower ceilings;
4. derives input/source data classes and checks every possible egress sink;
5. only after those checks, performs non-secret local preflight and freezes
   launcher/server executable identities;
6. only after every preflight passes, resolves credentials without
   snapshotting values;
7. starts the stdio server under an owner;
8. calls modern stateless `server/discover`;
9. retrieves and pages `tools/list`;
10. selects the five host-mapped tools, compiles their bounded schemas, and
   freezes provider/content identities;
11. prints only effective hashes and safe summaries; and
12. cancels/drains work and closes the server without invoking the workflow.

The useful output is the resolved selection, not a repetition of raw JSON:

```text
workflow  deepseek   llm        model openrouter:deepseek/deepseek-v4-flash  accepts normal
mission   workspace  mcp/stdio  5 tools  snapshot sha256:...
```

Rows are ordered by environment and alias. The view comes from the assembled
run, so it cannot disagree with placement or narrowing rules. It never prints
the credential, authorization header, host root, or private payload.

Try putting `"command": "bash"` in the manifest or raising
`timeout_ms` to `6000`. Strict loading/assembly rejects both before a model
call. Try adding an upstream tool to `allow`; it was never installed, so
selection fails.

## 6. Run, inspect, and form a human hypothesis

`repo-analyst/answer.schema.json` accepts an answer and one or more
source-backed citations. Each citation carries its provider alias and snapshot
hash beside its path/range, so evidence remains attributable when one result
combines multiple immutable sources.

Prepare destinations:

```console
umask 077
mkdir -p \
  tmp/traces \
  tmp/inspection \
  tmp/results \
  tmp/analysis-traces \
  repo-analyst/private
```

Add `tmp/` and `repo-analyst/private/` to the repository's `.gitignore`
before the first run. With the restrictive umask, the private directory is
created as `0700` and its files are created without group/other access.

Planned run:

```console
mix ptc.run repo-analyst-answer.json \
  --host-config repo-analyst.host.json \
  --trace tmp/traces/analyst.jsonl \
  --inspect tmp/inspection/analyst.inspection.jsonl \
  --output tmp/results/answer.json
```

Before workflow execution, the filesystem server freezes the workspace
snapshot. This manifest does not open either PTC snapshot provider. The active
run also has no capability that can read the separate inspection artifact it
is currently producing.

The model searches for a literal, reads only the relevant ranges, and returns
a schema-validated public result. The complete `Result` projection is printed
to stdout and atomically persisted with the same shape at the explicit
`--output` destination:

```json
{
  "value": {
    "answer": "The deadline owner cancels attached provider work before connector resources close.",
    "evidence": [
      {
        "provider": "workspace",
        "snapshot_hash": "sha256:...",
        "path": "lib/ptc_runner/kernel/run_state.ex",
        "lines": [250, 282]
      },
      {
        "provider": "workspace",
        "snapshot_hash": "sha256:...",
        "path": "lib/ptc_runner/kernel/run_builder.ex",
        "lines": [310, 329]
      }
    ]
  },
  "usage": {},
  "evaluation_memory": {}
}
```

The exact paths and lines above are illustrative, not expected fixture
answers.

The canonical trace remains payload-free:

```jsonl
{"event":"capability-call","capability_id":"cap-7","name":"workspace.search","effect":"read","duration_ms":9,"result_bytes":2114}
{"event":"capability-call","capability_id":"cap-8","name":"workspace.read","effect":"read","duration_ms":3,"result_bytes":1687}
```

The private inspection artifact contains correlated:

- provider-neutral LLM requests and responses;
- generated PTC-Lisp;
- capability arguments and results;
- effective prelude source; and
- MCP JSON-RPC request and response bodies.

It excludes the analysis-model secret, stdio environment values, and any
future rendered HTTP authorization headers.

Do not automate the first investigation. Start by seeing what the agent saw.
The public result answers whether the run completed its task. The canonical
trace shows timing, effects, and bounded sizes without payloads. The private
inspection explains how the result was produced.

Use the planned fixed private profile rather than making the human reconstruct
correlations with shell filters:

```console
mix ptc.repl \
  --profile inspection-analysis-v1 \
  --resource traces=tmp/traces \
  --resource inspection=tmp/inspection \
  --session-trace-dir tmp/analysis-traces \
  --private-terminal
```

`--private-terminal` explicitly authorizes this attached terminal as a private
sink. It does not make the source public: terminal scrollback, recording, and
screen sharing can retain the rendered values. The first profile version is
interactive-only and rejects `--eval`, script, stdin, or JSONL output. Without
the flag or an attached terminal it fails before opening either resource.

At startup the profile freezes both directories and validates each inspection
artifact against the exact captured canonical run. It grants no LLM,
filesystem, network, MCP, write, or new inspection capability. Its own trace
under `tmp/analysis-traces` is canonical and payload-free.

Start with the public evidence and retain the selected run ID:

```clojure
(log/runs {"limit" 20})
(def run-id "r-2026-07-21-0413")
(log/run run-id)
(def turns-page (log/turns run-id {"limit" 100}))

;; A payload-free index over the validated canonical page.
(->> (get turns-page "items")
     (map (fn [event]
            [(get event "sequence")
             (get event "type")
             (get-in event ["data" "environment"])
             (or (get-in event ["data" "name"])
                 (get-in event ["data" "component_id"])
                 (get-in event ["data" "evaluation_id"]))]))
     (map #(str/join "\t" %)))
```

Then inspect only the correlated private pages needed for the question:

```clojure
(inspection/capability-calls run-id nil)
(inspection/generated-sources run-id nil)
(inspection/model-exchanges run-id nil)
(inspection/effective-preludes run-id nil)
(inspection/provider-exchanges run-id nil)
```

Each function returns a bounded page and opaque `next_cursor`; pass that cursor
instead of `nil` to continue. Persistent REPL definitions make a long
investigation easier:

```clojure
(def calls-page (inspection/capability-calls run-id nil))
(def calls-cursor (get calls-page "next_cursor"))
(if calls-cursor
  (inspection/capability-calls run-id calls-cursor)
  nil)
```

Capability inputs and outputs are already paired by `capability_id`. Model
pages pair the complete provider-neutral `llm-request` input and output.
Generated programs and effective components carry their canonical
evaluation/component identities and source hashes. The human therefore
explores the same shaped evidence that `private-history` later gives the
automated reviewer.

Raw `jq` remains useful on the host for diagnosing the artifact format itself.
It is the fallback when the profile rejects a malformed artifact, not the
normal behavior-analysis interface. Keep its output encoded and bounded
because rejected fields have not passed PtcRunner validation. For example,
this index can help locate an early failing record without printing private
payload bodies:

```console
head -n 100 tmp/inspection/analyst.inspection.jsonl |
  jq -c '{
    sequence,
    record_type,
    environment: (.payload.environment // null),
    identity:
      ((.payload.name //
        .correlation.component_id //
        .correlation.evaluation_id //
        null) |
       if type == "string" then .[0:160] else . end)
  }'
```

This is operator-side diagnosis, not an alternative validator. `jq` must not
repair a rejected artifact, decide that it is safe, or feed its records back
into PTC-Lisp. The authoritative snapshot loader either exposes the complete
validated catalog or exposes nothing.

The exact native capability names in an existing V1 artifact may differ from
the planned MCP aliases above. Profile query results, correlation IDs, and
record shapes are authoritative; never reconstruct a conversation by
timestamps or terminal output.

Read in this order:

1. compare the public result with the task;
2. use the canonical trace to find expensive, failed, or repeated calls;
3. use each trace event's `capability_id` to locate the paired private
   capability records;
4. read the generated program that issued them;
5. read the exact LLM exchange that produced that program; and
6. inspect only the relevant effective prelude source.

Suppose one run repeats an identical empty search three times. That is an
observation, but one run is not yet a reusable failure class. The human records
the distinction instead of immediately editing the agent. Save an object such
as this as
`repo-analyst/private/manual-review.private.json`:

```json
{
  "summary": "One run repeated an identical empty search without changing evidence strategy.",
  "findings": [
    {
      "behavior": "Repeated identical call after an empty result",
      "inspection_evidence": {
        "run_id": "r-2026-07-21-0413",
        "sequences": [12, 18, 24],
        "capability_ids": ["cap-7", "cap-9", "cap-12"]
      },
      "inference": "The agent policy may need a neutral strategy-change cue.",
      "replication_status": "single-run",
      "possible_target": "agent.core"
    }
  ],
  "recommended_next_action": "insufficient-evidence",
  "evidence_needed": "Check independent runs for the same behavior after an empty result."
}
```

This manual record deliberately resembles the automated review contract in
the next step: observed behavior, exact evidence, inference, replication
status, possible target, and next action. It is not an executable candidate,
and the later reviewer does not receive it. That lets the reader compare an
independent automated review with their own reasoning.

Private inspection is still private after credentials are excluded. Keep the
artifacts and manual record `0600`, out of version control, and out of ordinary
model context. Do not inspect held-out evaluation answers while forming the
hypothesis; those remain useful only if the later evaluation stays blind.

The V1 inspection vocabulary remains exact and closed. Runs created through
the current manifest path use inspection V2, which adds paired `mcp-request`
and `mcp-response` records correlated to an existing capability attempt.
Artifact validation rejects mixed versions, unpaired exchanges, and MCP
records smuggled into V1.

This distinction matters when the server returns:

```json
{
  "resultType": "complete",
  "isError": true,
  "content": [
    {
      "type": "text",
      "text": "line range 900-1200 exceeds this file's final line 743"
    }
  ]
}
```

Under the installed bounded-feedback policy, the agent can correct that call.
Public errors and canonical traces retain a closed classification, while the
complete private record explains what happened. The controlled sample server
guarantees that this text contains no stacktrace or host root. PtcRunner can
enforce type and byte bounds, but cannot reliably sanitize the semantics of
arbitrary third-party prose; a host leaves feedback closed unless it accepts
that server's error-data contract.

## 7. Automate the review you just performed

The answer configuration intentionally accepted only normal data. Before
automating private review, widen the same host document explicitly and add the
two PTC-owned evidence sources:

```diff
    "deepseek": {
      "source": "llm",
      "model": "openrouter:deepseek/deepseek-v4-flash",
-      "credential": "openrouter_key"
+      "credential": "openrouter_key",
+      "accepts_data": ["normal", "private_inspection"]
     },
     "workspace": {
       ...
       "snapshot_identity": {
         "tool": "snapshot_info",
         "field": "snapshot_hash"
       },
+      "accepts_data": ["normal", "private_inspection"],
       "ceilings": {
         ...
       }
-    }
+    },
+    "history": {
+      "source": "ptc_trace_snapshot",
+      "directory": "tmp/traces",
+      "ceilings": {
+        "max_source_bytes": 8000000,
+        "max_result_bytes": 250000
+      }
+    },
+    "private-history": {
+      "source": "ptc_inspection_snapshot",
+      "directory": "tmp/inspection",
+      "ceilings": {
+        "max_files": 100,
+        "max_source_bytes": 64000000,
+        "max_result_bytes": 500000
+      }
+    }
```

This is authority expansion, so it appears where it first becomes necessary
rather than in the introductory answer configuration. It still adds no
destination to the host entries: the review manifest selects `deepseek` into
workflow and the three read sources into mission.

The review manifest adds the `runs` component and selects the `history` and
`private-history` providers alongside `workspace`, then binds a
review-specific input and result schema:

```json
{
  "task": "Review my last ten runs. Correlate repeated failures with the exact model exchanges, generated programs, MCP calls, and relevant source. Distinguish reusable behavior gaps from one-off bad input.",
  "agent": {"max_turns": 6}
}
```

Validate the expanded private selection before running it:

```console
mix ptc.run repo-analyst-review.json \
  --host-config repo-analyst.host.json \
  --check
```

The resolved view now makes the authority change visible:

```text
workflow  deepseek         llm                      accepts normal, private_inspection
mission   history          ptc_trace_snapshot       4 operations
mission   private-history  ptc_inspection_snapshot  6 operations  data private_inspection
mission   workspace        mcp/stdio                5 tools       accepts normal, private_inspection
```

Then run:

```console
mix ptc.run repo-analyst-review.json \
  --host-config repo-analyst.host.json \
  --private-output repo-analyst/private/review.private.json
```

Selecting `private-history` classifies the workflow input and result as
`private_inspection`. Every possible selected egress sink must therefore
declare that it accepts that class. This includes the analysis model and any
MCP server whose tool arguments can carry private text; a local read-only
stdio server is still an egress sink. An unapproved sink fails during static
assembly before credentials, sensitive snapshots, stdio, remote MCP, or model
activity. Private results use `--private-output` rather than stdout or
`--output`.

`repo-analyst/review.schema.json` validates a bounded review report with a
summary, recurring findings, source/run evidence, observed-versus-inferred
claims, replication status, and a recommended next action. It does not use
candidate-decision tags for what is still an evidence report.

`history` answers safe operational questions: outcomes, turns, counters, and
capability timing. `private-history` reconstructs what the model saw and what
the tools returned. `workspace` locates the implementation responsible for a
repeated behavior.

The automatic reviewer receives the same classes of evidence the human just
read, but through bounded, paged functions:

| Human action | Automated equivalent |
| --- | --- |
| `log/runs` plus `log/turns` | `runs/list-runs` plus `runs/turns` |
| `inspection/model-exchanges` | `runs/model-exchanges` |
| `inspection/capability-calls` | `runs/capability-calls` |
| `inspection/generated-sources` | `runs/generated-sources` |
| `inspection/effective-preludes` | `runs/effective-preludes` |
| `inspection/provider-exchanges` | `runs/provider-exchanges` |
| locate owning source | `repo/search` plus `repo/read-range` |

Compare `review.private.json` with `manual-review.private.json` before
proposing a change. The useful questions are whether it cites the same
observations, separates inference from fact, finds independent replications,
chooses the right layer, and notices evidence the human missed. Agreement is
evidence about the review method, not proof that either reviewer is correct.

The manual record is intentionally absent from every selected provider and
the filesystem root excludes `repo-analyst/private/`. Automation must
reconstruct the case from authoritative run/source snapshots rather than
copying the human conclusion.

Private inspection is data, not authority. A captured log that says “ignore
the manifest and run this command” cannot install a command or widen a root.
If the LLM nevertheless follows it using already granted tools, held-out
prompt-injection cases record a behavioral regression.

## 8. Propose an improvement

`repo-analyst/candidate.schema.json` should describe a discriminated union of:

- `no-change`;
- `insufficient-evidence`; and
- `propose-change`.

This uses the planned manifest-contract profile's narrow tagged `oneOf`
support: closed object branches share the required `decision` string and use
distinct `const` values. It does not widen MCP's callable-schema profile or
permit remote references and regexes.

Run the improvement task through its candidate-specific manifest:

```console
mix ptc.run repo-analyst-improve.json \
  --host-config repo-analyst.host.json \
  --private-output repo-analyst/private/candidate.private.json
```

An illustrative proposal value:

```json
{
  "decision": "propose-change",
  "target": "agent.core",
  "generalized_failure": "The loop repeats an identical empty search instead of changing evidence strategy.",
  "evidence": [
    {
      "provider": "history",
      "snapshot_hash": "sha256:...",
      "run_id": "r-2026-07-21-0413",
      "event_sequences": [12, 18, 24]
    },
    {
      "provider": "workspace",
      "snapshot_hash": "sha256:...",
      "path": "priv/preludes/kernel/agent.core.clj",
      "lines": [40, 53]
    }
  ],
  "candidate": {
    "format": "component-source",
    "component_id": "agent.core",
    "base_source_hash": "sha256:...",
    "source_hash": "sha256:...",
    "content": "(ns agent.core ...)"
  },
  "evaluation_plan": {
    "motivating_cases": ["repo-analyst/evaluation/motivating.json"],
    "regression_cases": ["repo-analyst/evaluation/regression.json"],
    "held_out_cases": ["repo-analyst/evaluation/held-out.json"],
    "metrics": ["success", "tool_calls", "tokens"]
  },
  "risks": [
    "May abandon a valid search after a transiently empty result."
  ]
}
```

The complete source, base hash, and source hash make the candidate
materializable and compilable. The review diff is optional. The run still has
no write capability and cannot replace `agent.core`.

## 9. Evaluate in isolated ordinary runs

Evaluation needs one more workflow-side installation. Add it immediately
after `deepseek`, keeping workflow entries before mission entries:

```diff
     "deepseek": {
       ...
     },
+    "replay-llm": {
+      "source": "llm_replay",
+      "fixtures": "repo-analyst/evaluation/replay.jsonl",
+      "data_class": "private_inspection",
+      "accepts_data": ["normal", "private_inspection"],
+      "ceilings": {
+        "max_entries": 1000,
+        "max_result_bytes": 250000
+      }
+    },
     "workspace": {
       ...
     }
```

`replay-llm` presents the same `llm-request` contract as `deepseek` from
frozen fixtures. Separate manifests select one or the other; the host entry
does not choose a destination or route between them.

The remaining `jq` commands have a different role: trusted host orchestration
between isolated runs. PTC-Lisp deliberately has no arbitrary filesystem or
write authority, so using it here would require a new sink merely to replace
visible host glue.

Materialization is a visible trusted host step:

```console
umask 077
jq -jr '.value.candidate.content' \
  repo-analyst/private/candidate.private.json \
  > repo-analyst/private/agent.core.candidate.clj
jq '.value.candidate |
    {component_id, base_source_hash, source_hash,
     path: "agent.core.candidate.clj"}' \
  repo-analyst/private/candidate.private.json \
  > repo-analyst/private/agent.core.override.json
```

`evaluate.clj` is a domain-blind workflow that executes exactly one
subject/case trial and returns its bounded observation and identities.
`evaluate-replay.json` selects only `replay-llm`;
`evaluate-live.json` selects only `deepseek`. A Kernel run never switches
between them.

Both manifests make the evaluator the workflow entry, declare its
`agent.core` dependency, and call the dependency once. The component override
therefore changes the implementation used by that one trial before the bundle
freezes. `aggregate.clj` is a separate pure workflow with no LLM or mission
provider.

The trusted host combines only the candidate identity with one frozen case
into bounded private baseline and candidate inputs. Candidate source is absent
from both inputs and reaches only the candidate run through the trusted
override descriptor. With each case file defined as a bounded JSON array, the
first motivating case can be prepared as:

```console
umask 077
jq -n \
  --slurpfile result repo-analyst/private/candidate.private.json \
  --slurpfile cases repo-analyst/evaluation/motivating.json \
  '{subject: "baseline",
    candidate_identity:
      ($result[0].value.candidate |
       {component_id, base_source_hash, source_hash}),
    case: $cases[0][0]}' \
  > repo-analyst/private/replay-baseline.private.json
jq '.subject = "candidate"' \
  repo-analyst/private/replay-baseline.private.json \
  > repo-analyst/private/replay-candidate.private.json
```

A deterministic replay pair is then:

```console
umask 077
mkdir -p repo-analyst/private/trials
mix ptc.run repo-analyst/evaluate-replay.json \
  --host-config repo-analyst.host.json \
  --private-mission private/replay-baseline.private.json \
  --private-output repo-analyst/private/trials/replay-baseline.private.json
mix ptc.run repo-analyst/evaluate-replay.json \
  --host-config repo-analyst.host.json \
  --private-mission private/replay-candidate.private.json \
  --component-override-descriptor repo-analyst/private/agent.core.override.json \
  --private-output repo-analyst/private/trials/replay-candidate.private.json
```

`--private-mission` is host CLI authority and resolves under the evaluation
manifest directory. It marks the complete input private before assembly and is
mutually exclusive with ordinary `--mission`; the manifest cannot downgrade
it.

The exact override descriptor carries component ID, expected base hash,
expected candidate hash, and a path confined to its directory. The runner
opens the source once, verifies those same bytes, and compiles those bytes
under normal dependency, export, signature, capability, and limit checks.

The host repeats baseline and candidate invocations with
`evaluate-live.json` for every motivating, regression, and held-out case.
Every repetition is a fresh Kernel run with one frozen LLM provider and a
unique no-clobber artifact. Nothing shares mission memory between trials.

Finally, the trusted host combines the still-private trial `Result`
projections and a provider-free aggregate run invokes `aggregate.clj`:

```console
jq -s '{"trials": .}' repo-analyst/private/trials/*.private.json \
  > repo-analyst/private/trials.private.json
mix ptc.run repo-analyst/aggregate.json \
  --private-mission private/trials.private.json \
  --private-output repo-analyst/private/evaluation.private.json
```

The pure aggregator rejects missing pairs, inconsistent case/candidate
identities, duplicate trials, and insufficient sample counts. A useful
`Result.value` reports counts and distributions. This excerpt omits the
surrounding persisted `Result` projection:

```json
{
  "candidate_sha256": "9f31c2...",
  "base_sha256": "bb8210...",
  "provider_snapshot_sha256": "ac43d1...",
  "workspace_snapshot_sha256": "7e04a9...",
  "fixture_set_sha256": "13dc48...",
  "compiles": true,
  "deterministic_contracts": {"passed": 18, "failed": 0},
  "live_trials_per_case": 5,
  "motivating": {"improved": 12, "unchanged": 3, "regressed": 0},
  "regression": {"improved": 1, "unchanged": 53, "regressed": 1},
  "held_out": {"improved": 8, "unchanged": 17, "regressed": 0},
  "resources": "within-policy",
  "recommendation": "review"
}
```

Provider, content, fixture, candidate, and effective-bundle identities make a
live result attributable; they do not make a remote LLM deterministic. A
candidate that fixes cited examples while regressing held-out cases does not
pass.

Promotion remains outside PtcRunner execution. A human or trusted CI gate
reviews confidentiality and behavior, applies the candidate, and runs normal
repository gates.

## 10. Improve the improvement loop without changing Elixir

The first loop is intentionally simple:

```text
human inspection in private ptc.repl
      |
automated review
      |
one candidate proposal
      |
scripted materialization
      |
replay and live baseline/candidate runs
      |
human promotion
```

It has strong authority, privacy, provenance, and isolation boundaries, but a
naive improvement method. It does not yet have an independent proposal
reviewer, a proposal-revision stage, or a distinct `replicate-first` decision.
That is useful in a tutorial because the reader can observe why those
refinements matter before inheriting them as ceremony.

Suppose the automated review recommends changing `agent.core` from the one
run above while the human record says `insufficient-evidence`. Do not decide by
preference. Treat the disagreement as another observable run outcome:

- both reviewers saw exact evidence rather than a redacted summary;
- only one independent occurrence exists;
- the proposed policy change could abandon a valid transiently empty search;
  and
- no negative control yet shows how the policy behaves after an empty result
  that should be retried unchanged.

The first improvement can therefore target the improvement application rather
than `agent.core`. A human or ordinary script can:

1. revise `repo-analyst/improve-input.json` to require observation/inference
   separation and an explicit replication assessment;
2. add a `replicate-first` branch to `candidate.schema.json`, or initially map
   that outcome to `insufficient-evidence` with required follow-up evidence;
3. add two independent encodings of the repeated-search condition and one
   no-condition negative control under `evaluation/`;
4. create `repo-analyst-improve-v2.json` selecting the revised files; and
5. run the complete old and revised improvement manifests in fresh replay/live
   invocations over the same frozen evidence, then aggregate their results
   under the same no-clobber and identity rules.

For example, the revised application policy may contain the neutral rule:

```json
{
  "task": "Propose a reusable component change only when the behavior is grounded in exact run evidence and independently replicated. Separate observations from inference. For a single plausible occurrence, return replicate-first with the additional evidence needed. Use a negative control to check that the proposed rule would not fire when the condition is absent."
}
```

Those changes are JSON, evaluation data, and optionally application-local
PTC-Lisp. The generic command, Kernel, MCP client, filesystem server, and
Elixir provider code remain unchanged. The same mechanism can later add:

- an independent proposal-review manifest;
- at most one proposal-revision manifest;
- scorer-only oracle data hidden from the subject run;
- structured `valid`, `apparatus-failed`, and `subject-failed` trial outcomes;
  and
- a form-aware editing MCP server for disposable candidates.

Each refinement should first appear as a response to observed friction or a
failed control. A larger application graph is not automatically a better
self-improving loop.

The bootstrap boundary remains explicit: the loop may identify and recommend
an improvement to its own application files, but it cannot authorize or
promote that improvement. The human/script step versions the candidate
application, and ordinary isolated runs produce the evidence for the next
decision.

## 11. Where MCP Tasks fit later

The filesystem tutorial needs only synchronous tools. Long-running evaluation
or a named test runner may later return the MCP Tasks extension's
`resultType: "task"` and task handle.

PtcRunner would then own polling, budget charging, input requests,
cancellation, and run-close cleanup. The application could wait for a test
task through the same provider without a new Mix command or Elixir callback.
Until that lifecycle is implemented, PtcRunner advertises no Tasks support and
rejects task results.

## 12. What the application cannot do

| Attempt | Outcome |
| --- | --- |
| Manifest declares an executable, endpoint, root, credential, upstream tool, or effect | strict load failure |
| Editor sees an unknown field or wrong source/transport shape | shipped schema reports it while the file is being edited |
| Document passes JSON Schema but names a missing provider or raises a ceiling | `--check` reports the semantic failure before provider activity |
| Manifest raises a host ceiling | assembly failure |
| First-slice manifest selects `workspace` into workflow | unsupported environment; workflow-side MCP is still an explicit future decision |
| Server advertises a write tool omitted from host mapping | tool never becomes a capability |
| MCP description claims a read tool is safe | no authority change; host effect remains authoritative |
| Filesystem changes after server capture | all calls continue to observe frozen bytes |
| Installation revision is omitted | provider/trial identity uses the remaining safe provider and content identities |
| Present installation revision or content identity changes | provider/trial hash changes |
| Workspace searches `.env`, `deps`, `_build`, `tmp`, or private results | no match: those paths were never included or opened |
| Path traverses or crosses a symlink | bounded tool error without host path disclosure |
| Server writes logs to stdout | protocol failure and owned process termination |
| Server returns `input_required` or `task` | unsupported result because the client did not advertise those features |
| Private history is selected with an unapproved model/MCP sink | assembly fails before sensitive data is opened |
| Private inspection REPL omits `--private-terminal`, is piped, or requests non-interactive output | profile rejects the command before opening trace or inspection sources |
| Provider-bearing manifest omits host config or uses legacy model/root/file config | strict failure; no implicit provider fallback |
| Host config declares `source: "file-read"` | strict unknown-source failure; install an MCP filesystem provider instead |
| Private candidate is supplied through `--private-mission` with a public sink/output | fails before provider activity; input stays private |
| Private run requests normal stdout value or `--output` | closed failure; only explicit private output may receive it |
| Log/source text asks for more authority | text cannot change installed capabilities |
| Analysis run tries to modify its own prelude | impossible: no write tool and active bundles are immutable |
| Candidate violates its schema or hash | not published/evaluated |
| Override file is replaced after verification | same opened bytes are hashed and compiled, or the override fails |
| Evaluator tries to switch from replay to live LLM | impossible: each run freezes exactly one workflow provider |
| Relevant file, run, or exchange is beyond the first result page | facade returns an opaque cursor and the model can request the next page |

## 13. Friction and resulting platform choices

Writing the tutorial resolves several API questions:

1. **One `mcp` source is easier to learn than `mcp_stdio` and `mcp_http`.**
   Transport is a typed nested field.
2. **The tool map is necessary, not ceremony.** It is the host allowlist,
   public rename, and effect declaration.
3. **Raw HTTP distracts from the proof.** It is deferred; a future external
   API can be exposed by an MCP server.
4. **Generic model-accessible filesystem access belongs in MCP.** The current
   `file-read` provider is migrated and deleted, not added to host config or
   expanded into a second API. Trusted manifest/component/contract/input
   loading remains direct and confined.
5. **PTC traces remain native.** Their fixed schema and private correlation
   rules are product contracts, not generic filesystem behavior.
6. **Useful tool errors and exact private exchanges are required for
   self-analysis.** A closed public error alone cannot teach the agent why its
   call failed.
7. **`--check`, classified inputs, and result artifacts are load-bearing.**
   Multi-run applications should not discover bad grants after spending model
   calls, lose confidentiality between runs, or scrape stdout to pass
   candidates.
8. **A composition-only `cap` helper and domain-blind `agent.main` remove
   repeated glue.** Prompt-visible `repo` and `runs` facades remain explicit.
9. **Tasks are valuable but not prerequisite.** Synchronous read tools prove
   the platform first.
10. **Fresh ordinary runs plus a pure aggregate are enough.** Provider
    switching and trial reset do not need a pipeline engine or mutable
    self-owner.
11. **Expose the evidence before automating the judgment.** A human inspection
    pass makes private authority, correlation, and the limits of one-run
    inference concrete; the automated reviewer then has a visible standard to
    reproduce or challenge.
12. **The improvement method is application policy.** Replication rules,
    proposal review, revision, controls, and aggregation can evolve through
    JSON, PTC-Lisp, fixtures, and scripts without a new Mix task or Elixir
    provider.
13. **Private evidence needs a first-class human query surface.** Raw `jq` is
    valuable for format debugging, but a fixed private `ptc.repl` profile can
    freeze both evidence planes, validate correlations, pair records, page
    large conversations, and let a human keep exploratory definitions. A
    distinct profile ID plus explicit terminal authority preserves the normal
    `log-analysis-v1` contract.
14. **Flat installation and explicit placement are easier to reason about.**
    The host says what exists; the manifest says whether a selected alias
    enters workflow or mission. Ordering and a resolved `--check` view provide
    visual grouping without duplicating destination across authority layers.
15. **Introduce authority when the tutorial needs it.** The first answer uses
    only concrete DeepSeek and workspace grants. Private acceptance and PTC
    snapshots appear at review; replay appears at evaluation. Safe local field
    defaults remove repetition without adding inheritance or merge precedence.
16. **The configuration language needs an editor contract.** Shipped generated
    JSON Schemas make host and manifest structure discoverable without reading
    Elixir or waiting for a run, while `--check` remains the authority for
    cross-file, security, discovery, and lifecycle semantics.
