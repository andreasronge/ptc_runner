# Manifest-authored applications — implementation plan

> **Status:** active implementation plan, promoted from `future/` on
> 2026-07-24. This document describes the generic runner and application
> contracts built on the MCP-first capability platform. Every API shown below
> remains planned unless explicitly described as current behavior.

## 1. Goal

Keep `mix ptc.run` as the generic top-level runner while making this authoring
test pass:

> Once PtcRunner implements MCP and a small set of PTC-specific local sources,
> an application author can add a substantial task using host configuration, a
> manifest, PTC-Lisp, and data. They do not add an Elixir module, edit
> `ProviderRegistry`, or create a task-specific Mix command.

A repository Code Scout is the proving application. It must navigate unknown
nested files, analyze canonical traces and explicitly granted private
conversations, propose a prelude improvement as inert data, and evaluate that
candidate in a separate run. The Kernel must never acquire `scout`,
`repository`, or `self-improvement` policy.

This direction depends on
[`mcp-capability-platform-direction.md`](mcp-capability-platform-direction.md):
MCP is the generic integration mechanism, stdio is the first local transport,
and host JSON is the trusted installation channel. This document adds the
generic application and artifact behavior around it.

## 2. Scope

In scope:

- one generic `mix ptc.run` application path;
- host-owned, data-driven MCP installation;
- a non-production read-only filesystem MCP server for the tutorial;
- PtcRunner-owned canonical trace and private inspection snapshots;
- local PTC-Lisp application components and preludes;
- bounded input, candidate, and evaluation contracts;
- public and private result artifacts;
- proposal, evaluation, and explicit promotion as separate phases; and
- a read-only Code Scout acceptance application.

Out of scope:

- `mix ptc.scout` or another domain-specific frontend;
- a raw HTTP/OpenAPI provider in the first platform;
- an ambient shell capability;
- arbitrary modules, commands, endpoints, roots, or credentials in a manifest;
- allowing a run to replace its own active bundle;
- automatic promotion of generated code;
- a second PTC trace/inspection parser in the sample MCP server;
- detailed agent planning/reflection policy; and
- a promise that entirely new protocol primitives never require PtcRunner
  changes. The no-Elixir promise applies to new applications assembled from
  installed generic capabilities.

## 3. Verified current state

| Surface | Current behavior | Missing for this direction |
| --- | --- | --- |
| `mix ptc.run` | Loads one strict manifest and runs it through `RunBuilder` | host config, validation-only assembly, result artifact options |
| Local components | Loads confined PTC-Lisp files and declared dependencies | no application-specific runtime work required |
| `agent.core` | Supplies the provider/evaluation loop | a small generic entry wrapper would remove repeated workflow boilerplate |
| Provider registry | Built-ins are `llm` and `file-read`; extra builders require Elixir | closed host JSON installation |
| `file-read` | Freezes a directory but reads one whole already-known UTF-8 path | temporary current behavior; migrate to MCP filesystem tools and delete it rather than adding it to host config |
| MCP | Trusted Elixir can install a read-only sessionful HTTP source | modern stateless protocol, stdio, host JSON |
| Canonical trace | `TraceSnapshot` and `TraceCapability` provide four bounded queries in a fixed analysis profile | ordinary manifest-selectable source |
| Private inspection | `--inspect` writes exact provider-neutral model, source, and capability records to a bounded `0600` artifact | ordinary explicitly classified snapshot source and MCP wire records |
| Terminal output | Prints public `Result`; trace and inspection persist separately | atomic public/private result artifacts and result schema |
| Bundle lifecycle | Bundles compile and freeze before execution | already prevents in-place self-replacement |

The missing feature is not a task framework. It is the ability to install
bounded MCP servers and PTC-specific snapshots through trusted data, then pass
typed artifacts between ordinary runs.

## 4. Design decisions

### 4.1 One runner, application names in files

The complete application runs through:

```console
umask 077
mkdir -p code-scout/private tmp
mix ptc.run code-scout.json \
  --host-config code-scout.host.json \
  --mission code-scout/input.json \
  --private-output code-scout/private/candidate.private.json \
  --trace tmp/code-scout-trace.jsonl
```

Generic options may know about manifests, host installation, validation,
classified outputs, traces, inspection, and trusted component overrides. They
must not know that the application is a scout.

Planned validation:

```console
mix ptc.run code-scout.json \
  --host-config code-scout.host.json \
  --check
```

`--check` strictly loads components and contracts and performs static
data-class/egress compatibility before provider activity. It then assembles
providers, performs MCP discovery, emits only bounded redacted hashes, and
closes every resource. It invokes neither the workflow entry nor an LLM. After
the static phase succeeds, it is deliberately allowed to start a configured
stdio server or contact a configured remote MCP endpoint.

### 4.2 The authority ladder remains visible

| Layer | Owns | Code Scout example |
| --- | --- | --- |
| Host config | authority and outer ceilings | MCP executable/args, filesystem root, trace directories, credentials, tool effects |
| Manifest | selection and narrowing | which public workspace/history tools enter the mission, lower quotas |
| PTC-Lisp | application behavior | search strategy, evidence collection, candidate/evaluation policy |
| Generated program | one bounded action sequence | calls `repo/search`, `repo/read-range`, and trace queries |

The manifest cannot contain an MCP command, remote endpoint, filesystem root,
credential, or effect. It can only select names installed by the host.

Host installation replaces the current implicit provider registry; it does not
augment it. When the combined Slices B–C cutover lands, manifests can no
longer instantiate the legacy `llm` or `file-read` built-ins by supplying
provider-specific config. Every selected provider name must come from the
host document. A provider-free manifest, such as the pure aggregate run
below, may omit host config. Existing manifests, examples, and tests move to
installed aliases; legacy model, root, and file lists are rejected rather
than retained as a fallback path.

That is the target contract, activated only when the filesystem MCP server and
its migration are ready. `file-read` is not made host-configurable during the
transition. Slices B and C form one release gate: host installation can be
built first, but the public registry cutover, example migration, and deletion
of `FileCapability` land together after the MCP filesystem acceptance suite
passes.

Inside a manifest, the workflow/mission split stays central:

> The model that plans is in the workflow environment; the generated program
> that touches data is in the mission environment.

### 4.3 MCP provides generic external tools

Do not add a native `repository_snapshot` provider. Repository access is a
filesystem capability, not a PtcRunner data format. The sample MCP server
proves that a server written outside Elixir can provide:

- nested directory listing;
- path/glob discovery;
- literal text search with line evidence;
- bounded ranged UTF-8 reads; and
- a deterministic snapshot identity.

The current `file-read` provider is not the seed of this API. It is a
temporary whole-file capability removed at the filesystem MCP cutover. In
particular, the host grammar never accepts `source: "file-read"`, its legacy
root/file configuration is not translated into a compatibility shape, and
the target runtime has no second public filesystem path.

Trusted platform loading remains direct and confined. PtcRunner does not use
MCP to read the host document, manifest, local component sources, contracts,
or selected input artifacts. Those are run-construction inputs, not
filesystem capabilities available to generated programs. An MCP tool named
`read_text_file` is therefore not the legacy PtcRunner provider.

The same MCP client later connects Git, GitHub, databases, test runners, or a
production filesystem server. Application-specific wrappers and search policy
remain PTC-Lisp.

### 4.4 PTC-owned formats keep native snapshot sources

Canonical trace and private inspection are different. PtcRunner owns their
schemas, correlation rules, redaction boundary, versioning, and exact query
semantics. They remain dedicated local source kinds:

- `ptc_trace_snapshot`
- `ptc_inspection_snapshot`

Both produce ordinary capabilities through the same provider build contract,
but they do not go through MCP merely for architectural symmetry. The existing
`TraceSnapshot`, `TraceCapability`, `TraceLog`, and `InspectionArtifact`
implementations remain authoritative.

An external trace MCP server may be useful later for foreign traces or remote
storage. It is not allowed to become a second parser for PtcRunner's canonical
formats.

### 4.5 Freeze evidence before model activity

The filesystem MCP sample captures its root before discovery completes.
Native trace and inspection providers capture their directories before the
workflow starts. Every operation for one provider queries the same captured
representation.

Changing a file or artifact during the run cannot change evidence. Traversal,
symlinks, replacement, aliases, oversized inputs, malformed records, and
invalid UTF-8 fail under provider-owned rules, not prompt instructions.

This is a proving-server constraint, not a claim that every MCP server is
immutable. Host configuration and provider metadata must state when an MCP
source is live. Applications requiring reproducible evidence should select
only servers whose installed contract supplies a stable snapshot.

### 4.6 Logs, source, and tool output are untrusted data

Repository text, issues, CI logs, trace payloads, MCP results, and MCP tool
errors never gain instruction authority. The host freezes authority; a string
cannot add a tool, change an effect, widen a root, or approve egress.

An LLM can still follow a malicious instruction embedded in data. That is a
behavioral failure measured by held-out cases, not something a prompt can make
impossible. System prompts and agent libraries remain domain-blind; fixture
answers and benchmark patterns stay in evaluation data.

### 4.7 Exact diagnostics are explicit private authority

Canonical traces intentionally omit prompts, responses, generated source,
capability payloads, and MCP bodies. Behavioral diagnosis uses a separately
requested private inspection artifact.

The planned private snapshot exposes bounded queries over:

- exact provider-neutral LLM requests and results;
- generated and effective PTC-Lisp source;
- capability inputs and outputs; and
- correlated MCP JSON-RPC request/response bodies, without credentials or
  rendered authorization headers.

Selecting `ptc_inspection_snapshot` gives generated code access to private
application data. Assembly therefore treats every selected remote or write
provider, including the workflow LLM and any MCP server, as a possible egress
sink. Each must be host-installed and explicitly accept
`private_inspection`. The manifest cannot change that declaration.

Terminal publication is also a sink. A private run suppresses its value on
stdout, cannot use normal `--output`, and requires an explicit no-clobber
`0600` private result.

A later run preserves that class through a planned trusted
`--private-mission PATH` option. It is mutually exclusive with `--mission`,
uses the same bounded manifest-confined JSON loading rules, and marks the
entire input `private_inspection` before provider assembly. That classification
forces static sink compatibility and private-only publication; neither the
manifest nor input content can lower it. Deliberate declassification is a
separate trusted host transformation followed by ordinary `--mission`, not a
field inside the artifact.

This is a coarse run-level information-flow rule, not dynamic taint tracking
for arbitrary Lisp values.

### 4.8 Improvement means propose, evaluate, promote

A running program never mutates its active bundle:

```text
frozen repository + traces + private inspection
                       |
                       v
                 analysis run
                       |
               candidate artifact
                       |
                       v
        isolated baseline/candidate runs
                       |
              private trial artifacts
                       |
                       v
                aggregate run
                       |
              evaluation evidence
                       |
                       v
          explicit human/host promotion
```

`no-change` and `insufficient-evidence` are successful decisions. Producing
code on every run is a failure mode.

## 5. Application package

The example application may live inside the repository it analyzes:

```text
code-scout.host.json             trusted installation
code-scout.json                  selection, components, limits, contracts
code-scout/
  repo.clj                       MCP filesystem wrappers
  runs.clj                       trace/private-inspection wrappers
  evaluate.clj                   exactly one isolated evaluation trial
  aggregate.clj                  pure aggregation of trial artifacts
  input.json                     one task
  candidate.schema.json          Result.value contract
  evaluation.schema.json         aggregate Result.value contract
  evaluate-replay.json           one replay-backed trial
  evaluate-live.json             one live-model trial
  aggregate.json                 provider-free result aggregation
  evaluation/
    motivating.json
    regression.json
    held-out.json
    replay.jsonl
```

No file registers an Elixir callback. Host JSON can instantiate only source
and transport kinds built into the installed PtcRunner release.
`code-scout/private/` is a generated `0700` host-artifact directory, not a
versioned application input and not part of the filesystem MCP include set.

The initial closed source identifiers are `mcp`, `llm`, `llm_replay`,
`ptc_trace_snapshot`, and `ptc_inspection_snapshot`. `file-read` is
deliberately absent. The `workspace` installation below uses `source: "mcp"`;
its alias and upstream `read_text_file` tool do not create another source
kind.

## 6. Planned host installation

Illustrative target configuration:

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
      "fixtures": "code-scout/evaluation/replay.jsonl",
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

The filesystem root is an argument to a trusted installed command. The
manifest never sees or changes it. The configured `cwd` and path fields in
host config resolve relative to the canonical host-config directory unless a
source explicitly requires an absolute operator path. The executable is
resolved once under host policy and frozen before spawn.

The repeated `--include` arguments are a default-deny host allowlist, not
search hints. The sample server does not open or inventory anything else.
Consequently `.env`, `.git`, `deps`, `_build`, `tmp`, replay fixtures, and the
generated private-result directory remain outside ordinary workspace data.

The stdio child receives an explicit allowlisted environment. Erlang Port
`{env, ...}` extends the ambient environment and is not by itself a clean
environment guarantee, so implementation needs a reviewed launcher and
process-group ownership.

`workspace.tools` is mandatory because it is the security allowlist and effect
classification. The sample server may advertise additional tools; PtcRunner
does not expose them.

There are no implicitly installed `llm` or `file-read` names alongside this
document. The host document is the complete provider registry for the run.
This prevents a manifest from bypassing an operator-installed alias by falling
back to the current manifest-configured built-ins.

There is also no host-configurable `file-read` source. At the cutover, current
whole-file examples move to the filesystem MCP server and the old builder,
manifest schema, and capability module are deleted. PtcRunner's dedicated
loaders for its own configuration and artifacts are unaffected.

`llm` is another closed host-installable source owned by the generic
application platform, not by MCP. It wraps the existing provider-neutral LLM
adapter and emits exactly the standard workflow `llm-request` capability.
Host config owns model ID, credential binding, cache policy, accepted data
classes, installation revision, and the provider alias (`analysis-llm` here).
A manifest may select that alias and lower generic ceilings; it cannot change
the model, credential, cache policy, or identity. `llm_replay` emits the same
capability contract from frozen fixtures, so a run chooses one or the other at
assembly rather than switching providers while executing. Both safe snapshots
include the installation-revision hash; replay additionally includes the
fixture-set hash, while a live LLM snapshot includes the effective model and
non-secret request-policy identity.

## 7. Planned manifest

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
      {"id": "repo", "path": "code-scout/repo.clj", "dependencies": ["cap"]},
      {"id": "runs", "path": "code-scout/runs.clj", "dependencies": ["cap"]}
    ],
    "data": {}
  },
  "providers": {
    "workflow": [{"name": "analysis-llm"}],
    "mission": [
      {
        "name": "workspace",
        "config": {
          "model_visible": []
        }
      },
      {"name": "history", "config": {"model_visible": []}},
      {"name": "private-history", "config": {"model_visible": []}}
    ]
  },
  "input": {"path": "code-scout/input.json"},
  "contracts": {
    "result_schema": {"path": "code-scout/candidate.schema.json"}
  },
  "limits": {
    "run_duration_ms": 120000,
    "mission_capability_calls": 64
  }
}
```

`agent.main` is a proposed small domain-blind shipped library that forwards
task and loop configuration from input to `agent.core`. It removes a repeated
four-line workflow component but adds no grammar or authority. Code Scout
policy lives in task data, result schemas, evaluation fixtures, and the
application's repository prelude rather than a runtime module.

The raw workspace, trace, and inspection capabilities are hidden from the
model catalog because the `repo` and `runs` preludes supply cleaner functions.
They remain callable by frozen prelude code. The planned `cap` helper library
becomes composition-only rather than prompt-visible, so it does not pollute
that facade. `allow`, if present, may only be a subset of the host tool map.

Selecting `private-history` requires `analysis-llm` and every other selected
egress provider to accept `private_inspection`. This manifest intentionally
selects no remote mission provider besides the local stdio workspace server.
If private trace text may flow to that server through tool arguments, the host
must also declare its accepted data classes; read-only does not mean
non-egress.

## 8. Generic provider contracts

### 8.1 Filesystem MCP server

The sample server contract is defined by the MCP-first plan. For this
application, the important operations are:

| Public capability | Behavior |
| --- | --- |
| `workspace.list` | sorted, paginated relative entries under a prefix |
| `workspace.find` | sorted, paginated path/glob matches |
| `workspace.search` | literal text matches with path, line, bounded context, cursor, and truncation |
| `workspace.read` | one bounded UTF-8 line range with stable line numbers and EOF/truncation |
| `workspace.info` | safe snapshot hash and counts |

PTC-Lisp should expose the familiar application API:

```clojure
(ns repo "Bounded source exploration." {:visibility :prompt})

(defn search
  "Read one search page. Pass nil first, then the returned next_cursor."
  {:signature "(text :string, cursor :string?) -> :map"}
  [text cursor]
  (cap/unwrap!
    (tool/workspace.search
      (merge {"text" text "limit" 20}
             (if cursor {"cursor" cursor} {})))))

(defn read-range
  "Read inclusive lines from one relative UTF-8 path."
  {:signature "(path :string, from :int, to :int) -> :map"}
  [path from to]
  (cap/unwrap!
    (tool/workspace.read {"path" path "from" from "to" to})))
```

The prelude decides search strategy, exposes an opaque cursor without
interpreting it, shapes evidence, and reacts to empty results. Every
collection wrapper accepts `nil` for its first page and the prior
`next_cursor` for a later page. The server owns filesystem confinement,
immutable capture, ordering, cursor validation, byte limits, and tool schemas.
Every data-bearing server result also carries `snapshot_hash`, binding cited
paths and line ranges to the captured bytes.

### 8.2 Canonical trace snapshot

`ptc_trace_snapshot` reads only canonical PtcRunner trace JSONL. It adapts the
existing trace owner and four operations:

- `history.list-runs`;
- `history.get-run`;
- `history.list-turns`; and
- `history.counters`.

Profile-backed and manifest-backed trace analysis must reuse the same query
implementation and return equivalent results. Paths, source bytes, private
payloads, and owner handles stay out of public metadata.

### 8.3 Private inspection snapshot

`ptc_inspection_snapshot` reads only versioned
`.inspection.jsonl` artifacts. It remains separate from canonical trace
discovery and exposes:

- `private-history.list-runs` for completeness without payloads;
- `private-history.model-exchanges`;
- `private-history.capability-calls`;
- `private-history.generated-sources`;
- `private-history.effective-preludes`; and
- `private-history.provider-exchanges` when that private record type lands.

It reuses the authoritative `InspectionArtifact` validation and capture rules:
exact schema/version, duplicate-key rejection, fixed vocabulary, identities,
sequence/correlation validation, symlink/replacement protection, and bounded
files/records. Because V1 has a closed record vocabulary, provider wire
exchanges require a new artifact version rather than an unrecognized V1
record.

Exact provider-neutral records are not necessarily byte-identical to a remote
provider wire format. MCP wire records deliberately add the bounded JSON-RPC
body needed for MCP diagnosis while still excluding credentials and transport
headers.

`code-scout/runs.clj` is the prompt-visible facade over both native sources. It
exports cursor-aware `runs/list`, `runs/turns`, `runs/model-exchanges`,
`runs/capability-calls`, `runs/generated-sources`,
`runs/effective-preludes`, and `runs/provider-exchanges`. This is required by
the current prompt policy: once any prompt-visible prelude facade exists, raw
`tool/...` entries are suppressed. Trace analysis must not depend on the model
guessing hidden capability names or discovering them through `cap/list`.
Native collection operations use the same opaque `next_cursor` convention as
the filesystem server.

### 8.4 LLM replay

Deterministic evaluation needs an installed `llm_replay` source rather than an
Elixir-only test callback. It freezes a bounded fixture file/directory and maps
an exact normalized request hash to one response or explicit ordered response
sequence.

It rejects duplicate keys, missing matches, exhausted sequences, malformed
responses, and limit violations. Its safe snapshot records the format version,
fixture-set hash, entry counts, and ceilings without payloads or paths. It
performs no network activity.

## 9. Candidate and result contracts

The analysis run returns one bounded decision:

```json
{
  "decision": "propose-change",
  "target": "agent.core",
  "generalized_failure": "...",
  "evidence": [
    {"run_id": "...", "event_sequences": [12, 18]},
    {
      "path": "priv/preludes/kernel/agent.core.clj",
      "lines": [70, 96],
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
  "review_diff": "...",
  "evaluation_plan": {
    "motivating_cases": ["..."],
    "regression_cases": ["..."],
    "held_out_cases": ["..."],
    "metrics": ["success", "tool_calls", "tokens"]
  },
  "risks": ["..."]
}
```

Complete component source is authoritative because it can be hashed and
compiled exactly. A diff may accompany it for review but is not executable
truth.

Manifest-local bounded schemas validate input before workflow execution and
`Result.value` before publication. They constrain shape, not confidentiality.
The result-contract compiler supports a narrow tagged union: bounded `oneOf`
object branches with the same required string discriminator and distinct
`const` values. It does not enable arbitrary remote references, regexes, or
general composition in MCP callable schemas.

Planned output channels:

- `--output PATH` atomically creates, without clobbering, exactly the same
  public `Result` projection written to stdout;
- `--private-output PATH` atomically creates a no-clobber `0600` classified
  result and suppresses the value on stdout;
- `--private-mission PATH` loads a manifest-confined JSON object as trusted
  private input and carries that classification into assembly; and
- trace and private inspection remain separate artifacts with their own
  contracts.

Do not invent a second result envelope. The persisted V1 projection remains
`value`, `usage`, and `evaluation_memory`.

## 10. Improvement and evaluation workflow

### 10.1 Analysis

The scout may:

1. classify relevant canonical runs;
2. inspect exact bounded private exchanges;
3. search and read the source owning the behavior;
4. distinguish a one-off defect from a reusable agent-behavior gap;
5. cite evidence that exists in the captured providers; and
6. return `no-change`, `insufficient-evidence`, or one candidate.

Unsupported claims fail evaluation even when the patch appears plausible.

### 10.2 Materialization

The candidate is inert when the run ends. A trusted host step writes it to a
new private file or disposable worktree, verifies `base_source_hash` and
`source_hash`, and never alters the evidence snapshots. File materialization
uses restrictive permissions such as a `077` umask.

Materialization is not hidden in result persistence, trace writing, an MCP
read tool, or the active bundle.

For the paths used above:

```console
umask 077
mkdir -p code-scout/private
jq -jr '.value.candidate.content' \
  code-scout/private/candidate.private.json \
  > code-scout/private/agent.core.candidate.clj
jq '.value.candidate |
    {component_id, base_source_hash, source_hash,
     path: "agent.core.candidate.clj"}' \
  code-scout/private/candidate.private.json \
  > code-scout/private/agent.core.override.json
```

### 10.3 Evaluation

Evaluation uses ordinary isolated runs against:

- motivating cases;
- previously successful regression cases;
- held-out cases not cited by the scout; and
- resource ceilings for calls, turns, duration, and tokens.

Do not switch providers or reset trial state inside one Kernel run. A run has
one frozen workflow environment. `evaluate.clj` therefore executes exactly one
subject/case trial, and separate manifests choose exactly one workflow
provider:

- `evaluate-replay.json` selects `replay-llm` for deterministic compilation,
  schema, capability-contract, bounded-control-flow, and known-regression
  fixtures;
- `evaluate-live.json` selects `analysis-llm` for one live trial; and
- baseline and candidate, every case, and every repetition run in fresh Kernel
  invocations with unique no-clobber outputs.

The evaluator component depends explicitly on `agent.core`, is the workflow
entry, and calls its `run` export once with the bounded case. An override
replaces that dependency before bundle compilation. `aggregate.clj` is a
separate pure workflow component with no LLM or mission providers.

Frozen inputs make live results attributable, not deterministic.

The host prepares a bounded private trial input containing only the candidate
identity (`component_id`, `base_source_hash`, and `source_hash`), one frozen
case, the subject (`baseline` or `candidate`), and trial configuration. It
does not put candidate source in either trial input; only the trusted override
descriptor supplies those bytes to a candidate run. A replay
baseline/candidate pair is:

```console
mkdir -p code-scout/private/trials
mix ptc.run code-scout/evaluate-replay.json \
  --host-config code-scout.host.json \
  --private-mission private/replay-baseline.private.json \
  --private-output code-scout/private/trials/replay-baseline.private.json
mix ptc.run code-scout/evaluate-replay.json \
  --host-config code-scout.host.json \
  --private-mission private/replay-candidate.private.json \
  --component-override-descriptor code-scout/private/agent.core.override.json \
  --private-output code-scout/private/trials/replay-candidate.private.json
```

The host repeats the same baseline/candidate shape with `evaluate-live.json`
for each motivating, regression, and held-out case. There is no in-run
provider routing and no mission state is shared across trials.

`--component-override-descriptor` is host CLI authority. The exact descriptor
contains `component_id`, `base_source_hash`, `source_hash`, and a path confined
to the descriptor directory. The runner opens the source once, hashes those
bytes, verifies the base against the currently installed component, and
compiles the same opened bytes under normal dependency, export, signature, and
capability validation. It never reopens a replacement path and adds no runtime
write capability.

After the host combines the still-private trial `Result` projections into one
bounded array, a provider-free `aggregate.json` invokes `aggregate.clj` to
validate counts and produce distributions:

```console
jq -s '{"trials": .}' code-scout/private/trials/*.private.json \
  > code-scout/private/trials.private.json
mix ptc.run code-scout/aggregate.json \
  --private-mission private/trials.private.json \
  --private-output code-scout/private/evaluation.private.json
```

Every trial and aggregate binds the subject, candidate/base hashes, case and
fixture-set hashes, effective bundle hash, host installation-revision hash,
provider snapshot, and filesystem/content snapshot identities. A schema-only
provider hash is not evidence that the evaluated server or dataset was the
same.

### 10.4 Promotion

Evaluation returns evidence only. A human or trusted CI gate reviews
confidentiality and behavior, applies an approved candidate, and runs normal
repository gates.

A future write-capable MCP tool should first target a disposable candidate
workspace. It needs explicit host effect classification, manifest selection,
approval policy, partial-effect semantics, and cancellation behavior. Read
access never implies write authority.

## 11. Implementation sequence

### Slice A — MCP prerequisites

Complete Slices 1 and 2 of the MCP-first plan:

- modern stateless protocol;
- one MCP source;
- Streamable HTTP retained as an MCP transport;
- owner-monitored stdio; and
- no legacy sessions.

**Gate:** the same mapped read tool works through both standard transports.

### Slice B — Host installation and `--check`

Complete MCP-first Slice 3:

- `--host-config`;
- closed source/transport decoders;
- closed host-installed `llm` aliases over the existing LLM adapter;
- reject `source: "file-read"` and all legacy model/root/file provider config;
- prepare the provider registry to contain exactly the host-installed aliases
  when Slice C activates the cutover;
- credentials;
- manifest-only narrowing;
- data-class compatibility; and
- validation-only assembly.

**Gate:** an ordinary manifest selects the sample stdio server with no Elixir
registration.

Static source, selection, and data-class checks happen before credentials are
resolved, sensitive snapshots are opened, stdio is spawned, or remote MCP is
contacted. Discovery is a later dynamic validation phase.

### Slice C — Sample filesystem server

- implement immutable list/find/search/read/info tools;
- require a non-empty default-deny host include set;
- use familiar MCP naming and bounded object schemas;
- add path, symlink, replacement, UTF-8, cursor, ordering, size, stderr,
  cancellation, owner-death, and excluded-secret/build/private-path tests; and
- map only read tools in the tutorial host config;
- migrate all current `file-read` examples and tests to those mapped tools;
- delete the implicit `file-read` builder, its manifest config, and
  `FileCapability`; and
- activate the host-only provider registry in the same breaking change.

**Gate:** the agent can discover an unknown nested file, find a literal, and
read its surrounding lines without a prelisted answer, while no public
`file-read` provider remains.

### Slice D — Manifest-selectable PTC snapshots

- adapt the existing trace owner into a provider builder;
- add the private inspection snapshot without changing its file format;
- reuse authoritative parsers/query code;
- enforce private data compatibility before opening sensitive sources; and
- prove fixed-profile and manifest paths return equivalent queries.

**Gate:** one ordinary manifest can correlate source, canonical trace, and
exact private inspection.

### Slice E — MCP feedback and private exchange records

Complete MCP-first Slice 4:

- preserve safe bounded tool-error feedback;
- add private JSON-RPC exchange evidence;
- retain closed public errors; and
- propagate safe trace context.

**Gate:** the scout can see why a filesystem call failed and a private reviewer
can reconstruct the complete tool exchange.

### Slice F — Result artifacts and contracts

- add `--output` and `--private-output`;
- add mutually exclusive `--mission` and trusted `--private-mission`;
- add input and `Result.value` schemas;
- support the bounded tagged-union profile needed by candidate decisions;
- preserve the existing result projection;
- ensure no-clobber atomic persistence;
- keep private values off stdout and public artifacts; and
- cover failures after meaningful provider activity.

**Gate:** a candidate becomes typed input to a later run without scraping
stdout.

### Slice G — Read-only Code Scout

- extend the shipped `cap` library with an envelope-aware `unwrap!` helper;
- make that helper library composition-only rather than prompt-visible;
- add the domain-blind `agent.main` library and its explicit dependencies;
- add prompt-visible `repo` and `runs` facades over every selected raw source;
- expose opaque pagination cursors through every collection facade and test
  evidence that occurs only after the first page;
- cover the helpers, facade-only model catalog, and agent through a real
  manifest integration path;
- add only host JSON, manifests, PTC-Lisp, schemas, and fixtures;
- use the sample MCP server and PTC-specific snapshots;
- keep prompts domain-blind;
- return verifiable decisions, including declining a change; and
- include prompt-injection data in held-out evaluation.

**Gate:** deleting the application files removes the entire Code Scout; no
runtime module contains its domain vocabulary.

### Slice H — Candidate evaluation

- implement the trusted, hash-bearing component override descriptor;
- implement `llm_replay`;
- add the one-trial evaluator and provider-free aggregate components;
- run replay/live and baseline/candidate in separate fresh invocations;
- prove no trial shares Kernel state or switches workflow providers;
- bind artifacts to candidate, fixture, installation revision, provider,
  content snapshot, and bundle hashes; and
- keep promotion external.

**Gate:** a candidate cannot pass solely by fixing cited cases while regressing
held-out cases.

### Later — Tasks and guarded writes

MCP Tasks are a natural fit for long test suites, indexing, CI, and approval
gates, but require the lifecycle and accounting design in the MCP-first plan.
Write tools remain a separate authority milestone.

## 12. Acceptance matrix

| Case | Expected result |
| --- | --- |
| No host config and no selected providers | Provider-free run remains valid |
| A manifest selects a provider without host config | Strict failure; there is no implicit `llm` or `file-read` fallback |
| A manifest uses legacy model/root/file provider config | Strict failure before provider activity |
| Host config declares `source: "file-read"` | Strict unknown-source failure; model-accessible filesystem operations require `source: "mcp"` |
| PtcRunner reads host config, a manifest, component, contract, or selected input | Dedicated confined loader remains direct; MCP is not a bootstrap dependency |
| Unknown host source/transport | Fails before provider or model activity |
| Manifest supplies a command, endpoint, root, credential, or effect | Strict manifest failure |
| Manifest selects an uninstalled provider/tool or raises a ceiling | Assembly failure |
| Sample filesystem changes after capture | Run continues to observe the frozen snapshot |
| Installation revision or content snapshot identity changes | Trial/provider identity changes |
| Secret, dependency, build, trace, or private-result path is not included | Workspace never opens or exposes it |
| Path traverses or crosses a symlink | Bounded tool error; no escaped data or host root |
| MCP server emits a malformed/oversized response | Closed provider failure and owned cleanup |
| MCP tool returns safe bounded argument feedback | Agent may correct it; public trace/error remains payload-free |
| Canonical trace source is malformed or changes during capture | Existing stable trace-source failure |
| Private artifact is malformed, replaced, oversized, or crosses a symlink | Closed private-source failure; no partial catalog |
| Private source has an unapproved selected egress sink | Assembly fails before sensitive capture, MCP activity, or model calls |
| `--private-mission` selects an unapproved sink or public output | Fails before provider activity; input remains private |
| Input or result violates its schema | Invalid value is not executed/published |
| Private run requests stdout value or public output | Closed failure; private value reaches only explicit private output |
| Scout sees one isolated defect | `no-change` or `insufficient-evidence`, not forced code |
| Candidate hash/base/compilation fails | Evaluation rejects before behavioral cases |
| Override source changes between verification and compilation | Rejected or irrelevant because the same opened bytes are hashed and compiled |
| A trial attempts to select both replay and live LLMs | Strict provider/capability failure; each run has one workflow LLM |
| Baseline/candidate repetitions are requested | Each is a fresh Kernel run with a distinct no-clobber artifact |
| Required source or run evidence occurs after the first page | The model-visible facade can follow the opaque cursor and retrieve it |
| Candidate improves motivating but regresses held-out cases | Reject or mark inconclusive |
| Run fails after starting stdio/native snapshot resources | Every resource is cancelled, observed, and closed exactly once |

## 13. Open decisions

1. **Private data and local stdio.** A local MCP server is still a separate
   process and generated code may send private text in tool arguments.
   Recommendation: treat every selected MCP provider as an egress sink unless
   a future installed contract proves a no-egress local mode.
2. **Filesystem snapshot mechanism.** In-memory bytes, a content-addressed
   temporary tree, or an indexed store? Recommendation: start with bounded
   in-memory UTF-8 text for the sample; it is easiest to make immutable and
   deterministic.
3. **Search language.** Recommendation: literal content search plus glob path
   filters. Regex is unnecessary for acceptance and can create runtime hazards.
4. **Live evaluation policy.** Decide minimum repetitions, confidence
   reporting, and acceptable regression thresholds per application. The
   platform only guarantees pinned configuration, fresh runs, and attributable
   artifacts; it does not declare statistical significance.
5. **Reusable application distribution.** Manifest-relative components are
   enough for the first application. Defer a component catalog until copying
   local PTC-Lisp is a demonstrated problem.
6. **Evaluation orchestration.** Prove two explicit `ptc.run` invocations
   before designing a pipeline language.
7. **Tasks.** Decide whether a durable MCP task may outlive its PtcRunner run
   before advertising the extension.
8. **Writes.** Decide approval, retry, partial-effect, and disposable-workspace
   rules before mapping the first `effect: write` tool.

## 14. No-Elixir completion test

The direction is proven when a clean installed PtcRunner can run the Code
Scout files and satisfy all of the following:

- the command is ordinary `mix ptc.run`;
- no `.ex` or task-specific Mix file changes for the application;
- host JSON installs the MCP filesystem server, PTC snapshots, and approved
  LLM;
- no public `file-read` provider or host source remains;
- the manifest only selects and narrows those grants;
- local PTC-Lisp discovers relevant files and traces without prelisted
  answers;
- exact private conversation and MCP evidence is available only under explicit
  private authority;
- the bounded result may decline a change or emit an inert content-addressed
  candidate;
- separate generic invocations evaluate baseline and exact candidate with
  replay fixtures and fresh held-out live trials, then aggregate their
  artifacts; and
- applying or promoting the candidate remains an explicit host/human write
  decision.
