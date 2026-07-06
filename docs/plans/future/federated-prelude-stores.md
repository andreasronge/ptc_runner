# Federated Prelude Stores for Many-Model Capability Libraries

**Status:** future direction, not committed work. This doc sketches a long-term
model where PreludeStore-like registries become the versioned capability layer
shared across many models, sessions, teams, and upstream providers.

## Problem

As ptc_runner deployments scale beyond one model and one local experiment,
capability preludes become more valuable than prompt prose. A prelude can wrap
raw MCP/OpenAPI tools into a stable Lisp-facing namespace, hide irrelevant API
details, expose bounded discovery, carry versioned source/checksums, and make
capability changes testable.

The current store is intentionally small: volatile, in-process, compile-on-write,
and host-gated. That is enough for local iteration and MCP-native improvement
loops, but not enough for a fleet where many models should share curated,
versioned capability libraries.

## Direction

Treat prelude stores as **capability registries**, not as authority systems.

The registry supplies source, compiled metadata, versions, dependencies,
checksums, provenance, docs, and test evidence. Authority still comes from the
host session's granted tools and upstream runtime. A prelude may declare that an
export requires `tool:<name>` or `upstream:<server>/<tool>`, but selecting the
prelude must not grant those capabilities by itself.

Preferred future shape:

1. Remote registries expose prelude metadata and source artifacts.
2. A local ptc_runner instance imports selected artifacts.
3. Imported preludes are compiled, checksum-verified, and stored locally.
4. Sessions attach from the local resolved store using explicit pins.
5. Runtime authority is validated against the local session's granted tools and
   upstream runtime.

Avoid live remote resolution during session attach. Import-and-pin keeps runs
reproducible and makes failures debuggable even if a remote registry changes or
goes down.

## Use Cases

### Model-specific capability packs

Different models can receive different abstraction levels over the same raw
systems. A small model might get narrow exports such as
`crm/find-risky-renewals`, while a stronger model gets lower-level `crm/search`,
`crm/get-account`, and debugging helpers. The backend APIs remain the same; the
selected prelude pack changes.

### Organization and domain libraries

Teams can publish namespaces such as `github-review/`, `incident/`,
`observability/`, `finance/`, or `salesforce/`. Agents attach the relevant
namespace set instead of rediscovering raw API shapes each run.

### Tool-surface normalization

Different MCP servers often expose inconsistent names, schemas, and error
models. Capability preludes can normalize them into stable Lisp APIs, so models
learn `ticket/search` rather than every vendor's raw tool shape.

### A/B testing and promotion

Run `paged@7` against `paged@8` across many tasks and model families, compare
traces and final answers, then promote a default only after evidence. The store
becomes a measurable capability rollout system.

### Policy-tiered access

Attach read-only libraries broadly (`prelude/read`, `log/read`,
`observability/read`) while reserving mutation libraries (`prelude/write`,
`incident/remediate`) for trusted sessions or approval flows.

### Generated helper promotion

Mission-local helpers that recur across successful runs can be extracted,
reviewed, tested, and promoted into a shared prelude store. This is the durable
"slow loop" for model-authored capabilities.

### Offline reproducibility

Traces can record exact prelude pins and checksums. A failed or surprising run
can be replayed later with the same capability surface even if remote defaults,
upstream APIs, or model versions changed.

## What This Enables

- smaller prompts with less repeated API explanation;
- more stable behavior across model providers and model sizes;
- reusable domain capabilities instead of copy-pasted task logic;
- measured rollout, rollback, and promotion of capability changes;
- shared improvement loops where models inspect and propose changes through the
  same protocol they use to execute;
- clearer separation between "what API does the model see?" and "what authority
  did the host grant?"

## Problems to Investigate

### Registry trust and provenance

Who can publish a prelude? What review state is attached? Should artifacts be
signed? Which metadata is trusted by the host, which is merely prompt-facing,
and which is discarded on import?

### Dependency and version conflicts

If one selected prelude requires `base@2` and another requires `base@3`, the
simple answer is to fail closed. At scale, investigate whether version aliases,
compatibility ranges, or isolated dependency worlds are worth the complexity.

### Authority propagation

Transitive `requires` and `tool_refs` must stay airtight across prelude
dependencies and imported artifacts. A registry is useful only if it cannot hide
authority requirements behind friendly wrapper names.

### Prompt inventory scaling

Many registries and namespaces cannot be dumped into every prompt. Need lazy
discovery, ranking, task-conditioned summaries, and model-specific capability
packs.

### Remote-store protocol

Define a narrow registry protocol: list/search metadata, read source by pinned
ref/checksum, read compiled public metadata, maybe read tests and promotion
status. Keep mutation separate and host-gated.

### Compatibility contracts

Classify breaking changes: deleted exports, arity changes, changed return
shape, changed upstream requirements, changed side-effect behavior, and behavior
changes not captured by signatures.

### Evaluation and promotion

A registry needs standard smokes, regression corpora, and per-model eval
matrices. Promotion should be evidence-backed, not just "latest write wins."

### Namespace governance

Decide whether namespaces are global, org-scoped, registry-scoped, or imported
under aliases. Collision policy needs to be simple enough for model-facing
discovery.

### Secret and data boundaries

Stored source and metadata are untrusted prompt surfaces. Remote preludes must
not smuggle credentials, leak secrets through docs/metadata, or induce unsafe
upstream calls. Credentials stay with the host runtime, never in the registry.

### Durable operations

Production stores need persistence, backups, retention, garbage collection for
pinned dependency versions, migration, and audit history. The current volatile
store is a good local iteration primitive, not the final registry substrate.

## Key Principle

A prelude store should be a **package registry for capability code**, not the
authority boundary. The host session grants tools and upstream runtimes; the
selected preludes describe and organize how the model may use those grants.
