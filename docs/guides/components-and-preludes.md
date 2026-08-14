# Components and preludes

A component is one immutable PTC-Lisp module with one namespace. Its declared
component dependencies define the only namespaces it may call while compiling.
Components compile into a frozen bundle; shipped components are selected as
libraries instead of copied into an application.

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

Public `defn` and `def` forms become qualified exports. `defn-` remains private
to its namespace. A cross-component call needs both a declared dependency and
a public export in that dependency.

Dependencies are composition boundaries, not authority grants. Once a bundle
is installed, evaluated PTC-Lisp can call every public export in it.
`:visibility :discoverable` removes an export from prompt inventory, not from
the callable surface. Code can find it with `dir` or `apropos` and inspect it
with `doc` or `export-meta`. Use this visibility for support APIs that remain
available without consuming prompt space.

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

The compiler parses contracts and rejects malformed declarations,
signature/arity mismatches, invalid effects, and incompatible constants. A
signed function validates arguments before its body and validates every
successful result, including an export-local `return`. `fail` is not a
successful result, so its payload is not output-validated. Unsigned exports
remain dynamic.

The contract is a string in its own type grammar, not Clojure reader metadata.
Signatures cover fixed arity only. A nullable type such as `:int?` accepts
`nil`; it does not make a positional argument optional.

See [Signature syntax](../signature-syntax.md) for the complete grammar and the
[PTC-Lisp specification](../ptc-lisp-specification.md#98-public-component-contracts)
for normative behavior. The
[manifest guide](manifests-and-capabilities.md#compose-components-and-libraries)
links to a credential-free rejection and correction example.

## Tool authority is explicit

Every `tool/name` used by an export is recorded as `tool:name`, including calls
through private helpers and dependencies. Environment assembly rejects a bundle
unless the destination environment grants every requirement. Requirements
validate authority; they never create it.

## Select a shipped prelude

Shipped libraries such as `runtime`, `cap`, `kernel`, `llm`, `analysis`, and
the agent and result libraries are selected by ID:

```json
"components": [
  {"id": "my.agent", "path": "agent.clj", "dependencies": ["agent.core"]},
  {"library": "agent.core"}
]
```

Transitive library dependencies join local components in the same frozen
bundle. Unknown IDs, repeated selections, and local/library ID collisions are
rejected. Workflow and mission bundles remain separate.

Manifests and `PtcRunner.Kernel.Library.resolve_components/1` expand shipped
dependencies. `Library.component/1` intentionally returns only one component;
direct `PtcRunner.Kernel.compile_bundle/1` callers must supply a closed graph.

Shipped components use the same dependency rules. For example:

| Component | Purpose |
| --- | --- |
| `cap` | Fail-safe capability-envelope handling and bounded cursor traversal |
| `analysis` | Three bounded public/private run-evidence navigation operations |

`analysis` depends on `cap`. Adding an installed dependency widens the callable
surface, so fixed profiles pin the complete resolved component list and must
version public surface changes.

[Building agents](building-agents.md) covers the `agent.core` loop and the
`agent.prompt` policy seam these libraries provide.

## Boundaries

The manifest selects component sources and trusted provider aliases;
executable callbacks stay in the host-owned provider registry. New provider
types must preserve this boundary: manifests must not introduce endpoints,
credentials, SQL, commands, or callbacks.

Private inspection is a separate host-selected artifact, described in
[Running and debugging](running-and-debugging.md). An active bundle is
immutable; any changed component must be compiled into a new bundle.

Hosts that compile bundles directly rather than through a manifest use the same
compiler; see [Embedding in Elixir](embedding-in-elixir.md).
