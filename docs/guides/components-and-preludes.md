# Components and preludes

A component is one immutable PTC-Lisp module. It declares a single namespace
and may depend only on the component IDs listed in its `dependencies` field.
Components compile together into the frozen bundle a run executes; preludes are
the shipped components a project selects instead of writing its own.

A project names its components in the manifest:

```json
"components": [
  {"id": "math", "path": "math.clj"}
]
```

```clojure
(ns math "Small arithmetic helpers." {:visibility :prompt})

(defn double [x] (* x 2))
```

Public `defn` and `def` forms become qualified exports. `defn-` remains
private to its namespace. Cross-component calls require both a declared
component dependency and a public export in the dependency.

Dependencies are real composition boundaries, not authority grants. A
component can call only the public namespaces of its direct dependencies. Once
the whole bundle is installed, evaluated PTC-Lisp can call every public export
in that bundle. `:visibility :discoverable` keeps an export out of model prompt
inventory; it does not make the export inaccessible. Evaluated code finds such
an export at runtime with `(dir)`, `(dir "ns")`, and `(apropos "term")`, and
reads its documentation with `(doc "ns/name")` or `(export-meta "ns/name")`.
Use it for exports that other components compose but a model should not have to
read past in every prompt.

## Declare the vocabularies a namespace emits

Canonical traces are payload-free, so an application failure kind reaches a
public error only as a one-way fingerprint and an application annotation is
rejected outright — unless the bundle declares it:

```clojure
(ns audit "Checks records against their source."
  {:failure-kinds ["budget-exceeded"]
   :annotations {"records-checked" ["checked" "rejected"]}})
```

`:failure-kinds` names the kinds `(fail (result/error :budget-exceeded ...))`
may print in a public error and in a trace's `run-stopped` event instead of
fingerprinting. `:annotations` maps an annotation type to the counter names
`workflow.event/annotate` may carry for it; such an annotation holds nothing
but those counters, each a non-negative integer no greater than 65535.

A counter name is declared in kebab-case like every other name here, but the
data map `workflow.event/annotate` receives crosses the same tool boundary as
every other call, where a hyphen in a map key is rewritten to an underscore.
Matching accounts for that rewrite, so a declared `already-seen` counter is
satisfied by an `already-seen` key in the call and recorded in the canonical
event as `already_seen`.

Both are declared here rather than in a manifest so the vocabulary sits beside
the code that emits it and is covered by the component source hash. Every name
is bounded lowercase kebab-case, at most 16 per list. Undeclared kinds keep
fingerprinting and undeclared annotation types stay rejected, so omitting both
changes nothing.

A declaration is **bundle-wide, not namespace-local**. The vocabulary is the
union across every namespace in the bundle, so a kind declared in one namespace
is named wherever in that bundle it is emitted, and any namespace may annotate
a type another declared. Declaring beside the emitting code is a convention
that keeps the two from drifting; it is not a scope boundary.

A declaration may not redefine a framework failure kind such as `turn-limit`,
nor the canonical `progress` and `agent-action` annotation types. Component
compilation checks only name shape, so such a bundle compiles and then fails
environment assembly with `:reserved_vocabulary_declaration`.

Naming a declared kind gives up no privacy the fingerprint provided: the
fingerprint is unsalted, so anyone holding the trace and the component can
precompute a closed declared set and match it. That reasoning holds only
because the set is closed and fixed at compile time.

Two namespaces in one bundle may declare the same annotation type only if they
agree on its counters — counter order does not matter. A conflict fails
environment assembly with `:conflicting_annotation_declaration` rather than
silently keeping one list and rejecting the other namespace's annotations.

## Declare runtime contracts

Public exports may declare contracts in their ordinary metadata map:

```clojure
(defn search
  "Search the configured document source."
  {:signature "(query :string, limit :int?) -> {items [:string]}"
   :effect :read}
  [query limit]
  ...)

(def default-limit
  "Default number of results."
  {:type ":int"}
  10)
```

The compiler parses the contract once, rejects malformed declarations,
duplicate parameter or normalized field names, signature/arity mismatches,
invalid effects, and constant values that do not match `:type`. At runtime a
signed function validates positional arguments before entering its body and
validates every successful result, including an export-local `(return ...)`.
An explicit `(fail ...)` is not a successful result and its payload is not
output-validated. Unsigned exports retain dynamic behavior.

Contract syntax is a string with its own small type grammar; Clojure reader
metadata such as `^{:signature ...}` is not supported. `:int?` accepts an
integer or `nil`; it does not make a positional argument omittable. In shaped
maps, an optional field may be omitted or `nil`. Function signatures currently
apply only to fixed-arity exports; the grammar has no rest-parameter contract.
See [Signature syntax](../signature-syntax.md) for the complete grammar and the
[PTC-Lisp specification](../ptc-lisp-specification.md#98-public-component-contracts).
[Manifests and capabilities](manifests-and-capabilities.md#test-a-signed-mission-function-without-a-model)
walks a credential-free run of a signature rejection and its model feedback.

## Tool authority is explicit

Every `tool/name` used by an export is recorded as `tool:name`, including calls
reached through private helpers or component dependencies. Environment assembly
rejects a bundle unless the destination environment grants every required tool.
Requirements validate authority; they never create it.

## Select a shipped prelude

Shipped libraries such as `runtime`, `cap`, `kernel`, `llm`, `fs`, `log.core`,
and the agent and result libraries are selected by ID rather than copied into
the project:

```json
"components": [
  {"id": "my.agent", "path": "agent.clj", "dependencies": ["agent.core"]},
  {"library": "agent.core"}
]
```

Their transitive dependencies are frozen into the same compiled bundle as local
components. Unknown IDs, repeated selections, and local/library ID collisions
are rejected. Workflow and mission bundles compile separately and attach to
structurally distinct environments.

Manifest library selections and `Library.resolve_components/1` expand shipped
dependencies automatically. `Library.component/1` intentionally returns only
the requested component; an embedder passing components directly to
`PtcRunner.Kernel.compile_bundle/1` must first assemble a closed dependency set.

Shipped components reuse lower-level components in the same way as application
components. The analysis stack is a concrete example:

| Component | Purpose |
| --- | --- |
| `cap` | Fail-safe capability-envelope handling and bounded cursor traversal |
| `log.core` | One-page canonical trace queries |
| `log.analysis` | Bounded whole-result trace traversal |
| `inspection.core` | One-page private inspection queries |
| `inspection.analysis` | Bounded whole-result private inspection traversal |

`log.core` and `inspection.core` depend on `cap`; each analysis layer depends
on its matching core component and on `cap`. This keeps each helper in one
place without granting new host capabilities. Adding an installed dependency
does widen the resolved bundle and its callable namespaces, so fixed profiles
pin the complete resolved component list and version user-visible surface
changes.

[Building agents](building-agents.md) covers the `agent.core` loop and the
`agent.prompt` policy seam these libraries provide.

## Boundaries

The manifest selects component sources and trusted provider names; executable
callbacks stay in the host-owned provider registry. The current manifest
supports built-in or embedder-registered capability builders, including the
host-installed MCP source described in the
[Kernel maintainer guide](kernel-maintainer.md). Future OpenAPI, database, or
command sources must resolve to the same immutable capability boundary without
granting manifests arbitrary endpoints, credentials, SQL, commands, or
callbacks.

Human inspection is a separate host-selected private artifact, described in
[Running and debugging](running-and-debugging.md). Writable prelude workspaces
remain deferred: a candidate component is compiled from trusted host input and
promoted into a new frozen revision for later environments, never mutated into
the active run bundle.

Hosts that compile bundles directly rather than through a manifest use the same
compiler; see [Embedding in Elixir](embedding-in-elixir.md).
