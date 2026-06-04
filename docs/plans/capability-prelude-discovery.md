# Capability Prelude, Sandbox Profiles, and Namespace Discovery Requirements

## Purpose

PtcRunner should support configurable agent environments where deployments can
define sandbox-visible APIs through PTC-Lisp preludes, structured descriptors,
sandbox profiles, and runtime discovery. The foundational work is
descriptor-backed prelude discovery; the target architecture is a generic
capability environment where sandbox profiles, runtime preludes, authoring
preludes, and SubAgent definitions are distinct concepts.

The goal is to let deployments define sandbox-facing APIs such as workflow
coordination, catalog browsing, resource reads, event publication, and
agent-to-agent calls without hard-coding each API into PtcRunner core. Agents
should explore the sandbox they run inside, not infer capability authority from
SubAgent prompt configuration.

PTC-Lisp programs should be able to discover Lisp-facing APIs using familiar
Clojure-style documentation and namespace reflection forms. Larger or
non-Lisp-facing host catalogs may also be discoverable through structured
catalog operations, but typed `tool/` calls, `data/` bindings, and prelude
functions should remain the primary LLM steering surface until benchmarks prove
that a replacement is better.

The same descriptor substrate should eventually support developer-authored and
LLM-authored preludes. Higher-level forms such as `defagent`, `defsandbox`, and
`defcap` should be provided by a bundled PTC-Lisp authoring prelude rather than
being hard-coded evaluator special forms.

## Problem

Today, agent inputs are split across several channels:

- `context` values rendered as `data/` bindings.
- native Elixir tools rendered as `tool/` calls.
- SubAgents wrapped as tools.
- upstream MCP/OpenAPI servers discovered through `(tool/servers)`, `dir`,
  `doc`, `meta`, and `apropos`.
- session memory and journal state carried separately.

These channels are useful and should not be torn up prematurely. The immediate
problem is that deployment-specific helper APIs, docstrings, visibility, and
namespace discovery are not first-class enough for generic workflows. Agents
should be able to inspect curated sandbox APIs without receiving the full
prelude source or a prompt-stuffed tool catalog.

There is also a current conceptual overlap between SubAgent configuration and
runtime capability configuration. A SubAgent definition should describe the LLM
loop and task contract. A sandbox profile should describe what Lisp code can
see, call, discover, and spend while running.

## Delivery Phasing

This requirement should be implemented incrementally. Each stage should ship
value independently and keep the existing `tool/` and `data/` contracts working.

1. Add descriptor metadata on `def`, `defn`, and configured namespace
   declarations. Surface descriptors through existing `doc`, `dir`, `meta`,
   `apropos`, and `ns-publics` paths where possible.
2. Add user/prelude namespaces plus `all-ns` and `ns-name`, reusing the existing
   discovery registry shape.
3. Add a protected prelude loader, including `mix ptc.repl --prelude` and
   `--show-prompt-inventory`, before integrating with SubAgent runtime prompts.
4. Introduce an explicit sandbox profile descriptor that gathers tools, data
   bindings, namespaces, preludes, limits, and discovery policy. Existing
   `SubAgent.Definition` fields may continue to populate this profile during the
   migration.
5. Add descriptor-driven sandbox prompt inventory rendering. Prompt-visible
   descriptors should be rendered into the SubAgent prompt, while discoverable
   descriptors remain queryable through namespace reflection or catalog forms.
6. Add a minimal authoring substrate, such as `ptc.author/declare!`,
   `ptc.author/descriptors`, `ptc.author/schema`, and
   `ptc.author/validate`.
7. Implement bundled authoring conveniences such as `defcap`, `defsandbox`, and
   `defagent` in PTC-Lisp on top of the authoring substrate.
8. Add an LLM-authored prelude workflow: generate, validate, diff, compile,
   hash, and install descriptor proposals only when host policy accepts them.
9. Add or expand generic structured capability discovery only after workflow
   benchmarks show that typed `tool/`, `data/`, and prelude namespaces are
   insufficient.

## Requirements

### Glossary

- execution sandbox: the existing BEAM runtime isolation boundary for PTC-Lisp
  execution, including timeout, heap/memory limits, atom hardening, and
  recoverable error behavior;
- sandbox profile: the capability/environment profile selected for a run. It
  chooses namespaces, tools, data bindings, runtime preludes, limits, discovery
  policy, and prompt inventory from host-granted authority;
- runtime prelude: PTC-Lisp code compiled into the sandbox profile and loaded
  before ordinary user/agent programs;
- authoring prelude: PTC-Lisp code, including `ptc.author` and `ptc.prelude`,
  used while compiling descriptor proposals;
- deployment prelude: developer- or LLM-authored prelude source for a specific
  deployment;
- compiled prelude artifact: validated, frozen runtime namespace definitions
  plus accepted descriptors, hashes, provenance, and host-policy decisions;
- host capability catalog: the host's broader inventory of possible
  capabilities and providers before sandbox selection;
- host policy: the grant, denial, narrowing, credential, effect, model, and
  limit rules applied to catalog entries and descriptor proposals.

### 1. Core Model

PtcRunner should distinguish five concepts:

- host capability catalog: inventory of possible providers, tools, upstream
  operations, data bindings, built-in tool families, SubAgent definitions, and
  other descriptors known to the host;
- host policy: grants real authority, including tools, effects, upstreams,
  model access, resource limits, and maximum prompt exposure;
- sandbox profile: selects and shapes granted authority into a Lisp runtime,
  including namespaces, tools, data bindings, runtime preludes, limits, and
  discovery visibility;
- prelude: PTC-Lisp code loaded into an authoring or runtime sandbox. Runtime
  preludes define functions and namespaces. Authoring preludes declare
  descriptors and higher-level configuration intent;
- SubAgent definition: defines LLM-loop behavior, including prompt, signature,
  model, max turns, output mode, retry policy, compaction, and the selected
  sandbox profile.

Capabilities belong to sandbox profiles. SubAgent definitions may select,
derive, or narrow a sandbox profile, but should not be the primary owner of
tools, namespaces, or discovery state in the long-term model.

Prompt assembly should combine two projections:

- SubAgent prompt state: task instructions, output contract, loop mechanics,
  retry/turn behavior, and any agent-specific prompting policy;
- sandbox prompt inventory: prompt-visible capability descriptors, namespace
  summaries, data-binding summaries, tool/server summaries, budget information,
  and discovery hints for queryable capabilities.

The prompt should be a rendered view of the selected sandbox profile and the
SubAgent definition. It should not be an independent capability registry.

Existing `%PtcRunner.SubAgent.Definition{}` fields such as `tools`,
`builtin_tools`, `timeout`, `max_heap`, and `memory_limit` currently do double
duty. That is acceptable during migration, but the target design should move
runtime-environment fields toward a first-class sandbox profile.

### 2. Descriptor Model and Capability View

PtcRunner should maintain structured descriptors for functions, constants,
namespaces, tools, resources, agents, upstream servers, and future host
capabilities. Prompt rendering, REPL discovery, traces, and catalog responses
should be projections of descriptor data rather than separate hand-written
inventories.

Descriptor classification should use three axes, not one overloaded `kind`
field:

- `descriptor_type`: closed structural role that PtcRunner core knows how to
  render, validate, compile, or enforce;
- `provider_kind`: open implementation/provider tag for capabilities;
- `facets`: open capability verbs and traits such as `:callable`,
  `:queryable`, `:appendable`, `:readable`, `:persistent`, `:streamable`, and
  `:idempotent`.

Initial `descriptor_type` values should be closed and core-owned:

- `:capability`: something a sandbox can expose for reading, querying,
  appending, calling, or similar operations;
- `:namespace`: a Lisp-facing namespace and its public/protected symbols;
- `:sandbox_profile`: a selected and narrowed runtime environment;
- `:agent_definition`: an authored runnable SubAgent specification;
- `:tool_server`: an upstream MCP/OpenAPI/tool-server container with lifecycle,
  health, auth, and operation descriptors.

Deployment authoring forms such as `defworker`, `defworkflow`, or `defrole`
must expand to existing core `descriptor_type` values. Deployments may extend
`provider_kind`, `facets`, descriptor schemas, and `:ext` metadata, but should
not mint new `descriptor_type` values without a PtcRunner core change.

Example capability provider kinds:

- `:data_binding` for values surfaced through `data/`.
- `:native_tool` for Elixir tools surfaced through `tool/`.
- `:builtin_tool` for built-in tool families such as `:grep`.
- `:prelude_function` for callable PTC-Lisp functions exported by a prelude.
- `:subagent` for callable SubAgents backed by an `:agent_definition`.
- `:mcp_tool` and `:openapi_operation` for upstream tool-server operations.
- deployment/provider-specific kinds such as `:grpc_method`.

Capabilities should use `provider_ref` or `backed_by` to point at the backing
implementation or definition. For example, a callable SubAgent capability has
`descriptor_type: :capability`, `provider_kind: :subagent`, `facets:
[:callable]`, and `provider_ref` pointing at an `:agent_definition` descriptor.
This mirrors the current distinction between `%SubAgent.Definition{}` and a
SubAgent-as-tool projection.

Descriptors may also use `requires` for dependency edges. A prelude function
that wraps `tool/workflow-claim-task` should declare or infer that dependency so
prelude compilation can fail fast when the selected sandbox does not grant the
backing capability.

Existing `context`, `tools`, SubAgent-as-tool, and upstream runtime inputs may
be represented in this descriptor view, but `data/`, typed `tool/name` calls,
and prelude functions should remain callable. A future `cap` or `catalog`
namespace should initially be a unified discovery view and escape hatch, not the
main call path. The rich internal descriptor axes should not be exposed
verbatim as the default LLM-facing query vocabulary. Catalog search should
present a curated projection with friendly filters and names while preserving
the richer descriptor data for validation, rendering, traces, and debugging.

### 3. Layered Preludes

PtcRunner should ship layered, domain-blind preludes:

- `ptc.core`: the stable runtime language surface available to normal
  SubAgent execution. It includes selected Clojure-compatible helpers, safe PTC
  runtime functions, and stable discovery mechanics.
- `ptc.author`: a small stable descriptor-construction substrate available in
  prelude authoring mode.
- `ptc.prelude`: PTC-Lisp conveniences built on `ptc.author`, such as
  `defcap`, `defsandbox`, `defagent`, and `defnamespace`.
- deployment prelude: developer-authored or LLM-authored PTC-Lisp that defines
  runtime namespaces and/or descriptor proposals using `ptc.prelude`.
- `user`: mutable working namespace for ordinary agent code.

`ptc.prelude` should usually be available only while compiling or validating a
prelude. Normal SubAgent execution should receive `ptc.core`, the compiled
deployment/runtime prelude, and the sandbox profile's selected `tool/`, `data/`,
`budget/`, and other configured namespaces.

Higher-level authoring forms should not be hard-coded evaluator special forms
unless there is no reasonable library implementation. They should expand to a
small stable descriptor API so deployments can define their own forms such as
`defworker`, `defworkflow`, or `defrole` without changing PtcRunner core.

### 4. Authoring Substrate

The authoring substrate should be intentionally small and data-oriented. A
possible initial namespace is `ptc.author` with primitives such as:

```clojure
(ptc.author/declare! descriptor-map)
(ptc.author/descriptors)
(ptc.author/descriptor id)
(ptc.author/schema descriptor-type)
(ptc.author/validate descriptor-map)
```

`declare!` records descriptor intent in the prelude compilation artifact. It
must not grant permissions, mutate a live production sandbox, or bypass host
policy. Host/deployment config remains authoritative for exposure,
permissions, model access, effect policy, and resource limits.

Example low-level descriptor declarations:

```clojure
(ptc.author/declare!
 {:descriptor-type :namespace
  :id 'workflow
  :doc "Workflow helpers."
  :visibility :prompt})

(ptc.author/declare!
 {:descriptor-type :sandbox-profile
  :id 'workflow/runtime
  :uses ['ptc.core 'workflow]
  :tools ['workflow/ready-tasks]
  :limits {:timeout-ms 1000}})

(ptc.author/declare!
 {:descriptor-type :agent-definition
  :id 'workflow/worker
  :sandbox 'workflow/runtime
  :signature "[] -> map"
  :max-turns 6
  :prompt "Claim and complete the next available workflow task."})

(ptc.author/declare!
 {:descriptor-type :capability
  :id 'workflow/worker-call
  :provider-kind :subagent
  :provider-ref 'workflow/worker
  :facets [:callable]
  :signature "[] -> map"
  :visibility :discoverable})
```

The bundled authoring prelude may provide nicer forms on top:

```clojure
(defagent worker
  "Claim and complete the next available workflow task."
  {:sandbox 'workflow/runtime
   :signature "[] -> map"
   :max-turns 6
   :visibility :discoverable
   :prompt "Claim and complete the next available workflow task."})
```

`defagent` should compile to a descriptor that can become a
`%PtcRunner.SubAgent.Definition{}` or a sibling internal descriptor after host
validation. If the authored agent should be callable from another sandbox, the
compiler should also emit or accept a separate `:capability` descriptor with
`provider_kind: :subagent` and `provider_ref` pointing at the
`:agent_definition`. `defsandbox` should compile to a sandbox profile proposal.
`defcap` should compile to a callable or discoverable capability descriptor.
None of these forms should create authority by themselves.

Generated preludes should be handled as descriptor proposals:

1. run authoring code in a restricted prelude-authoring sandbox;
2. collect descriptors and runtime namespace definitions;
3. validate schemas and host policy;
4. resolve backing capabilities;
5. freeze protected namespaces;
6. record source hash, descriptor hash, host-policy hash, and provenance;
7. install only the accepted compiled artifact.

### 5. Configurable Runtime Prelude

PtcRunner should support a configured prelude loaded before user programs.

The prelude should be written in PTC-Lisp and may define functions, constants,
and namespaces that create the sandbox-facing API for a deployment.

Example:

```clojure
(defn workflow-ready-tasks
  "Return tasks in a workflow that are ready to be claimed."
  [workflow-id]
  (tool/workflow-ready-tasks {:workflow-id workflow-id}))

(defn workflow-claim-task!
  "Atomically claim a task for a worker. Returns nil if already claimed."
  [task-id worker-id]
  (tool/workflow-claim-task {:task-id task-id
                             :worker-id worker-id}))
```

The prelude should define policy and convenience functions. Host-owned
capabilities should remain responsible for effects, persistence, permissions,
idempotency, and resource limits.

Prelude code may declare sandbox-facing metadata inline, but host configuration
must remain authoritative for exposure, permissions, and prompt budget policy.
Inline metadata is a convenient authoring surface, not a security boundary.

Example descriptor metadata in PTC-Lisp:

```clojure
(ns workflow
  "Durable task graph helpers for multi-agent workflows."
  {:visibility :prompt
   :prompt-group :workflow
   :priority 100})

(defn workflow-next-action
  "Return the next recommended workflow action."
  {:visibility :prompt
   :effect :read
   :signature "[workflow-id worker-id] -> map"
   :priority 100}
  [workflow-id worker-id]
  ...)

(defn workflow-task-history
  "Return the event history for a task."
  {:visibility :discoverable
   :effect :read}
  [task-id]
  ...)
```

Host/deployment config should be able to provide defaults, overrides, and
validation policy for prelude metadata. A reasonable merge order is:

1. runtime facts, such as callable arity and actual capability provider;
2. host overrides;
3. prelude metadata;
4. namespace defaults;
5. global defaults.

Bad descriptors should fail fast at prelude load time. Examples include unknown
descriptor keys, invalid visibility values, duplicate public IDs, invalid
signatures, and metadata that conflicts with host policy.

Descriptor schemas should reserve an extension area, such as `:ext` or
namespaced `:x-*` fields, for tolerated deployment-specific or future metadata.
Unknown top-level descriptor keys should fail fast so typos do not silently
change prompt or discovery behavior.

### 6. Docstrings and Metadata

PTC-Lisp should support Clojure-style docstrings and metadata for:

- `def`
- `defn`
- configured namespaces

Examples:

```clojure
(def workflow-timeout-ms
  "Default workflow operation timeout in milliseconds."
  5000)

(defn complete-task!
  "Mark a task complete and attach its result reference."
  [task-id result-ref]
  ...)
```

Namespace documentation should also be supported.

Example shape:

```clojure
(ns workflow
  "Durable task graph helpers for multi-agent workflows.")
```

If full Clojure `ns` support is out of scope, an equivalent prelude manifest or
PTC-specific namespace declaration may be used, but it should still surface as
namespace metadata through discovery.

Metadata should be represented internally as structured descriptors rather than
prompt text. Prompt rendering, REPL discovery, traces, and capability catalog
responses should all be projections of the same descriptor data.

Metadata support should be limited to definition and namespace descriptors in
this track. Arbitrary runtime metadata on values is not required and should not
be introduced as part of prelude discovery.

### 7. Custom Namespaces

Configured preludes should be able to expose custom namespaces such as:

- `workflow`
- `catalog`
- `journal`
- `memory`
- `agent`
- deployment-specific namespaces

Agents should be able to discover these namespaces and their public symbols
without receiving the full source code in the prompt.

Configured namespaces should be protected unconditionally in the initial design.
User programs must not be able to redefine configured namespaces, public
prelude exports, or hidden internal bindings. Redefinition should raise a
programmer fault with a clear message.

Reserved namespaces include at least:

- `clojure.core`
- `tool`
- `cap` or the chosen structured catalog namespace
- `data`
- `budget`
- `ptc.core`
- `ptc.author` in authoring mode

The `user` namespace may remain mutable for interactive work and model-defined
helpers. Shadowing ordinary user bindings is allowed. Per-namespace protection
configuration can be added later if a concrete need appears.

### 8. Clojure-Style Namespace Discovery

PTC-Lisp should support a useful subset of Clojure namespace reflection for
configured and local PTC namespaces.

Required forms:

```clojure
(all-ns)
(ns-name n)
(ns-publics n)
(meta v)
```

The supported behavior may be a subset of Clojure's behavior, but it should
preserve the common REPL pattern:

```clojure
(doseq [n (sort-by ns-name (all-ns))]
  (println "\n" (ns-name n))
  (doseq [[sym v] (sort-by key (ns-publics n))]
    (println " " sym "-" (or (:doc (meta v)) ""))))
```

`all-ns` should return only curated Lisp-facing namespaces available inside the
PTC-Lisp environment. It must not expose upstream server names, implementation
modules, BEAM modules, Java classes, provider internals, or every backing
capability.

`ns-publics` should return var-like values with metadata so that `(meta v)`
works naturally.

`meta` should support both common discovery styles:

```clojure
(meta 'workflow/workflow-next-action)
(meta (get (ns-publics 'workflow) 'workflow-next-action))
```

The var-like values returned by `ns-publics` do not need to expose BEAM or Java
runtime internals. They only need stable identity, display formatting, and
metadata sufficient for discovery and documentation.

Refs should use one canonical lexical shape for Lisp symbols and one for host
capabilities:

- Lisp-facing symbols: `namespace/symbol`, such as `workflow/workflow-next-action`.
- Host capabilities: `provider/id`, such as `store/workflow`.

`doc`, `meta`, `apropos`, namespace discovery, and structured catalog
operations should normalize refs consistently.

### 9. Discovery Visibility Policy

Each function, constant, namespace, and capability should be configurable for
visibility.

Visibility is evaluated in the context of a sandbox profile. The same host
capability may be prompt-visible, discoverable, hidden, or unavailable depending
on which sandbox selected it and how host policy narrowed that selection.

At minimum, distinguish:

- prompt-visible: included in the sandbox prompt inventory rendered into the
  generated prompt.
- discoverable: hidden from the initial prompt but available through `doc`,
  `dir`, `meta`, `apropos`, `all-ns`, or structured catalog search.
- hidden/internal: not exposed to agent programs except through other prelude
  functions.
- unavailable: present in a broader host catalog but not selected into this
  sandbox profile.

Availability and visibility are related but distinct. `:unavailable` is derived
from sandbox selection and host policy, not authored prompt visibility. For
selected descriptors, effective visibility should be monotonic narrowing:

```text
prompt-visible > discoverable > hidden
```

The effective value should be no wider than host policy, sandbox profile
settings, namespace defaults, or descriptor metadata allow. A reasonable model
is:

```text
effective_visibility =
  narrowest(host_max_visibility,
            sandbox_visibility,
            descriptor_visibility,
            namespace_default,
            global_default)
```

Descriptor merging and sandbox narrowing should be separate phases. First,
runtime facts, host overrides, prelude metadata, namespace defaults, and global
defaults produce a canonical descriptor. Then sandbox selection and visibility
narrowing produce the per-sandbox effective view.

Example intent:

```clojure
;; Prompt-visible because it is the main workflow entry point.
(defn workflow-next-action
  "Return the next recommended workflow action."
  [workflow-id worker-id]
  ...)

;; Discoverable only because it is useful but too detailed for the prompt.
(defn workflow-task-history
  "Return the event history for a task."
  [task-id]
  ...)

;; Internal helper, not shown in prompt or discovery.
(defn normalize-task-id
  [task]
  ...)
```

The policy should support small prompts by default while still allowing agents
to inspect deeper APIs when needed.

Visibility is not permission. Hidden or discoverable status controls prompt and
discovery exposure only. Host capabilities must still enforce authorization,
effects, idempotency, and resource limits.

Hidden/internal should mean inaccessible to user programs except through other
exposed prelude functions. It should not merely mean "omitted from discovery".

### 10. Unified Discovery

Discovery should be split by responsibility:

- namespace reflection discovers Lisp-facing APIs;
- structured catalog operations discover host capabilities.

Duplicated discovery surfaces should be removed only after the replacement has
been proven by benchmarks and prompt behavior.

Expected forms:

```clojure
(dir 'workflow)
(doc 'workflow/workflow-claim-task!)
(meta 'workflow/workflow-claim-task!)
(apropos "claim task")
(ns-publics 'workflow)
```

For structured host-capability discovery, a generic namespace such as `cap` or
`catalog` may expose operations such as:

```clojure
(cap/list)
(cap/list {:kind :agent})
(cap/list {:kind :resource-store})
(cap/search "task workflow")
(cap/meta "store/workflow")
```

The exact names are an open decision. The high-level requirement is that agents
can discover both:

- Lisp-facing APIs, through namespace reflection and docs.
- backing host capabilities, through structured catalog search.

Typed tools and prelude functions remain the preferred call path. Generic
`cap/call` or `cap/query` should not replace typed tool contracts unless a later
benchmark demonstrates that the generic path improves reliability, prompt size,
or orchestration capability.

Capability provider kinds and facets should be extensible. The structural
`descriptor_type` axis is intentionally closed because PtcRunner core must know
how to render, validate, compile, or enforce each structural role. The
`provider_kind` and `facets` axes are open so future providers can participate
without changing the LLM-facing contract. For example, a future gRPC provider
can expose descriptors with `descriptor_type: :capability`, `provider_kind:
:grpc_method`, and `facets: [:callable]`.

Catalog operations should expose curated filters and aliases rather than
requiring agents to reason about the full internal descriptor schema. For
example, `cap/list {:kind :tool-server}` may remain a friendly query shape even
if the internal descriptor uses `descriptor_type: :tool_server`.

Capability IDs and namespaced Lisp symbols should use a canonical ref syntax.
The exact syntax is an open decision, but refs should be stable, unambiguous,
and accepted consistently by `doc`, `meta`, `apropos`, and structured catalog
operations.

### 11. Benchmark-Gated Tool-Server Discovery Migration

`(tool/servers)` duplicates generic capability discovery and should not remain
as a separate long-term surface.

Agents should discover upstream MCP/OpenAPI servers through generic capability
discovery:

```clojure
(cap/list {:kind :tool-server})
```

or a similarly named structured catalog form.

Upstream MCP/OpenAPI servers should become catalog providers in the descriptor
view. A server itself should be represented as `descriptor_type: :tool_server`
because it has lifecycle, health, auth, and connection state. Individual
operations exposed by that server should be `descriptor_type: :capability` with
provider kinds such as `:mcp_tool` or `:openapi_operation`.

If a migration window is needed while the implementation changes, it should be
short and explicit. The target design should contain one generic discovery
surface, not both `(tool/servers)` and capability listing.

Once generic capability discovery lands and benchmarks validate it, prompts and
docs should stop teaching `(tool/servers)`. During any short transition,
`(tool/servers)` may return a targeted error pointing agents to the replacement
form rather than remaining as a silent long-term alias.

This migration is limited to duplicated tool-server discovery. It does not imply
removing `tool/name` calls or `data/name` bindings.

### 12. Sandbox Prompt Inventory Policy

Prompt inclusion should be descriptor-driven and configurable per sandbox
profile. The prompt should not be the source of truth for capability metadata;
it should be a compact projection of the selected sandbox's descriptors.

SubAgent prompt construction should merge:

- agent-specific content: mission prompt, output contract, LLM-loop mechanics,
  transport instructions, and retry/turn guidance;
- sandbox-specific content: prompt-visible namespaces, functions, tools, data
  bindings, tool servers, budget limits, and discovery hints.

Queryable capabilities that are not prompt-visible should remain available
through namespace reflection or structured catalog operations when their
descriptor visibility allows discovery.

The static system prompt should explain only stable discovery mechanics:

- prompt-visible APIs are a partial sandbox inventory;
- more sandbox APIs may be available through namespace and capability discovery;
- use `doc`, `dir`, `apropos`, `ns-publics`, and structured catalog forms when
  details are needed;
- host capabilities enforce effects and permissions.

Core prompt text must remain domain-blind. Deployment-specific words such as
workflow, task graph, or benchmark-domain hints should come only from
descriptors, prelude source, or deployment config, never from the maintained
core system prompt. Tests should assert that maintained core prompt text does
not contain deployment- or benchmark-domain terms introduced by a prelude.

The dynamic context should render a compact prompt-visible projection of the
selected sandbox profile. Example policy shape:

```elixir
sandbox_prompt_inventory: [
  include: [
    :namespace_summary,
    :prompt_visible_symbols,
    :prompt_visible_tools,
    :prompt_visible_servers,
    :data_summary,
    :budget_summary
  ],
  groups: [:primary, :workflow],
  max_symbols: 12,
  max_bytes: 1200,
  include_effects: true,
  include_discovery_hint: true
]
```

Descriptor fields useful for prompt and discovery projections include:

```elixir
%{
  id: "workflow/workflow-next-action",
  descriptor_type: :capability,
  provider_kind: :prelude_function,
  provider_ref: "workflow/workflow-next-action",
  facets: [:callable],
  namespace: :workflow,
  visibility: :prompt,
  prompt_group: :workflow,
  priority: 100,
  doc: "Return the next recommended workflow action.",
  signature: "[workflow-id worker-id] -> map",
  effect: :read,
  requires: ["tool/workflow-ready-tasks"],
  version: "1.0.0",
  provenance: %{source_hash: "sha256:..."},
  ext: %{}
}
```

Prompt rendering should sort by configured group and priority, apply byte and
symbol caps deterministically, and include enough discovery guidance that the
agent can inspect omitted symbols when needed.

The same descriptor may have different prompt visibility in different sandbox
profiles. For example, a GitHub tool server may be discoverable in a general
engineering sandbox, prompt-visible in an issue-triage sandbox, and unavailable
in a document-analysis sandbox.

### 13. REPL and Local Testing Support

`mix ptc.repl` should support first-class sandbox and prelude testing once
configured preludes and sandbox profiles exist. Existing `-l/--load` should
remain a normal user-code load mechanism. Deployment and authoring preludes
should be loaded through distinct options so that protected namespaces,
descriptor metadata, visibility policy, sandbox prompt inventory, and prelude
trace metadata are exercised in the same way as SubAgent runtime execution.

The REPL should support at least two modes:

- authoring mode: loads `ptc.core`, `ptc.author`, `ptc.prelude`, host policy,
  and one or more deployment prelude sources. It compiles descriptor proposals
  and reports accepted, rejected, narrowed, and overridden descriptors.
- runtime mode: loads `ptc.core`, an already compiled runtime prelude artifact,
  the selected sandbox profile, and user code. It should match what a SubAgent
  would see during execution.

Runtime mode should also support LLM-backed capabilities when the selected
sandbox exposes SubAgents, LLM tools, or agent-backed catalog entries. The REPL
should make LLM availability explicit instead of silently stubbing calls. If an
evaluated form calls a SubAgent that requires an LLM and no LLM is configured,
the call should return a recoverable error that names the missing model or
credential requirement.

Credential and model configuration should be explicit and traceable. Supported
inputs may include environment variables, `.env` files, provider-specific
credential files, and CLI overrides. Secrets must not be printed in prompts,
descriptor dumps, traces, or error messages.

Expected REPL affordances:

```bash
mix ptc.repl --prelude workflow.clj
mix ptc.repl --prelude workflow.clj --capabilities capabilities.json
mix ptc.repl --author-prelude workflow.clj --host-policy policy.json
mix ptc.repl --sandbox workflow/runtime --prelude workflow.clj
mix ptc.repl --sandbox workflow/runtime --compiled-prelude .ptc/preludes/workflow.json
mix ptc.repl --sandbox workflow/runtime --llm openrouter:anthropic/claude-sonnet-4.5
mix ptc.repl --sandbox workflow/runtime --env-file .env
mix ptc.repl --sandbox workflow/runtime --llm-registry llms.json
mix ptc.repl --sandbox workflow/runtime --llm-dry-run
mix ptc.repl --prelude workflow.clj -e "(ns-publics 'workflow)"
mix ptc.repl --prelude workflow.clj --show-prompt-inventory
mix ptc.repl --author-prelude workflow.clj --show-descriptors
mix ptc.repl --author-prelude workflow.clj --explain-descriptor workflow/worker
mix ptc.repl --sandbox workflow/runtime --show-llm-config
```

Interactive meta commands may also expose:

- namespace listing;
- capability listing/search;
- selected sandbox profile and effective limits;
- rendered sandbox prompt inventory;
- raw and merged descriptors;
- descriptor validation errors and host-policy overrides;
- LLM provider/model availability for agent-backed capabilities;
- credential-source status with redacted values;
- prelude version/hash;
- compiled prelude artifact path/cache key;
- docs for prelude symbols and backing capabilities.

REPL support should use the same prelude loader and descriptor/capability
environment as SubAgent execution. Authoring-mode compilation should use the
same compiler and validator used for generated or deployment preludes. Runtime
mode should use the same compiled artifact and sandbox profile assembly path
used by SubAgents. It should not become a parallel implementation.

LLM-backed calls in the REPL should use the same adapter, retry, timeout,
telemetry, trace, and credential resolution path used by SubAgent execution.
This includes provider-specific configuration such as OpenRouter credentials and
model IDs. REPL-specific conveniences may select a default model or load local
credentials, but they should compile into the same runtime configuration shape
that a normal SubAgent run receives.

### 14. Safety and Runtime Enforcement

Prelude discovery must preserve the sandbox and atom-hardening discipline.
Namespace names, symbol refs, descriptor keys, and metadata-derived lookup keys
must not create an unbounded atom path. New symbols should go through bounded
vocabularies, explicit interning budgets, or safe string-backed refs consistent
with `SourceAtoms.intern/1`.

Descriptor `:effect` metadata must be more than a prompt hint. The enforced
effect must be host/runtime-resolved and fail closed. Prelude-declared effect
metadata is advisory and may document or narrow expected behavior, but it must
not weaken side-effect enforcement. A prelude wrapper around a write-capable or
unknown-effect backing capability remains write-capable or unknown-effect for
guard purposes unless host policy proves a narrower effect.

Write-capable or unknown-effect capabilities should feed the existing
side-effect and continuation/idempotency guards so prelude-wrapped writes are
treated like other side-effecting tool attempts.

Generic structured catalog calls must preserve the recoverable-result and
tagged-error contracts used by existing upstream/tool execution. Agents should
receive actionable error values, not opaque exceptions, whenever a host
capability can fail recoverably.

### 15. Traceability and Compile Cache

Prelude versions and hashes should be recorded in workflow traces, benchmark
outputs, and debugging records. Capability environment summaries should include
enough stable identifiers to reproduce which prelude and host descriptor policy
were active for a run.

Prelude compilation should be cacheable by content hash. A compiled prelude
should be reusable across sessions when the source, descriptor policy, and
capability environment hash match. Trace and debug output should record the
cache key or enough component hashes to reproduce it.

## Example Usage

### Author a Sandbox and Agent Descriptor

In prelude authoring mode, `ptc.prelude` may define forms such as `defsandbox`
and `defagent` on top of `ptc.author/declare!`:

```clojure
(ns workflow.author)

(defsandbox workflow-runtime
  "Runtime surface for workflow workers."
  {:uses ['ptc.core 'workflow]
   :tools ['workflow/ready-tasks
           'workflow/claim-task!
           'workflow/complete-task!]
   :limits {:timeout-ms 1000
            :max-heap-bytes 10000000}})

(defagent workflow-worker
  "Claim and complete one ready workflow task."
  {:sandbox 'workflow-runtime
   :signature "[] -> map"
   :max-turns 6
   :visibility :discoverable
   :prompt "Claim and complete one ready workflow task."})
```

Compilation records descriptors. Host policy then accepts, rejects, narrows, or
overrides the requested sandbox and agent settings before installation.

### Discover Available Namespaces

```clojure
(map ns-name (all-ns))
```

Possible result:

```clojure
(clojure.core tool cap workflow journal)
```

### List Workflow API

```clojure
(doseq [[sym v] (sort-by key (ns-publics 'workflow))]
  (println sym "-" (:doc (meta v))))
```

Possible output:

```text
workflow-ready-tasks - Return tasks in a workflow that are ready to be claimed.
workflow-claim-task! - Atomically claim a task for a worker. Returns nil if already claimed.
workflow-complete-task! - Mark a task complete and attach its result reference.
workflow-task-history - Return the event history for a task.
```

### Use Prompt-Visible Entry Point

```clojure
(let [action (workflow/workflow-next-action data/workflow-id data/worker-id)]
  (case (:type action)
    :claim-task (workflow/workflow-claim-task! (:task-id action) data/worker-id)
    :wait       (return {:status :idle})
    :finish     (return {:status :done})))
```

### Discover Backing Capabilities

```clojure
(cap/search "workflow task")
```

Possible result:

```clojure
[{:id "store/workflow"
  :kind :resource-store
  :description "Durable task graph and event store"
  :access [:query :append :call]}]
```

### Discover Upstreams

```clojure
(cap/list {:kind :tool-server})
```

## Non-Goals

- Full Clojure namespace loading, `require`, `refer`, `import`, or dynamic class
  loading.
- Exposing BEAM internals or arbitrary Java/Clojure runtime namespaces.
- Making prelude code a new trust boundary for effects.
- Replacing host-side permission checks with Lisp code.
- Granting new authority through `ptc.author/declare!`, `defagent`,
  `defsandbox`, `defcap`, or any other authoring-prelude form.
- Hard-coding high-level authoring forms such as `defagent` as evaluator special
  forms before proving they cannot be implemented cleanly in PTC-Lisp.
- Requiring RDF, OWL, or a graph database as the internal representation.
- Supporting arbitrary runtime value metadata, `with-meta`, `vary-meta`, or
  reader metadata (`^...`) as part of this track.
- Replacing typed `tool/name` calls or `data/name` bindings with generic
  capability calls before benchmark evidence justifies it.

## Open Decisions

1. Should the generic structured catalog namespace be named `cap`, `catalog`,
   or something else?
2. Should namespace declarations use a subset of Clojure `ns`, a PTC-specific
   form, or external config metadata?
3. Should `meta` on a capability return the same shape as `cap/meta`, or should
   var metadata and capability metadata remain distinct?
4. Can `(tool/servers)` be removed immediately when generic capability
   discovery lands, or is there a specific release/process constraint that
   requires a short removal window?
5. What is the canonical descriptor schema and validation behavior for inline
   PTC-Lisp metadata?
6. What sandbox prompt inventory defaults should be used when a deployment does
   not provide an explicit prompt policy?
7. Should `mix ptc.repl --prelude` accept only Lisp source, or also an external
   manifest that declares namespace metadata without executable prelude code?
8. What are the final namespace names for the bundled layers: `ptc.core`,
   `ptc.author`, and `ptc.prelude`, or shorter aliases?
9. Which current `%SubAgent.Definition{}` fields should move to a first-class
   sandbox profile first, and which should remain agent-loop configuration?
10. Should generated preludes install only after explicit host approval, or may
   some deployments allow automatic installation under a narrow policy profile?
11. Which closed `descriptor_type` values should ship first:
   `:capability`, `:namespace`, `:sandbox_profile`, `:agent_definition`,
   `:tool_server`, or a smaller set?
12. What deployment registration mechanism should validate open
   `provider_kind` values and any provider-specific descriptor schema?
13. Which catalog query filters should be exposed to LLMs as friendly aliases
   rather than raw internal descriptor axes?

## Benchmark Fit

This requirement supports a generic workflow benchmark where a configured
workflow prelude exposes task graph operations over a host-owned event/resource
store. Agents should discover the workflow API, claim and complete tasks once,
recover from retries, and produce a final result with provenance.

The benchmark can compare:

- prompt-stuffed tools/context versus discoverable prelude namespaces;
- hard-coded workflow tools versus prelude-defined workflow APIs;
- direct SubAgent tool configuration versus sandbox-profile-backed agents;
- developer-authored preludes versus LLM-authored descriptor proposals reviewed
  through the same compiler;
- direct tool-server discovery versus generic capability discovery;
- full prompt inventory versus discovery-on-demand visibility.

## Future Ideas

### Agent-Published Capabilities

A later version may let SubAgents propose capabilities discovered or authored
during a workflow. This should build on the same descriptor model and
authoring substrate, but remain out of the foundational prelude/discovery track
until lifecycle, permission, approval, and traceability rules are clear.

Example use cases:

- a SubAgent explores an upstream API and publishes a normalized PTC-Lisp helper
  function for other SubAgents;
- a SubAgent publishes a callable agent endpoint that wraps a multi-step
  workflow over upstream tools;
- a later SubAgent discovers a bug or improvement and publishes a corrected
  version;
- a debugging SubAgent inspects descriptor metadata, source, history, or an
  agent definition when policy allows it.

This should be modeled as descriptor proposal and mediated installation, not
direct mutation of another agent's namespace. Accepted APIs should be
descriptors plus mediated call targets. Other agents may discover and call them
according to visibility policy, but should not redefine them.

Possible Lisp-facing shape, if a later workflow allows publication-like
operations:

```clojure
(cap/publish
 {:id "weather/current-forecast"
  :descriptor-type :capability
  :provider-kind :prelude-function
  :provider-ref "weather/current-forecast"
  :facets [:callable]
  :namespace 'weather
  :symbol 'current-forecast
  :version "1.0.0"
  :provenance {:source-hash "sha256:..."}
  :visibility :workflow
  :effect :read
  :signature "[location date] -> map"
  :requires ["tool/weather-api-get"]
  :doc "Return normalized current forecast for a location/date."
  :source
  '(defn current-forecast [location date]
     (let [raw (tool/weather-api-get {:location location
                                      :date date})]
       {:temp-c (:temperatureC raw)
        :summary (:summary raw)
        :source :weather-api}))})
```

Possible agent-backed shape:

```clojure
(cap/publish
 [{:id "research/summarize-paper-definition"
   :descriptor-type :agent-definition
   :version "1.2.0"
   :signature "[paper-url question] -> map"
   :prompt-ref "agents/research-summarizer@sha256:..."
   :sandbox "research/runtime"
   :requires ["tool/fetch" "tool/pdf-text"]}
  {:id "research/summarize-paper"
   :descriptor-type :capability
   :provider-kind :subagent
   :provider-ref "research/summarize-paper-definition"
   :facets [:callable]
   :namespace 'research
   :symbol 'summarize-paper
   :version "1.2.0"
   :visibility :workflow
   :effect :read
   :signature "[paper-url question] -> map"
   :doc "Fetch, inspect, and summarize a paper for a specific question."}])
```

Calling agents should see the same stable surface regardless of whether the
implementation is a Lisp function, Elixir tool wrapper, or SubAgent endpoint:

```clojure
(weather/current-forecast "Stockholm" "2026-06-03")
(research/summarize-paper data/url "What are the limitations?")
```

Updates should be versioned rather than mutable in place:

```clojure
(cap/deprecate "weather/current-forecast" "1.0.0"
  {:reason "Incorrect temperature unit normalization."
   :replacement "weather/current-forecast@1.0.1"})
```

Deletion should usually mean revoking future discovery and calls, not erasing
history. Existing traces must remain resolvable.

Controlled inspection may expose diagnostic operations such as:

```clojure
(cap/meta 'weather/current-forecast)
(cap/source 'weather/current-forecast)
(cap/history 'weather/current-forecast)
```

Source and agent-definition visibility should be policy-gated separately from
call visibility. Published functions or SubAgent definitions may contain prompt
details, upstream assumptions, or other information that should only be
available to owners or debug-authorized agents.

Future design questions:

- publication scopes, such as owner-only, sibling-visible, workflow-visible, or
  global;
- how published Lisp source is compiled, cached, protected, and revoked;
- how agent-backed capabilities preserve side-effect and idempotency ledgers;
- how conflicts are resolved when multiple agents publish the same namespace or
  symbol;
- how source inspection redacts secrets, prompt internals, or sensitive
  deployment assumptions;
- whether callers pin versions explicitly or resolve latest compatible versions.
