# Components-and-preludes reference

This is the complete component, dependency, visibility, and shipped-library
contract.

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
[PTC-Lisp specification](../ptc-lisp-specification.md#9-8-public-component-contracts)
for normative behavior. The
[manifest guide](application-manifest.md#compose-components-and-libraries)
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

Manifests expand shipped dependencies into a closed component graph. Hosts
that assemble bundles through another supported interface have the same
responsibility.

Shipped components use the same dependency rules. For example:

| Component | Purpose |
| --- | --- |
| `cap` | Fail-safe capability-envelope handling and bounded cursor traversal |
| `analysis` | Three bounded public/private run-evidence navigation operations |

The generated [shipped prelude reference](../prelude-reference.md) groups every
installed component by purpose and lists its visibility, direct and transitive
dependencies, reverse dependents, public functions, contracts, effects, and
backing capability requirements.

`analysis` depends on `cap`. Adding an installed dependency widens the callable
surface, so fixed profiles pin the complete resolved component list and must
version public surface changes.

`cap/fold-pages` is the single shipped traversal helper. It reduces page items
into caller-owned bounded state, stops at `max_pages`, and returns the opaque
`next_cursor` plus `snapshot_hash` needed to resume in another evaluation.
Callers must keep the reducer state bounded; collecting every item merely moves
the source-size heap problem into the accumulator. Cursor-cycle detection covers
each bounded invocation; the helper deliberately does not retain an unbounded
history across resumptions.

[Building agents](../guides/building-agents.md) covers the `agent.core` loop and the
`agent.prompt` policy seam these libraries provide.

Local components use new IDs; they cannot shadow a selected shipped library
ID. A hash-checked
[component override](../guides/evaluating-with-replay.md#evaluate-the-candidate-without-installing-it)
can evaluate replacement source for one selected component on a run, but it is
an invocation option rather than a permanent manifest library installation.

## Evaluate one replacement component

`--component-override-descriptor` replaces one component already selected by
the manifest. A transitively selected component is also eligible. The
descriptor contains the replacement instruction, not the source itself:

```json
{
  "target": {"environment": "workflow"},
  "component_id": "my.agent",
  "base_source_hash": "sha256:<64 lowercase hex>",
  "source_hash": "sha256:<64 lowercase hex>",
  "path": "candidate.clj"
}
```

| Field | Meaning |
| --- | --- |
| `target` | The workflow bundle, or one exact mission bundle |
| `component_id` | An already-selected component whose source will be replaced |
| `base_source_hash` | Hash of the installed source the candidate was derived from |
| `source_hash` | Hash of the candidate source bytes |
| `path` | Candidate source path relative to the descriptor directory |
| `provenance` | Optional claims about how the candidate was authored |

For a mission component, use
`{"environment": "mission", "mission": "reader"}` as the target. The
candidate path is confined to the descriptor directory. PtcRunner verifies
both hashes before compiling: `source_hash` prevents substituted candidate
bytes, while `base_source_hash` rejects a candidate built for a component that
has since changed. The source is read once, and those verified bytes are the
bytes compiled.

A refused descriptor keeps the `override_invalid` code and the logical source
`component-override.json`. The message names the field and the rule — stale
`base_source_hash`, mismatched `source_hash`, an unknown `component_id`, or a
`path` that is not a usable candidate — and `path` points at that field.
The descriptor's filesystem path and the rejected hash values stay out of the
envelope.

An override preserves the selected component's ID and declared dependencies.
It cannot add a component or change the graph. The replacement still passes
the normal dependency, signature, export, capability-requirement, and bundle
checks. The descriptor contains no source, credentials, provider grants, or
installation instruction.

The optional closed `provenance` object may contain `run_id`, `prompt_hash`,
`authored_at`, and `accept_widened_effect`. These are supplied claims rather
than proof of origin.

## Boundaries

The manifest selects component sources and trusted provider aliases;
executable callbacks stay in the host-owned provider registry. New provider
types must preserve this boundary: manifests must not introduce endpoints,
credentials, SQL, commands, or callbacks.

Private inspection is a separate host-selected artifact, described in
[Running and debugging](cli.md). An active bundle is
immutable; any changed component must be compiled into a new bundle.

Hosts that compile bundles directly rather than through a manifest use the same
compiler and dependency rules.
