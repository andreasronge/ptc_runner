# Capability Prelude and Namespace Discovery Requirements

## Purpose

PtcRunner should support configurable agent environments where deployments can
define agent-facing APIs through PTC-Lisp preludes, structured descriptors, and
runtime discovery. The foundational work is descriptor-backed prelude discovery;
a broader generic capability environment should be treated as a later,
benchmark-gated track.

The goal is to let deployments define agent-facing APIs such as workflow
coordination, catalog browsing, resource reads, event publication, and
agent-to-agent calls without hard-coding each API into PtcRunner core.

PTC-Lisp programs should be able to discover Lisp-facing APIs using familiar
Clojure-style documentation and namespace reflection forms. Larger or
non-Lisp-facing host catalogs may also be discoverable through structured
catalog operations, but typed `tool/` calls, `data/` bindings, and prelude
functions should remain the primary LLM steering surface until benchmarks prove
that a replacement is better.

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
should be able to inspect curated deployment APIs without receiving the full
prelude source or a prompt-stuffed tool catalog.

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
4. Add descriptor-driven prompt inventory rendering.
5. Add or expand generic structured capability discovery only after workflow
   benchmarks show that typed `tool/`, `data/`, and prelude namespaces are
   insufficient.

## Requirements

### 1. Descriptor Model and Capability View

PtcRunner should maintain structured descriptors for functions, constants,
namespaces, tools, resources, agents, upstream servers, and future host
capabilities. Prompt rendering, REPL discovery, traces, and catalog responses
should be projections of descriptor data rather than separate hand-written
inventories.

Example descriptor kinds:

- `:value` or `:resource` for read-only data values.
- `:resource-store` for queryable or addressable data.
- `:tool` for callable native functions.
- `:agent` for callable SubAgents.
- `:tool-server` for upstream MCP/OpenAPI servers.
- `:event-stream` or `:journal` for append/read event flows.
- `:namespace` for Lisp-facing APIs exposed by a prelude.

Existing `context`, `tools`, SubAgent-as-tool, and upstream runtime inputs may
be represented in this descriptor view, but `data/`, typed `tool/name` calls,
and prelude functions should remain callable. A future `cap` or `catalog`
namespace should initially be a unified discovery view and escape hatch, not the
main call path.

### 2. Configurable Prelude

PtcRunner should support a configured prelude loaded before user programs.

The prelude should be written in PTC-Lisp and may define functions, constants,
and namespaces that create the agent-facing API for a deployment.

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

Prelude code may declare agent-facing metadata inline, but host configuration
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

### 3. Docstrings and Metadata

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

### 4. Custom Namespaces

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

The `user` namespace may remain mutable for interactive work and model-defined
helpers. Shadowing ordinary user bindings is allowed. Per-namespace protection
configuration can be added later if a concrete need appears.

### 5. Clojure-Style Namespace Discovery

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

### 6. Discovery Visibility Policy

Each function, constant, namespace, and capability should be configurable for
visibility.

At minimum, distinguish:

- prompt-visible: included in the generated prompt or system prompt inventory.
- discoverable: hidden from the initial prompt but available through `doc`,
  `dir`, `meta`, `apropos`, `all-ns`, or structured catalog search.
- hidden/internal: not exposed to agent programs except through other prelude
  functions.

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

### 7. Unified Discovery

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

Capability kinds should be extensible. Avoid a closed enum where possible:
descriptors should support a coarse `kind` plus capability facets such as
`:callable`, `:queryable`, `:appendable`, `:readable`, `:persistent`,
`:idempotent`, and effect metadata such as `:read`, `:write`, or `:unknown`.
This allows future providers to participate without changing the LLM-facing
contract.

Capability IDs and namespaced Lisp symbols should use a canonical ref syntax.
The exact syntax is an open decision, but refs should be stable, unambiguous,
and accepted consistently by `doc`, `meta`, `apropos`, and structured catalog
operations.

### 8. Benchmark-Gated Tool-Server Discovery Migration

`(tool/servers)` duplicates generic capability discovery and should not remain
as a separate long-term surface.

Agents should discover upstream MCP/OpenAPI servers through generic capability
discovery:

```clojure
(cap/list {:kind :tool-server})
```

or a similarly named structured catalog form.

Upstream MCP/OpenAPI servers should become catalog providers in the descriptor
view.

If a migration window is needed while the implementation changes, it should be
short and explicit. The target design should contain one generic discovery
surface, not both `(tool/servers)` and capability listing.

Once generic capability discovery lands and benchmarks validate it, prompts and
docs should stop teaching `(tool/servers)`. During any short transition,
`(tool/servers)` may return a targeted error pointing agents to the replacement
form rather than remaining as a silent long-term alias.

This migration is limited to duplicated tool-server discovery. It does not imply
removing `tool/name` calls or `data/name` bindings.

### 9. Prompt Inventory Policy

Prompt inclusion should be descriptor-driven and configurable. The prompt should
not be the source of truth for capability metadata.

The static system prompt should explain only stable discovery mechanics:

- prompt-visible APIs are a partial inventory;
- more APIs may be available through namespace and capability discovery;
- use `doc`, `dir`, `apropos`, `ns-publics`, and structured catalog forms when
  details are needed;
- host capabilities enforce effects and permissions.

Core prompt text must remain domain-blind. Deployment-specific words such as
workflow, task graph, or benchmark-domain hints should come only from
descriptors, prelude source, or deployment config, never from the maintained
core system prompt. Tests should assert that maintained core prompt text does
not contain deployment- or benchmark-domain terms introduced by a prelude.

The dynamic context should render a compact prompt-visible projection of the
capability environment. Example policy shape:

```elixir
prompt_inventory: [
  include: [:namespace_summary, :prompt_visible_symbols],
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
  kind: :function,
  namespace: :workflow,
  visibility: :prompt,
  prompt_group: :workflow,
  priority: 100,
  doc: "Return the next recommended workflow action.",
  signature: "[workflow-id worker-id] -> map",
  effect: :read,
  facets: [:callable],
  provider: :prelude,
  ext: %{}
}
```

Prompt rendering should sort by configured group and priority, apply byte and
symbol caps deterministically, and include enough discovery guidance that the
agent can inspect omitted symbols when needed.

### 10. REPL and Local Testing Support

`mix ptc.repl` should support first-class prelude testing once configured
preludes exist. Existing `-l/--load` should remain a normal user-code load
mechanism. A deployment prelude should be loaded through a distinct option so
that protected namespaces, descriptor metadata, visibility policy, and prelude
trace metadata are exercised in the same way as SubAgent runtime execution.

Expected REPL affordances:

```bash
mix ptc.repl --prelude workflow.clj
mix ptc.repl --prelude workflow.clj --capabilities capabilities.json
mix ptc.repl --prelude workflow.clj -e "(ns-publics 'workflow)"
mix ptc.repl --prelude workflow.clj --show-prompt-inventory
```

Interactive meta commands may also expose:

- namespace listing;
- capability listing/search;
- rendered prompt inventory;
- prelude version/hash;
- docs for prelude symbols and backing capabilities.

REPL support should use the same prelude loader and descriptor/capability
environment as SubAgent execution. It should not become a parallel
implementation.

### 11. Safety and Runtime Enforcement

Prelude discovery must preserve the sandbox and atom-hardening discipline.
Namespace names, symbol refs, descriptor keys, and metadata-derived lookup keys
must not create an unbounded atom path. New symbols should go through bounded
vocabularies, explicit interning budgets, or safe string-backed refs consistent
with `SourceAtoms.intern/1`.

Descriptor `:effect` metadata must be more than a prompt hint. Write-capable or
unknown-effect capabilities should feed the existing side-effect and
continuation/idempotency guards so prelude-wrapped writes are treated like other
side-effecting tool attempts.

Generic structured catalog calls must preserve the recoverable-result and
tagged-error contracts used by existing upstream/tool execution. Agents should
receive actionable error values, not opaque exceptions, whenever a host
capability can fail recoverably.

### 12. Traceability and Compile Cache

Prelude versions and hashes should be recorded in workflow traces, benchmark
outputs, and debugging records. Capability environment summaries should include
enough stable identifiers to reproduce which prelude and host descriptor policy
were active for a run.

Prelude compilation should be cacheable by content hash. A compiled prelude
should be reusable across sessions when the source, descriptor policy, and
capability environment hash match. Trace and debug output should record the
cache key or enough component hashes to reproduce it.

## Example Usage

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
6. What prompt inventory defaults should be used when a deployment does not
   provide an explicit prompt policy?
7. Should `mix ptc.repl --prelude` accept only Lisp source, or also an external
   manifest that declares namespace metadata without executable prelude code?

## Benchmark Fit

This requirement supports a generic workflow benchmark where a configured
workflow prelude exposes task graph operations over a host-owned event/resource
store. Agents should discover the workflow API, claim and complete tasks once,
recover from retries, and produce a final result with provenance.

The benchmark can compare:

- prompt-stuffed tools/context versus discoverable prelude namespaces;
- hard-coded workflow tools versus prelude-defined workflow APIs;
- direct tool-server discovery versus generic capability discovery;
- full prompt inventory versus discovery-on-demand visibility.

## Future Ideas

### Agent-Published Capabilities

A later version may let SubAgents publish capabilities discovered or authored
during a workflow. This should build on the same descriptor model, but remain
out of the foundational prelude/discovery track until lifecycle, permission,
and traceability rules are clear.

Example use cases:

- a SubAgent explores an upstream API and publishes a normalized PTC-Lisp helper
  function for other SubAgents;
- a SubAgent publishes a callable agent endpoint that wraps a multi-step
  workflow over upstream tools;
- a later SubAgent discovers a bug or improvement and publishes a corrected
  version;
- a debugging SubAgent inspects descriptor metadata, source, history, or an
  agent definition when policy allows it.

This should be modeled as capability publication, not direct mutation of another
agent's namespace. Published APIs should be descriptors plus mediated call
targets. Other agents may discover and call them according to visibility policy,
but should not redefine them.

Possible Lisp-facing shape:

```clojure
(cap/publish
 {:id "weather/current-forecast"
  :kind :function
  :namespace 'weather
  :symbol 'current-forecast
  :version "1.0.0"
  :visibility :workflow
  :effect :read
  :signature "[location date] -> map"
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
 {:id "research/summarize-paper"
  :kind :agent
  :namespace 'research
  :symbol 'summarize-paper
  :version "1.2.0"
  :visibility :workflow
  :effect :read
  :signature "[paper-url question] -> map"
  :doc "Fetch, inspect, and summarize a paper for a specific question."
  :agent {:prompt-ref "agents/research-summarizer@sha256:..."
          :tools ["fetch" "pdf-text"]}})
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
