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
3. studies canonical traces and complete private conversations from prior
   runs; and
4. proposes a PTC-Lisp improvement that a second run evaluates.

The interesting result is not the repository domain. It is that the external
filesystem implementation is TypeScript, the application behavior is
PTC-Lisp, and the runner remains generic. No application-specific Elixir or
`mix ptc.scout` command appears.

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
| immutable whole-file `file-read` | current only; deleted at the MCP filesystem cutover and never added to host config |
| MCP Streamable HTTP installed from Elixir | current, pinned to sessionful `2025-11-25` |
| `--trace` and exact `--inspect` capture | current |
| stateless MCP `2026-07-28` and stdio | planned MCP Slices 1–2 |
| `--host-config` and `--check` | planned MCP Slice 3 |
| host-installed aliases replacing manifest-configured providers | planned application Slices B–C; filesystem access uses `source: "mcp"` |
| immutable filesystem sample MCP server | planned MCP Slice 5 |
| manifest-selectable PTC trace/private snapshots | planned application Slice D |
| private MCP request/response inspection | planned MCP Slice 4 |
| result schemas, `--output`, `--private-output`, `--private-mission` | planned application Slice F |
| `cap/unwrap!` and `agent.main` libraries | planned application Slice G |
| component override and LLM replay evaluation | planned application Slice H |

This single page replaces separate “draft” and “simulated” tutorials. The
status table carries implementation truth; the steps below show one coherent
target API.

## 1. Create the application files

From a repository root, create:

```text
repo-analyst.host.json
repo-analyst.json
repo-analyst/
  repo.clj
  runs.clj
  evaluate.clj
  aggregate.clj
  input.json
  review-input.json
  improve-input.json
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
field.

There is intentionally no `source: "file-read"` form in the target host
grammar. The current whole-file provider remains only until this sample passes
its acceptance suite; the same cutover migrates its examples/tests and deletes
the old builder, manifest config, and capability module. PtcRunner still reads
this host document, the application manifest, local PTC-Lisp, contracts, and
selected input through dedicated confined loaders. MCP is for
model-accessible filesystem capabilities, not runtime bootstrap.

`repo-analyst.host.json`:

```json
{
  "credentials": {
    "analysis_llm_key": {"env": "ANALYSIS_LLM_API_KEY"}
  },
  "install": {
    "analysis-llm": {
      "source": "llm",
      "installation_revision": "analysis-model-profile-v1",
      "model": "operator-approved-model",
      "auth": [{"scheme": "bearer", "binding": "analysis_llm_key"}],
      "accepts_data": ["normal", "private_inspection"]
    },
    "workspace": {
      "source": "mcp",
      "installation_revision": "filesystem-sample-v1",
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
          "--max-source-bytes",
          "32000000"
        ],
        "env": {}
      },
      "tools": {
        "list_directory": {
          "as": "workspace.list",
          "effect": "read",
          "model_visible": false
        },
        "search_files": {
          "as": "workspace.find",
          "effect": "read",
          "model_visible": false
        },
        "search_text": {
          "as": "workspace.search",
          "effect": "read",
          "model_visible": false,
          "error_feedback": "bounded"
        },
        "read_text_file": {
          "as": "workspace.read",
          "effect": "read",
          "model_visible": false,
          "error_feedback": "bounded"
        },
        "snapshot_info": {
          "as": "workspace.info",
          "effect": "read",
          "model_visible": false
        }
      },
      "snapshot_identity": {
        "tool": "snapshot_info",
        "field": "snapshot_hash"
      },
      "accepts_data": ["normal", "private_inspection"],
      "ceilings": {
        "timeout_ms": 5000,
        "max_catalog_tools": 32,
        "max_result_bytes": 250000
      }
    },
    "history": {
      "source": "ptc_trace_snapshot",
      "directory": "tmp/traces",
      "ceilings": {
        "max_source_bytes": 8000000,
        "max_result_bytes": 250000
      }
    },
    "private-history": {
      "source": "ptc_inspection_snapshot",
      "directory": "tmp/inspection",
      "ceilings": {
        "max_files": 100,
        "max_source_bytes": 64000000,
        "max_result_bytes": 500000
      }
    },
    "replay-llm": {
      "source": "llm_replay",
      "installation_revision": "replay-fixtures-v1",
      "fixtures": "repo-analyst/evaluation/replay.jsonl",
      "data_class": "private_inspection",
      "accepts_data": ["normal", "private_inspection"],
      "ceilings": {
        "max_entries": 1000,
        "max_result_bytes": 250000
      }
    }
  }
}
```

Seven details are deliberate:

1. `source` is `mcp`; `stdio` is a transport field, not a separate provider
   kind.
2. `installation_revision` is a non-secret host identity that changes whenever
   behavior-defining installation details change.
3. The command, root, include set, and executable arguments are host authority.
4. Inclusion is default-deny. The server never opens paths outside the
   repeated `--include` patterns, even when they exist below the root.
5. The `tools` map is the allowlist. The server can advertise other tools,
   but the application cannot call them.
6. Effects come from the host map, never MCP annotations.
7. Exact private trace text may influence a filesystem search term, so the
   local MCP process is still conservatively treated as a possible egress
   sink and explicitly approved for that data class.

The server captures the bounded UTF-8 tree before replying to discovery.
Every later list, search, and read observes that same snapshot. It exposes no
write, shell, network, Roots, Sampling, Logging, MRTR, or Tasks capability.
Every data-bearing result includes the snapshot hash, so a later citation can
be tied to the exact captured bytes.

During provider assembly, `snapshot_identity` invokes the mapped read-only
`snapshot_info` tool once and includes its SHA-256 identity, alongside the
installation-revision hash, in the effective provider snapshot.

The host allowlist deliberately excludes `.env`, `.git`, `deps`, `_build`,
`tmp`, the evaluation fixtures, and `repo-analyst/private`. Private artifacts
therefore cannot silently reappear as ordinary workspace search results.

Relative host-config paths and `cwd` resolve from the canonical host-config
directory. PtcRunner resolves the executable once under host policy and
freezes the canonical target before spawning it.

`analysis-llm` uses the planned closed host-installed `llm` source over the
existing provider-neutral adapter. The host fixes model, credential, cache
policy, alias, accepted data classes, and installation revision. A manifest
chooses that alias but cannot retarget it. `replay-llm` presents the same
`llm-request` contract from frozen fixtures; separate evaluation manifests
choose one provider per run.

This host document is the complete provider registry for the run. It does not
augment implicitly installed `llm` or `file-read` entries: those
manifest-configured built-ins are removed when the Slices B–C filesystem
cutover lands. A provider-free manifest may omit `--host-config`, but a
provider-bearing manifest cannot fall back to legacy model, root, or file-list
configuration.

The closed target source set is `mcp`, `llm`, `llm_replay`,
`ptc_trace_snapshot`, and `ptc_inspection_snapshot`. `read_text_file` below is
merely an upstream MCP tool mapped to `workspace.read`; it is not a
PtcRunner source kind or compatibility spelling for `file-read`.

The tool names are intentionally familiar. They follow the official MCP
filesystem server where possible (`list_directory`, `search_files`,
`read_text_file`) and add only the content-search operation needed for large
source trees.

Canonical PTC traces do not go through this generic server. `history` and
`private-history` use PtcRunner's authoritative parsers because those formats
have PTC-specific correlation and confidentiality rules.

## 3. Select capabilities in the manifest

`repo-analyst.json`:

```json
{
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
      },
      {
        "id": "runs",
        "path": "repo-analyst/runs.clj",
        "dependencies": ["cap"]
      }
    ],
    "data": {}
  },
  "providers": {
    "workflow": [{"name": "analysis-llm"}],
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
          "model_visible": [],
          "timeout_ms": 3000,
          "max_result_bytes": 100000
        }
      },
      {"name": "history", "config": {"model_visible": []}},
      {"name": "private-history", "config": {"model_visible": []}}
    ]
  },
  "input": {"path": "repo-analyst/input.json"},
  "contracts": {
    "result_schema": {"path": "repo-analyst/candidate.schema.json"}
  },
  "limits": {
    "run_duration_ms": 120000,
    "mission_capability_calls": 64
  }
}
```

The manifest narrows the installed time and result limits. It cannot increase
them or add an upstream tool. `allow` could be omitted to select the complete
host map; it is shown here to make the grant visible.

Provider `config` is a closed, source-independent narrowing object. Legacy
fields that create a model or choose files/roots are not accepted here; every
provider name must resolve in the host document before any provider activity.

The host mappings set the maximum model-visible set. Their value is already
`false`; the manifest's explicit `model_visible: []` documents the same
narrowing and could never widen it. Frozen prelude code can still call the raw
capabilities. The model sees the smaller `repo`/`runs` API in the next step.

The planned `cap` library is composition-only rather than prompt-visible.
`repo` and `runs` form the complete model-facing facade.

`agent.main` is a planned domain-blind wrapper around `agent.core`: it reads a
task and loop settings from input. It avoids every agent application repeating
the same workflow entry file.

`repo-analyst/input.json`:

```json
{
  "task": "Where is the run deadline enforced, and what happens to in-flight capability calls when it fires? Cite paths and line ranges.",
  "agent": {"max_turns": 6}
}
```

## 4. Compose raw MCP tools into a clean prelude

`repo-analyst/repo.clj`:

```clojure
(ns repo "Bounded repository exploration." {:visibility :prompt})

(defn- with-cursor [arguments cursor]
  (merge arguments (if cursor {"cursor" cursor} {})))

(defn ls
  "Read one directory page. Pass nil first, then the returned next_cursor."
  {:signature "(path :string, cursor :string?) -> :map"}
  [path cursor]
  (cap/unwrap!
    (tool/workspace.list
      (with-cursor {"path" path "limit" 100} cursor))))

(defn find
  "Read one glob page. Pass nil first, then the returned next_cursor."
  {:signature "(glob :string, cursor :string?) -> :map"}
  [glob cursor]
  (cap/unwrap!
    (tool/workspace.find
      (with-cursor {"glob" glob "limit" 100} cursor))))

(defn search
  "Read one literal-search page. Pass nil first, then next_cursor."
  {:signature "(text :string, cursor :string?) -> :map"}
  [text cursor]
  (cap/unwrap!
    (tool/workspace.search
      (with-cursor
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

(defn- with-cursor [arguments cursor]
  (merge arguments (if cursor {"cursor" cursor} {})))

(defn list
  "Read one public run page. Pass nil first, then the returned next_cursor."
  {:signature "(limit :int, cursor :string?) -> :map"}
  [limit cursor]
  (cap/unwrap!
    (tool/history.list-runs
      (with-cursor {"limit" limit} cursor))))

(defn turns
  "Read one sanitized-turn page for a run."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/history.list-turns
      (with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn model-exchanges
  "Read one private model-exchange page for an explicitly granted run."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.model-exchanges
      (with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn capability-calls
  "Read one private capability-exchange page."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.capability-calls
      (with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn generated-sources
  "Read one generated-program page for an explicitly granted run."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.generated-sources
      (with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn effective-preludes
  "Read one effective-prelude page for an explicitly granted run."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.effective-preludes
      (with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn provider-exchanges
  "Read one private provider-wire page for an explicitly granted run."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.provider-exchanges
      (with-cursor {"run_id" run-id "limit" 100} cursor))))
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

What the model sees:

```text
repo/ls          (path :string, cursor :string?) -> :map
repo/find        (glob :string, cursor :string?) -> :map
repo/search      (text :string, cursor :string?) -> :map
repo/read-range  (path :string, from :int, to :int) -> :map
runs/list        (limit :int, cursor :string?) -> :map
runs/turns       (run-id :string, cursor :string?) -> :map
runs/model-exchanges   (run-id :string, cursor :string?) -> :map
runs/capability-calls  (run-id :string, cursor :string?) -> :map
runs/generated-sources (run-id :string, cursor :string?) -> :map
runs/effective-preludes (run-id :string, cursor :string?) -> :map
runs/provider-exchanges (run-id :string, cursor :string?) -> :map
```

It does not need to know JSON-RPC, stdio framing, `tools/call`, hidden native
capability names, the host root, or the server executable.

## 5. Validate before spending model calls

Planned command:

```console
mix ptc.run repo-analyst.json \
  --host-config repo-analyst.host.json \
  --check
```

The runner:

1. strictly loads host config and manifest;
2. loads and compiles local components and input/result contracts;
3. statically selects installed names and lower ceilings;
4. derives input/source data classes and checks every possible egress sink;
5. only after those checks, resolves credentials without snapshotting values;
6. starts the stdio server under an owner;
7. calls modern stateless `server/discover`;
8. retrieves and pages `tools/list`;
9. selects the five host-mapped tools, compiles their bounded schemas, and
   freezes provider/content identities;
10. prints only effective hashes and safe summaries; and
11. cancels/drains work and closes the server without invoking the workflow.

An unapproved private-data sink fails during step 4: before credentials,
sensitive snapshots, stdio, remote MCP, or model activity.

Try putting `"command": "bash"` in the manifest or raising
`timeout_ms` to `6000`. Strict loading/assembly rejects both before a model
call. Try adding an upstream tool to `allow`; it was never installed, so
selection fails.

## 6. Run and inspect the MCP path

Prepare destinations:

```console
umask 077
mkdir -p tmp/traces tmp/inspection repo-analyst/private
```

Planned run:

```console
mix ptc.run repo-analyst.json \
  --host-config repo-analyst.host.json \
  --trace tmp/traces/analyst.jsonl \
  --inspect tmp/inspection/analyst.inspection.jsonl \
  --private-output repo-analyst/private/answer.private.json
```

Before workflow execution, the server and both PTC snapshot providers freeze
their inputs. The active run cannot read the inspection artifact it is
currently producing.

The model searches for a literal, reads only the relevant ranges, and returns
a schema-validated result. Because this manifest selects private history,
stdout reports status without the value. The complete `Result` projection is
created atomically at the explicit `0600` destination:

```json
{
  "value": {
    "decision": "no-change",
    "answer": "The deadline owner cancels attached provider work before connector resources close.",
    "workspace_snapshot_hash": "sha256:...",
    "evidence": [
      {
        "path": "lib/ptc_runner/kernel/run_state.ex",
        "lines": [250, 282]
      },
      {
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
{"event":"capability-call","name":"workspace.search","effect":"read","duration_ms":9,"result_bytes":2114}
{"event":"capability-call","name":"workspace.read","effect":"read","duration_ms":3,"result_bytes":1687}
```

The private inspection artifact contains correlated:

- provider-neutral LLM requests and responses;
- generated PTC-Lisp;
- capability arguments and results;
- effective prelude source; and
- MCP JSON-RPC request and response bodies.

It excludes the analysis-model secret, stdio environment values, and any
future rendered HTTP authorization headers.

The existing V1 inspection vocabulary is exact and closed. MCP wire exchange
records therefore require a new inspection artifact version rather than
unrecognized record types added to V1.

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

## 7. Study complete prior runs

Change only the input:

```json
{
  "task": "Review my last ten runs. Correlate repeated failures with the exact model exchanges, generated programs, MCP calls, and relevant source. Distinguish reusable behavior gaps from one-off bad input.",
  "agent": {"max_turns": 6}
}
```

Then run:

```console
mix ptc.run repo-analyst.json \
  --host-config repo-analyst.host.json \
  --mission repo-analyst/review-input.json \
  --private-output repo-analyst/private/review.private.json
```

`history` answers safe operational questions: outcomes, turns, counters, and
capability timing. `private-history` reconstructs what the model saw and what
the tools returned. `workspace` locates the implementation responsible for a
repeated behavior.

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

Run the improvement input through the same manifest:

```console
mix ptc.run repo-analyst.json \
  --host-config repo-analyst.host.json \
  --mission repo-analyst/improve-input.json \
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
      "run_id": "r-2026-07-21-0413",
      "event_sequences": [12, 18, 24]
    },
    {
      "path": "priv/preludes/kernel/agent.core.clj",
      "lines": [40, 53],
      "snapshot_hash": "sha256:..."
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

Materialization is a visible trusted step:

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
`evaluate-live.json` selects only `analysis-llm`. A Kernel run never switches
between them.

Both manifests make the evaluator the workflow entry, declare its
`agent.core` dependency, and call the dependency once. The component override
therefore changes the implementation used by that one trial before the bundle
freezes. `aggregate.clj` is a separate pure workflow with no LLM or mission
provider.

The host combines only the candidate identity with one frozen case into
bounded private baseline and candidate inputs. Candidate source is absent
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

Finally, the host combines the still-private trial `Result` projections and a
provider-free aggregate run invokes `aggregate.clj`:

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
  "installation_revision_sha256": "ac43d1...",
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

## 10. Where MCP Tasks fit later

The filesystem tutorial needs only synchronous tools. Long-running evaluation
or a named test runner may later return the MCP Tasks extension's
`resultType: "task"` and task handle.

PtcRunner would then own polling, budget charging, input requests,
cancellation, and run-close cleanup. The application could wait for a test
task through the same provider without a new Mix command or Elixir callback.
Until that lifecycle is implemented, PtcRunner advertises no Tasks support and
rejects task results.

## 11. What the application cannot do

| Attempt | Outcome |
| --- | --- |
| Manifest declares an executable, endpoint, root, credential, upstream tool, or effect | strict load failure |
| Manifest raises a host ceiling | assembly failure |
| Server advertises a write tool omitted from host mapping | tool never becomes a capability |
| MCP description claims a read tool is safe | no authority change; host effect remains authoritative |
| Filesystem changes after server capture | all calls continue to observe frozen bytes |
| Installation revision or content identity changes | provider/trial hash changes |
| Workspace searches `.env`, `deps`, `_build`, `tmp`, or private results | no match: those paths were never included or opened |
| Path traverses or crosses a symlink | bounded tool error without host path disclosure |
| Server writes logs to stdout | protocol failure and owned process termination |
| Server returns `input_required` or `task` | unsupported result because the client did not advertise those features |
| Private history is selected with an unapproved model/MCP sink | assembly fails before sensitive data is opened |
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

## 12. Friction and resulting platform choices

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
