# Manifest-authored applications — implementation plan

> **Status:** active implementation plan, promoted from `future/` on
> 2026-07-24. Slices A, B, Pre-C, C, D, and F are complete. Slices E, G, and H
> remain planned.
> This document
> describes the generic runner and application contracts built on the
> MCP-first capability platform.

## 1. Goal

Keep `mix ptc.run` as the generic top-level runner while making this authoring
test pass:

> Once PtcRunner implements MCP and a small set of PTC-specific local sources,
> an application author can add a substantial task using host configuration, a
> manifest, PTC-Lisp, and data. They do not add an Elixir module, edit
> `ProviderRegistry`, or create a task-specific Mix command.

### 1.1 Two claims, proven separately

This document carries two claims of very different confidence, and they must
not share a completion test.

**Claim A — applications are assembled from data, not Elixir.** A third-party
MCP server becomes an application capability through host JSON, a manifest,
and PTC-Lisp. This is the platform thesis, it is broadly valuable, and it is
provable as soon as host installation exists.

**Claim B — an agent can improve its own preludes from its own evidence.** A
scout reads canonical traces and explicitly granted private conversations,
proposes a prelude change as inert data, and separate runs evaluate it. This
is a research claim. It may not pay off, and §13.1 already concedes the
platform guarantees pinned configuration and attributable artifacts rather
than statistical significance.

Claim A must not wait on Claim B. Earlier revisions of this plan proved both
only at the final slice, which meant the platform thesis stayed untested until
the most speculative work was finished. Claim A is now settled by the MCP-first
Slice 3 GitHub acceptance and the ordinary application in Slice C; Claim B is
settled by the Code Scout flow in Slices E–H. §14 states each test separately.

A repository Code Scout remains the proving application for Claim B. It must
navigate unknown nested files, analyze canonical traces and explicitly granted
private conversations, propose a prelude improvement as inert data, and
evaluate that candidate in a separate run. The Kernel must never acquire
`scout`, `repository`, or `self-improvement` policy.

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
- a fixed private-inspection `ptc.repl` profile for human investigation;
- local PTC-Lisp application components and preludes;
- bounded input, candidate, and evaluation contracts;
- public and private result artifacts;
- proposal, evaluation, and explicit promotion as separate phases; and
- a read-only Code Scout acceptance application.

Claim A (§1.1) is in scope for Slices A–C and is not conditional on any of the
self-improvement work below it.

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
| MCP | Trusted Elixir can install a read-only stateless HTTP `2026-07-28` source | stdio and host JSON |
| Canonical trace | `TraceSnapshot` and `TraceCapability` provide four bounded queries in the fixed `log-analysis-v1` profile | ordinary manifest-selectable source |
| Private inspection | `--inspect` writes exact provider-neutral capability, evaluation-source, and prelude-source records to a bounded `0600` artifact — LLM exchanges are the workflow `llm-request` capability records; the Viewer can pin one artifact against its canonical run | ordinary explicitly classified snapshot source, a private human-analysis REPL profile, and MCP wire records |
| `ptc.repl` profiles | the frontend, resource parser, assembly, session, and help text are hard-coded to `log-analysis-v1` | a closed profile registry and shared analysis-session machinery before adding `inspection-analysis-v1` |
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
mix ptc.run code-scout-improve.json \
  --host-config code-scout.host.json \
  --private-output code-scout/private/candidate.private.json \
  --trace tmp/code-scout-trace.jsonl
```

Generic options may know about manifests, host installation, validation,
classified outputs, traces, inspection, and trusted component overrides. They
must not know that the application is a scout.

Planned validation:

```console
mix ptc.run code-scout-answer.json \
  --host-config code-scout.host.json \
  --check
```

`--check` strictly loads components and contracts and performs static
data-class/egress compatibility before provider activity. It then assembles
providers, performs MCP discovery, emits only bounded redacted hashes, and
closes every resource. It invokes neither the workflow entry nor an LLM. After
the static phase succeeds, it is deliberately allowed to start a configured
stdio server or contact a configured remote MCP endpoint.

Its main output is the resolved, manifest-selected picture rather than the raw
heterogeneous host entries:

```text
workflow  deepseek   llm        model openrouter:deepseek/deepseek-v4-flash  accepts: normal, private_inspection  snapshot ...
mission   workspace  mcp/stdio  5 tools  accepts: normal, private_inspection  snapshot ...
```

Rows are ordered by environment and alias. Source-specific safe metadata may
follow, but secrets, rendered authorization, host roots, and private payloads
never do. This computed view cannot drift from assembly rules.

Both JSON control files have shipped JSON Schema 2020-12 contracts:

```text
priv/schemas/ptc-host-config.schema.json
priv/schemas/ptc-application-manifest.schema.json
```

An optional `$schema` property lets editors surface source-specific completion,
field descriptions, defaults, examples, unknown fields, and malformed
provider selections while the human is typing. Both schemas are generated by
`mix ptc.gen_docs` and checked for drift by `mix precommit`. The new host
decoder and host schema share its closed structural descriptor. The existing
explicit manifest decoder remains unchanged in style; its schema is generated
from an explicit schema definition beside it rather than from a new generic
configuration DSL.

This does not split validation authority. PtcRunner does not fetch `$schema`;
the strict loader and `--check` still own duplicate-key detection, bounded
files, paths, credential/provider references, ceiling narrowing, data-class
and egress compatibility, discovery, and lifecycle validation. Schema success
means “structurally plausible,” not “authorized to run.” A shared
valid/invalid fixture corpus and every concrete documented config must agree
between schema validation and the corresponding runtime decoder; abstract
grammar sketches are not fixtures.

### 4.2 The authority ladder remains visible

| Layer | Owns | Code Scout example |
| --- | --- | --- |
| Host config | authority and outer ceilings | MCP executable/args, filesystem root, trace directories, credentials, tool effects |
| Manifest | selection and narrowing | which public workspace/history tools enter the mission, lower quotas |
| PTC-Lisp | application behavior | search strategy, evidence collection, candidate/evaluation policy |
| Generated program | one bounded action sequence | calls `repo/search`, `repo/read-range`, and trace queries |

The manifest cannot contain an MCP command, remote endpoint, filesystem root,
credential, or effect. It can only select names installed by the host.

For manifest/CLI runs, host installation replaces the current implicit
provider registry; it does not augment it. When the combined Slices B–C
cutover lands, manifests can no longer instantiate the legacy `llm` or
`file-read` built-ins by supplying provider-specific config. Every selected
provider name must come from the host document. A provider-free manifest,
such as the pure aggregate run below, may omit host config. Existing
manifests, examples, and tests move to installed aliases; the legacy inline
config keys (`model` and `cache` for `llm`; `root`, `max_bytes`, and
`model_visible` for `file-read`) are rejected rather than retained as a
fallback path.

Trusted direct Elixir embedding remains able to construct and pass an
explicit `ProviderRegistry`, including custom builders. That programmatic host
API is outside the no-Elixir manifest promise and does not become host-JSON
only.

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

Classification is deliberately coarse and run-level:

1. The effective run class is `private_inspection` when the mission input is
   private or any selected provider produces private inspection data;
   otherwise it is `normal`.
2. The entire `Result.value` inherits that effective class.
3. Every selected remote provider or write sink, including the workflow LLM
   and every MCP provider, must accept that class before any provider is
   acquired.
4. A native local read-only snapshot is not itself egress. Terminal display,
   public result output, remote calls, MCP calls, and future writes are sinks.

This is conservative by design: V1 does not attempt field-level taint
tracking. Every selected MCP provider is an egress sink even when it launches
locally, because generated code can send data in tool arguments. A future
installed no-egress contract may narrow that rule.

Terminal publication is also a sink. A private run suppresses its value on
stdout, cannot use normal `--output`, and requires an explicit no-clobber
`0600` private result.

Human investigation uses a separate planned
`inspection-analysis-v1` `ptc.repl` profile. Do not widen
`log-analysis-v1`: its profile ID attests a normal-data authority recipe. The
private profile immutably captures both a canonical trace directory and a
private inspection directory, validates every inspection artifact against its
captured canonical run, and exposes only bounded read-only `log/*` and
`inspection/*` functions.

Selecting the private profile is not sufficient terminal authority. Its first
version is interactive-only and also requires `--private-terminal` on an
attached terminal. That check happens before either source is opened. The
flag makes terminal scrollback an explicit private sink; it does not
declassify data. Non-interactive `--eval`, script, stdin, and JSONL modes are
rejected initially. A later non-interactive mode must use an explicit
no-clobber `0600` private output and keep values off stdout.

The inspection-analysis session writes its own physically separate canonical
analysis trace. That trace records hashes, sizes, timing, outcomes, and usage,
but never queried inspection payloads, evaluated source text, or retained REPL
history. The profile grants no LLM, filesystem, network, MCP, write, or
inspection-capture authority.

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
code-scout-answer.json           source-question selection and contract
code-scout-review.json           prior-run review selection and contract
code-scout-improve.json          candidate proposal selection and contract
code-scout/
  repo.clj                       MCP filesystem wrappers
  runs.clj                       trace/private-inspection wrappers
  evaluate.clj                   exactly one isolated evaluation trial
  aggregate.clj                  pure aggregation of trial artifacts
  answer-input.json              one source question
  review-input.json              one prior-run review task
  improve-input.json             one improvement task
  answer.schema.json             source-answer Result.value contract
  review.schema.json             review Result.value contract
  candidate.schema.json          improvement Result.value contract
  evaluation.schema.json         aggregate Result.value contract
  trial-input.schema.json        per-trial subject/case input contract
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

Native PtcRunner snapshot sources derive public names as
`<installed-alias>.<fixed-operation>`. The host chooses the installed alias
(`history` or `private-history` below); the source implementation owns its
closed operation names. MCP is different because its explicit host tool map
chooses each public `as` name.

## 6. Planned host installation

Installation remains flat because the host declares what exists while each
manifest selects an environment. Read examples in this order: credentials,
workflow-side installations, then mission-side installations. The current
tutorial placement is:

| Source | Tutorial placement | Platform rule |
| --- | --- | --- |
| `llm`, `llm_replay` | workflow | workflow-only |
| `ptc_trace_snapshot`, `ptc_inspection_snapshot` | mission | mission-only |
| `mcp` | mission | mission in the first slice; workflow-side MCP remains an explicit open decision |

This table explains the examples; it does not nest destinations into host
configuration or remove `providers.workflow` and `providers.mission` from
manifests.

Illustrative final configuration for every tutorial phase:

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
      "credential": "openrouter_key",
      "accepts_data": ["normal", "private_inspection"]
    },
    "replay-llm": {
      "source": "llm_replay",
      "fixtures": "code-scout/evaluation/replay.jsonl",
      "data_class": "private_inspection",
      "accepts_data": ["normal", "private_inspection"],
      "ceilings": {
        "max_entries": 1000,
        "max_result_bytes": 250000
      }
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
          "code-scout/*.clj",
          "--include",
          "code-scout/*-input.json",
          "--include",
          "code-scout/*.schema.json",
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
    }
  }
}
```

The shared host credential declarations and source-specific references are
defined once in
[MCP plan §5.1](mcp-capability-platform-direction.md#51-credential-bindings).
The `deepseek` installation names one binding through `credential`; its known
OpenRouter adapter renders the bearer header per request. This sample
filesystem process has no credential, but a stdio MCP installation may map an
allowlisted child environment variable to a binding. Neither manifests nor
PTC-Lisp can name or inspect those bindings.

The filesystem root is an argument to a trusted installed command. The
manifest never sees or changes it. The configured `cwd` and path fields in
host config resolve relative to the canonical host-config directory unless a
source explicitly requires an absolute operator path. The executable is
resolved once under host policy and frozen before spawn.

The repeated `--include` arguments are a default-deny host allowlist, not
search hints. The sample server exposes application-local PTC-Lisp, task
inputs, and result schemas so Code Scout can inspect its own policy, but does
not open or inventory anything else. Consequently the host document, root
manifests, `.env`, `.git`, `deps`, `_build`, `tmp`, replay/held-out fixtures,
and the generated private-result directory remain outside ordinary workspace
data.

The stdio child receives an explicit allowlisted environment. Erlang Port
`{env, ...}` extends the ambient environment and is not by itself a clean
environment guarantee, so implementation uses the MCP plan's versioned,
optional companion launcher and process-group ownership. Supported stdio users
receive a checksummed precompiled artifact rather than a compiler requirement.
A trusted runtime-level custom path is an explicit deployment override, not
another manifest-selectable provider or a native build requirement of the core
Hex library. The default macOS/Linux compatibility profile inherits only the
six sudo-inspired MCP SDK variables; operators can select a strict-empty base,
and credentials remain explicit bindings.

`workspace.tools` is mandatory because it is the security allowlist and effect
classification. The sample server may advertise additional tools; PtcRunner
does not expose them. Mapped tools are model-invisible by default, normal is
the default data class unless a closed source fixes a stricter class, normal is
the default accepted class, and omitted stdio `env` means no credential
bindings. These local safe defaults remove repeated fields without introducing
a defaults block or merge precedence.

Do not add a shared ceilings/defaults section for the first application.
Repeated explicit byte limits are cheap; an inherited security ceiling would
need merge precedence, validation, and disagreement diagnostics. Revisit only
after several real host documents show substantial repetition beyond these
safe field defaults.

There are no implicitly installed `llm` or `file-read` names alongside this
document. For `mix ptc.run`, the host document is the complete provider
registry for the run. This prevents a manifest from bypassing an
operator-installed alias by falling back to the current manifest-configured
built-ins. Trusted Elixir callers may still supply an explicit custom
`ProviderRegistry`; that embedding API is not manifest authority.

There is also no host-configurable `file-read` source. At the cutover, current
whole-file examples move to the filesystem MCP server and the old builder,
manifest schema, and capability module are deleted. PtcRunner's dedicated
loaders for its own configuration and artifacts are unaffected.

`llm` is another closed host-installable source owned by the generic
application platform, not by MCP. It wraps the existing provider-neutral LLM
adapter and emits exactly the standard workflow `llm-request` capability.
Host config owns model ID, credential binding, cache policy, accepted data
classes, optional installation revision, and the provider alias (`deepseek`
here).
A manifest may select that alias and lower generic ceilings; it cannot change
the model, credential, cache policy, or identity. `llm_replay` emits the same
capability contract from frozen fixtures, so a run chooses one or the other at
assembly rather than switching providers while executing. An optional
installation revision affects either safe snapshot when present. Replay also
includes the fixture-set hash, while a live LLM snapshot includes the effective
model and non-secret request-policy identity.

For the live `llm` source, the optional host `ceilings` fields are
`max_request_bytes` and `max_response_bytes`, both defaulting to the Kernel's
bounded capability limits. A manifest selection may repeat either field only
to lower it. The tutorial omits them because the safe defaults are sufficient.

The example pins the upstream model directly with the existing registry
grammar. The effective resolved model enters the safe snapshot. The
LLM-specific `credential` field authorizes the binding for that installation;
the known adapter owns its conventional bearer rendering. Generic MCP HTTP
transports retain the explicit `auth` scheme list because their authentication
contract is not implied by a model provider. LLM caching keeps its current
`false` default, so the example omits `cache`.

## 7. Planned task-specific manifests

The source-question manifest is:

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
      {"id": "repo", "path": "code-scout/repo.clj", "dependencies": ["cap"]}
    ],
    "data": {}
  },
  "providers": {
    "workflow": [{"name": "deepseek"}],
    "mission": [{"name": "workspace"}]
  },
  "input": {"path": "code-scout/answer-input.json"},
  "contracts": {
    "result_schema": {"path": "code-scout/answer.schema.json"}
  },
  "limits": {
    "run_duration_ms": 120000,
    "mission_capability_calls": 64
  }
}
```

The review and improvement manifests retain the same workflow and limits but
add only the mission surface their tasks require:

| Manifest | Input and `Result.value` contract | Mission surface | Result class |
| --- | --- | --- | --- |
| `code-scout-answer.json` | `answer-input.json` / `answer.schema.json` | `cap` + `repo`; `workspace` | public |
| `code-scout-review.json` | `review-input.json` / `review.schema.json` | add `runs`; add `history` + `private-history` | private |
| `code-scout-improve.json` | `improve-input.json` / `candidate.schema.json` | same evidence surface as review | private |

The manifests remain small and may share ordinary JSON-generation tooling, but
the runtime does not introduce manifest inheritance. A question, a run review,
and an improvement decision are different output types and must not be forced
through one broad union. Do not add a manifest-level `tasks` map or `--task`
selector for these three cases; revisit that grammar only when a fourth real
task demonstrates that separate manifests are the dominant remaining
duplication.

`agent.main` is a small domain-blind shipped library that forwards
task and loop configuration from input to `agent.core`. It removes a repeated
four-line workflow component but adds no grammar or authority. Code Scout
policy lives in task data, result schemas, evaluation fixtures, and the
application's repository prelude rather than a runtime module.

The host mappings keep every raw capability model-invisible by relying on the
safe false default. The prompt policy then presents `repo` as the answer facade
and `repo` plus `runs` as the review/improvement facade. Frozen prelude code can
still call the mapped raw capabilities, and visibility is discovery-only: a
selected, model-invisible capability also remains callable by generated code
that names it directly, because authority comes from host installation and
manifest selection rather than the prompt catalog. The `cap` helper library
becomes composition-only rather than prompt-visible. A manifest may further
narrow an installed model-visible set, but these examples do not repeat an
empty narrowing when the host ceiling is already false. `allow`, if present,
may only be a subset of the host tool map.

The answer manifest never selects or opens prior-run sources. Selecting
`private-history` in the review and improvement manifests requires
`deepseek` and every other selected egress provider to accept
`private_inspection`. Those manifests select no remote mission provider
besides the local stdio workspace server. Private trace text may flow to that
server through tool arguments, so the host must explicitly accept the class;
read-only does not mean non-egress.

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

For V1, the server captures one bounded in-memory UTF-8 snapshot. Path
selection uses glob filters and content search is literal; regex and a
content-addressed or indexed store are deferred until a real application
needs them.

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

The composition-only `cap/with-cursor` helper owns the repeated conditional
merge of an opaque cursor into a string-keyed argument map. It neither follows
nor interprets the cursor. A general `cap/paginate` helper is deliberately
absent from the first slice: generated code can loop explicitly, stop when it
has enough evidence, and keep every page call visible to Kernel budgets
without accumulating an unbounded all-pages result. Revisit automatic
pagination only after several applications demonstrate the same bounded
all-pages policy.

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

The implementation adds one immutable `InspectionSnapshot` owner and one
source-bound query layer. Both the manifest provider and private REPL profile
must use them; neither may query raw records through its own filters. The
snapshot enumerates a bounded directory, opens each regular
`.inspection.jsonl` file once, retains the validated records under aggregate
and retained-size ceilings, and never reopens a pathname. It reuses the
authoritative `InspectionArtifact` rules: exact schema/version,
duplicate-key rejection, fixed vocabulary, identities, sequence validation,
symlink/replacement protection, and bounded files/records.

The inspection snapshot is constructed with the already captured
`TraceSnapshot`. For every inspection artifact it resolves the exact
`run_id`/`trace_id`, pages the corresponding captured canonical turns, and
calls the existing correlation validator before publishing any capability.
An orphan, identity mismatch, missing canonical page, duplicate inspection
artifact for one run, or incomplete correlation fails the whole snapshot; no
partial private catalog is exposed. The paired snapshots then remain immutable
for the session.

Queries return paired records rather than leaving callers to join inputs and
outputs by timestamp. Model exchanges and capability calls include their
correlation ID and input/output sequences; generated sources and effective
preludes carry their canonical evaluation/component identity and hashes.
Every collection is deterministically ordered, paged under a result-byte
ceiling, and uses an opaque cursor bound to the snapshot identity, operation,
filters, and offset.

`model-exchanges` needs no new record type: the V1 vocabulary already
captures each LLM exchange as the `capability-input`/`capability-output`
records of the workflow `llm-request` capability, so the query is a filtered
pairing of existing records. Provider wire exchanges have no V1 record type;
because the vocabulary is closed, they require a new artifact version rather
than an unrecognized V1 record.

Exact provider-neutral records are not necessarily byte-identical to a remote
provider wire format. MCP wire records deliberately add the bounded JSON-RPC
body needed for MCP diagnosis while still excluding credentials and transport
headers.

`code-scout/runs.clj` is the prompt-visible facade over both native sources. It
exports cursor-aware `runs/list-runs`, `runs/turns`, `runs/model-exchanges`,
`runs/capability-calls`, `runs/generated-sources`,
`runs/effective-preludes`, and `runs/provider-exchanges`. This is required by
the current prompt policy: once any prompt-visible prelude facade exists, raw
`tool/...` entries are suppressed. Trace analysis must not depend on the model
guessing hidden capability names or discovering them through `cap/list`.
Native collection operations use the same opaque `next_cursor` convention as
the filesystem server.

### 8.4 Private inspection REPL profile

The planned fixed profile is invoked as:

```console
mix ptc.repl \
  --profile inspection-analysis-v1 \
  --resource traces=tmp/traces \
  --resource inspection=tmp/inspection \
  --session-trace-dir tmp/analysis-traces \
  --private-terminal
```

Both resources are existing directories. `traces` accepts only normal
canonical trace files; `inspection` accepts only private inspection artifacts.
The input directories and analysis-trace destination must be physically
separate, including through aliases and symlinks.

The shipped `log.core` component keeps its current canonical functions. A new
composition-only `inspection.core` component wraps the same fixed inspection
capabilities used by `ptc_inspection_snapshot` and exports:

- `inspection/runs`;
- `inspection/model-exchanges`;
- `inspection/capability-calls`;
- `inspection/generated-sources`;
- `inspection/effective-preludes`; and
- `inspection/provider-exchanges`.

The profile contains exactly `log.core`, `inspection.core`, their fixed
read-only capabilities, empty mission data, and ordinary runtime
introspection. It has a distinct digest and declares
`private_inspection` as both its source and result class.

The `provider-exchanges` operation is present in the profile from its first
release and returns an empty page for an inspection format with no such
records. Slice F teaches the shared inspection source to populate it from the
new versioned record type; it does not widen the profile's capability surface.
Any later authority or capability addition requires a new profile ID.

Adding this profile requires extracting the code-owned session plumbing that
is currently specific to log analysis. A closed internal profile registry
resolves an ID to a recipe for resource schema, captures, components,
capabilities, limits, data class, frontend modes, result presentation, and
cleanup. Shared assembly attestation, lifecycle ownership, evaluation,
budgets, and canonical session-trace persistence move behind one analysis
session engine. The existing `log-analysis-v1` descriptor and behavior remain
unchanged. Callers still cannot provide a module, component, capability,
limit, or sink policy; this refactor does not make profiles manifest-authored
or plugin-extensible.

### 8.5 LLM replay

Deterministic evaluation needs an installed `llm_replay` source rather than an
Elixir-only test callback. It freezes a bounded fixture file/directory and maps
an exact normalized request hash to one response or explicit ordered response
sequence.

It rejects duplicate keys, missing matches, exhausted sequences, malformed
responses, and limit violations. Its safe snapshot records the format version,
fixture-set hash, entry counts, and ceilings without payloads or paths. It
performs no network activity.

## 9. Candidate and result contracts

Each task has a narrow result:

- `answer.schema.json` requires an answer plus source-backed citations;
- `review.schema.json` requires a bounded review summary, recurring findings,
  cited run/source evidence, and a recommended next action; and
- `candidate.schema.json` is the tagged decision union used only by the
  improvement task.

The improvement run returns one bounded decision:

```json
{
  "decision": "propose-change",
  "target": "agent.core",
  "generalized_failure": "...",
  "evidence": [
    {
      "provider": "history",
      "snapshot_hash": "sha256:...",
      "run_id": "...",
      "event_sequences": [12, 18]
    },
    {
      "provider": "workspace",
      "snapshot_hash": "sha256:...",
      "path": "priv/preludes/kernel/agent.core.clj",
      "lines": [70, 96]
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

Output channels:

- `--output PATH` atomically creates, without clobbering, the validated
  `Result.value`;
- `--private-output PATH` atomically creates a no-clobber `0600` classified
  result and suppresses the value on stdout;
- `--private-mission PATH` loads a manifest-confined JSON object as trusted
  private input and carries that classification into assembly; and
- trace and private inspection remain separate artifacts with their own
  contracts.

Path resolution is intentionally explicit:

| Path surface | Base for a relative path |
| --- | --- |
| Manifest path, `--host-config`, `--trace`, `--inspect`, `--output`, `--private-output`, or `--component-override-descriptor` | invoking process working directory |
| A path or `cwd` stored inside host config | canonical host-config directory |
| Component, input, or contract path stored inside a manifest | canonical manifest directory |
| `--mission` or `--private-mission` | canonical manifest directory |
| Candidate source path stored inside an override descriptor | canonical descriptor directory |

The runner canonicalizes and confines each path under its owning boundary
before opening it. Moving a manifest or host document therefore moves its
relative configuration as a unit, while output destinations remain explicit
operator paths.

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
- `evaluate-live.json` selects `deepseek` for one live trial; and
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
descriptor supplies those bytes to a candidate run. A trusted host step
generates each trial-input file consumed below from the candidate artifact
and one frozen case before any trial runs; `evaluate-replay.json` and
`evaluate-live.json` validate it against `trial-input.schema.json`. A replay
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
fixture-set hashes, effective bundle hash, provider snapshot, and
filesystem/content snapshot identities. When present, an optional installation
revision contributes to the provider snapshot. A schema-only provider hash is
not evidence that the evaluated server or dataset was the same.

### 10.4 Promotion

Evaluation returns evidence only. A human or trusted CI gate reviews
confidentiality and behavior, applies an approved candidate, and runs normal
repository gates.

A future write-capable MCP tool should first target a disposable candidate
workspace. It needs explicit host effect classification, manifest selection,
approval policy, partial-effect semantics, and cancellation behavior. Read
access never implies write authority.

## 11. Implementation sequence

Slices A–C settle Claim A: after them, a third-party MCP server is an
application capability reachable from host JSON, a manifest, and PTC-Lisp.
Slices D–H settle Claim B and are enrichment on a validated foundation rather
than prerequisites for an unvalidated one. If Claim B stalls, Claim A is
already proven and shippable.

| Slice | Serves | Settles |
| --- | --- | --- |
| A — MCP prerequisites | A | one client, both transports |
| B — Host installation and `--check` | A | **Claim A**: real third-party server, no Elixir |
| Pre-C — Confined trusted file loading | A | trusted loading independent of the public provider |
| C — Sample filesystem server | A | an ordinary application on an owned server |
| D — Classified inputs and result artifacts | B | typed artifacts between runs |
| E — PTC snapshots and private inspection | B | evidence a reviewer can read |
| F — MCP feedback and exchange records | B | why a call failed |
| G — Read-only Code Scout | B | the scout itself |
| H — Candidate evaluation | B | **Claim B**: propose, evaluate, promote |

### Slice A — MCP prerequisites

Complete Slices 0–2 of the MCP-first plan:

- behavior-preserving pure protocol seams;
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
- generated, shipped JSON Schemas for host config and application manifests,
  including optional non-semantic `$schema` annotations;
- a descriptor-driven host decoder and explicit manifest schema definition,
  with one shared structural fixture corpus;
- closed host-installed `llm` aliases over the existing LLM adapter;
- reject `source: "file-read"` and all legacy model/root/file provider config;
- prepare the provider registry to contain exactly the host-installed aliases
  when Slice C activates the cutover;
- credentials;
- pure provider preparation, then non-secret local preflight, followed by
  credential/resource acquisition only after every selected provider passes
  both barriers;
- manifest-only narrowing;
- data-class compatibility;
- safe local omission defaults without a shared merge/defaults block;
- resolved `--check` rows ordered by environment and alias; and
- validation-only assembly.

**Gate (Claim A):** host JSON and an ordinary manifest select the pinned
GitHub MCP Server over stdio, complete `--check`, and call one read-only tool
from PTC-Lisp with no Elixir registration change — the MCP-first Slice 3 gate.
Every concrete documented configuration validates against the shipped schemas,
and schema/runtime structural fixtures cannot drift.

A published third-party server is the gate rather than a local fixture on
purpose. A fixture and the client are written against the same reading of the
protocol, so they agree even when that reading is wrong; and the friction that
decides whether this platform is usable — wrapper process trees, servers that
chatter on stderr, tool descriptions and schemas outside the bounded callable
profile — only appears against a server this project did not write. The same
argument applies one level down: the Slice 1 HTTP interoperability target is
an independent SDK implementation for exactly this reason.

Reaching this gate means Claim A holds. An author can connect a new server
without Elixir, which is the platform thesis, independent of whether any
self-improvement work ever lands.

Static source, selection, and data-class checks happen before credentials are
resolved, sensitive snapshots are opened, stdio is spawned, or remote MCP is
contacted. Discovery is a later dynamic validation phase.

MCP-first Slices 4 and 5 are complete: private MCP feedback/exchange capture
and the filesystem sample/cutover are now shared foundations for the remaining
Code Scout flow.

### Pre-C prerequisite — Confined trusted file loading

**Status:** implemented. `PtcRunner.Kernel.ConfinedFile` owns path resolution
and the bounded read; `Manifest` uses it for the manifest, components,
contracts, and selected input and no longer references `FileCapability`. Host
config joins the same primitive when Slice B adds it.

- Extract a dedicated internal
  `ConfinedFile.read(root, relative_path, max_bytes)` primitive from the
  confinement logic currently reused through `FileCapability`.
- Use it directly for trusted host config, manifests, PTC-Lisp components,
  contracts, and selected input.
- Preserve canonical-root, traversal, symlink, replacement, size, and
  deterministic error behavior.
- Migrate `Manifest.read_relative` and equivalent trusted artifact reads
  before deleting `FileCapability`.

Two properties were previously incidental rather than enforced, and the
extraction makes them explicit:

- **Traversal was contained only because the frozen-snapshot lookup missed.**
  `resolve_relative` did not reject a `..` segment; the resulting key simply
  failed to match a snapshot entry. A primitive that reads directly has no
  such backstop, so `ConfinedFile` rejects empty, `.`, and `..` segments
  before resolving and re-checks the resolved absolute path against the root.
- **Reading one trusted file froze the whole root.** `Manifest.read_relative`
  built a `FileCapability`, which snapshots up to 4,096 entries and 32 MB, to
  return a single manifest. The primitive reads one file.

Trusted loading and the public provider also had different symlink policies:
`FileCapability` rejects links outright, while trusted loading follows them
while they stay inside the root. `ConfinedFile` keeps the trusted-loading
policy; Slice C later deleted `FileCapability`.

**Gate:** trusted artifact loading has no dependency on a model-visible
filesystem capability, and confinement tests pass against the extracted
primitive. Met: 24 focused confinement tests cover traversal, symlink escape
and cycles, size, UTF-8, replacement, and error distinctness.

### Slice C — Sample filesystem server

**Status:** implemented. The immutable TypeScript sample and reproducible
bundle have 18 conformance tests; a cross-language acceptance test exercises
all five tools through host JSON, manifest selection, stdio, and PTC-Lisp. The
implicit providers and `FileCapability` are removed, and examples use
host-installed aliases.

- implement immutable list/find/search/read/info tools;
- use one bounded in-memory UTF-8 snapshot, glob path filters, and literal
  content search;
- ship the TypeScript source, exact lockfile, reproducible bundle, and license
  metadata so a clean tutorial run performs no package install or download;
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

### Slice D — Classified inputs, result artifacts, and contracts

**Status:** implemented. `--output`, `--private-output`, `--private-mission`,
atomic no-clobber persistence, terminal suppression, and the §4.7 effective
run-class rule have landed. Provider policy is frozen during preparation;
sink incompatibility fails before preflight, credential resolution, process
spawn, or remote discovery, and the same class drives event and publication
policy. Manifest-relative input/result contracts compile once through a
bounded application profile. Input and overrides fail before provider
activity; successful `Result.value` validation runs after trace/private
inspection capture and before any result publication. The root-only tagged
decision union remains separate from MCP callable schemas.

- add `--output` and `--private-output`;
- keep the existing manifest-relative `--mission` input override and add the
  mutually exclusive trusted `--private-mission`;
- add input and `Result.value` schemas;
- implement the coarse effective run-class and sink-compatibility rule from
  §4.7;
- support the bounded tagged-union profile needed by candidate decisions;
- preserve the existing result projection;
- ensure no-clobber atomic persistence;
- keep private values off stdout and public artifacts; and
- cover failures after meaningful provider activity.

**Gate:** met. Normal values can be published explicitly, private values can
reach only an authorized private sink, and a typed candidate becomes validated
input to a later run without scraping stdout. Contract-failure coverage also
proves that provider activity remains traceable while the rejected value is
neither persisted nor attached to the error.

### Slice E — PTC snapshots and private human inspection

#### E1 — Shared snapshot/query sources

**Status:** in progress. The canonical half has landed:
`ptc_trace_snapshot` is a mission-only host installation, captures through the
existing `TraceSnapshot` owner, derives four fixed operations from its alias,
and delegates every query to `TraceLog`. The paired private inspection
snapshot/query layer and profile/manifest parity remain.

- adapt the existing trace owner into a provider builder;
- add `InspectionSnapshot` and fixed inspection query/capability modules
  without changing the inspection file format;
- capture trace first, then validate every captured inspection artifact
  against the matching captured canonical run before exposing a catalog;
- pair capability inputs/outputs in the query layer and preserve correlation
  IDs, source identities, deterministic ordering, byte limits, and
  source-bound cursors;
- reuse the authoritative `TraceLog` and `InspectionArtifact` parsers and
  correlation validator;
- enforce private data compatibility before opening sensitive sources; and
- prove profile-backed and manifest-backed sources return equivalent queries.

**Gate:** one ordinary manifest can correlate source, canonical trace, and
exact private inspection without a second parser or caller-side timestamp
join.

#### E2 — `inspection-analysis-v1`

- extract the current log-specific profile frontend, assembly attestation,
  session lifecycle, evaluation, and persistence into shared internal
  analysis-session machinery behind a closed profile registry;
- preserve the `log-analysis-v1` descriptor, grants, output, and lifecycle;
- add the fixed private profile with exactly `traces` and `inspection`
  directory resources, `log.core`, `inspection.core`, and the E1 read-only
  capabilities;
- require an attached interactive terminal and `--private-terminal` before
  source capture;
- reject non-interactive evaluation and JSONL output for the private profile
  in its first version;
- keep its physically separate analysis trace canonical and payload-free; and
- prove owner death, cancellation, source replacement, malformed artifacts,
  correlation failure, result bounds, and cleanup fail closed.

**Gate:** a human can use PTC-Lisp to page from a slow or repeated canonical
event to its exact model exchange, generated program, capability
arguments/results, and effective prelude, while no private payload appears in
the profile's own analysis trace.

### Slice F — MCP feedback and private exchange records

**Status:** implemented.

Complete MCP-first Slice 4:

- preserve safe bounded tool-error feedback;
- add private JSON-RPC exchange evidence;
- retain closed public errors; and
- propagate safe trace context.

**Gate:** the scout can see why a filesystem call failed and a private reviewer
can reconstruct the complete tool exchange.

### Slice G — Read-only Code Scout

**Status:** partly implemented. The shipped `cap` helpers and domain-blind
`agent.main` entry are complete; the application facades, schemas, fixtures,
and held-out evaluation remain.

- extend the shipped `cap` library with envelope-aware `unwrap!` and
  opaque-cursor `with-cursor` helpers;
- make that helper library composition-only rather than prompt-visible;
- add the domain-blind `agent.main` library and its explicit dependencies;
- add prompt-visible `repo` and `runs` facades over every selected raw source;
- expose opaque pagination cursors through every collection facade and test
  evidence that occurs only after the first page;
- keep page traversal explicit rather than adding `cap/paginate`;
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
- bind artifacts to candidate, fixture, provider, content snapshot, and bundle
  hashes, including an optional installation revision through the provider
  snapshot when present; and
- keep promotion external.

**Gate:** a candidate cannot pass solely by fixing cited cases while regressing
held-out cases.

### Later — Tasks and guarded writes

MCP Tasks are a natural fit for long test suites, indexing, CI, and approval
gates, but require the lifecycle and accounting design in the MCP-first plan.
Write tools remain a separate authority milestone.

## 12. Acceptance matrix

Rows that decide Claim A are reachable from Slice B; the rest belong to Claim
B and do not gate it.

| Case | Expected result |
| --- | --- |
| A pinned third-party MCP server is installed from host JSON and called from PTC-Lisp | Succeeds with no Elixir registration change — **Claim A** |
| No host config and no selected providers | Provider-free run remains valid |
| A manifest selects a provider without host config | Strict failure; there is no implicit `llm` or `file-read` fallback |
| A manifest uses legacy model/root/file provider config | Strict failure before provider activity |
| Human edits host config or manifest with schema-aware tooling | Completion and structural diagnostics come from the shipped version-matched schema |
| `$schema` changes or is omitted | No runtime fetch, authority change, or identity change |
| Schema-valid document violates references, ceilings, placement, or data flow | `--check` reports the semantic failure before provider activity |
| Host config declares `source: "file-read"` | Strict unknown-source failure; model-accessible filesystem operations require `source: "mcp"` |
| Host mapping declares an effect other than `read` | Structural failure; guarded writes are not V1 host grammar |
| PtcRunner reads host config, a manifest, component, contract, or selected input | Dedicated confined loader remains direct; MCP is not a bootstrap dependency |
| Unknown host source/transport | Fails before provider or model activity |
| Manifest supplies a command, endpoint, root, credential, or effect | Strict manifest failure |
| Manifest selects an uninstalled provider/tool or raises a ceiling | Assembly failure |
| Any selected provider fails pure preparation | No credential, sensitive snapshot, subprocess, network endpoint, or model is touched |
| An ordinary provider omits `data_class`/`accepts_data`, a mapped tool omits `model_visible`, or stdio omits `env` | Resolves to normal-only, model-invisible, and no child credential bindings |
| Generated code names a selected model-invisible capability directly | Call succeeds; visibility filters the prompt catalog, not authority |
| First-slice manifest selects an MCP alias into workflow | Strict unsupported-environment failure; workflow-side MCP remains undecided |
| `--check` succeeds | Prints the resolved environment/alias/source view and safe identities, never raw secrets, roots, or private payloads |
| Sample filesystem changes after capture | Run continues to observe the frozen snapshot |
| Installation revision is omitted | Provider/trial identity uses the remaining safe provider and content identities |
| Present installation revision or content snapshot identity changes | Trial/provider identity changes |
| Secret, dependency, build, trace, or private-result path is not included | Workspace never opens or exposes it |
| Path traverses or crosses a symlink | Bounded tool error; no escaped data or host root |
| MCP server emits a malformed/oversized response | Closed provider failure and owned cleanup |
| MCP tool returns safe bounded argument feedback | Agent may correct it; public trace/error remains payload-free |
| Canonical trace source is malformed or changes during capture | Existing stable trace-source failure |
| Private artifact is malformed, replaced, oversized, or crosses a symlink | Closed private-source failure; no partial catalog |
| Inspection artifact has no exact captured canonical run/correlation | Entire inspection snapshot fails; no partial private catalog |
| Private source has an unapproved selected egress sink | Assembly fails before sensitive capture, MCP activity, or model calls |
| Private run selects any MCP provider without private acceptance | Assembly fails even when that MCP server is local and read-only |
| `inspection-analysis-v1` omits `--private-terminal`, has no attached terminal, or requests non-interactive output | Fails before canonical or private source capture |
| Private REPL evaluates a query | Value may reach only the explicitly authorized terminal; its analysis trace retains metadata, never the private payload |
| `log-analysis-v1` is selected after the profile refactor | Existing descriptor, resources, capabilities, output, and lifecycle remain unchanged |
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

1. **Live evaluation policy.** Decide minimum repetitions, confidence
   reporting, and acceptable regression thresholds per application. The
   platform only guarantees pinned configuration, fresh runs, and attributable
   artifacts; it does not declare statistical significance.
2. **Reusable application distribution.** Manifest-relative components are
   enough for the first application. Defer a component catalog until copying
   local PTC-Lisp is a demonstrated problem.
3. **Evaluation orchestration.** Keep the visible shell recipe while it passes
   candidate, override, and trial artifacts between explicit `ptc.run`
   invocations. Revisit generic orchestration when the recipe needs a fourth
   distinct intermediate artifact type or another repeated
   synthesis/aggregation stage; that is the tripwire, not the current command
   count.
4. **Tasks.** Decide whether a durable MCP task may outlive its PtcRunner run
   before advertising the extension.
5. **Writes.** Decide approval, retry, partial-effect, and disposable-workspace
   rules before mapping the first `effect: write` tool.
6. **Workflow-side MCP.** The first application selects MCP only into mission
   because generated programs use the filesystem tools. Keep the host
   installation flat and retain explicit manifest `workflow`/`mission`
   selections. Decide later whether a planning-time knowledge MCP provider may
   enter workflow; do not collapse the two manifest lists or derive placement
   from source kind before that decision.

## 14. No-Elixir completion tests

### 14.1 Claim A — assembled from data

Settled at Slice B, confirmed at Slice C. A clean installed PtcRunner must:

- run ordinary `mix ptc.run` with no `.ex` or task-specific Mix file change
  for the application;
- install a published third-party MCP server — the pinned GitHub MCP Server
  over stdio — entirely through host JSON;
- resolve its credential through a host binding, keeping it out of every
  public artifact;
- complete every static `--check` validation before any credential is
  resolved or process spawned, then allow the checked acquisition/discovery
  phase to use the declared binding;
- select and narrow that server from an ordinary manifest;
- call one read-only tool from PTC-Lisp; and
- tear down the process tree cleanly.

Nothing in this test requires a trace snapshot, private inspection profile,
candidate contract, or evaluation loop. It is the platform thesis on its own,
and it is the point after which new applications are an authoring exercise
rather than an Elixir exercise.

### 14.2 Claim B — improves itself from evidence

Settled at Slice H. The Code Scout files must additionally satisfy all of the
following:

- everything in §14.1 still holds, now with host JSON installing the MCP
  filesystem server, PTC snapshots, and approved LLM;
- no public `file-read` provider or host source remains;
- local PTC-Lisp discovers relevant files and traces without prelisted
  answers;
- exact private conversation and MCP evidence is available only under explicit
  private authority;
- after the generic private inspection profile is implemented once, a human
  can inspect that exact evidence first in `ptc.repl` and an automated review
  can independently reconstruct it through the same bounded source queries;
- the bounded result may decline a change or emit an inert content-addressed
  candidate;
- separate generic invocations evaluate baseline and exact candidate with
  replay fixtures and fresh held-out live trials, then aggregate their
  artifacts;
- replication rules, proposal review, and other improvement-method changes can
  be versioned as application JSON, PTC-Lisp, schemas, fixtures, and scripts
  without changing Elixir; and
- applying or promoting the candidate remains an explicit host/human write
  decision.
