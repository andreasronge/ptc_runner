# Kernel component bundles

Kernel components are immutable PTC-Lisp modules compiled by
`PtcRunner.Kernel.compile_bundle/1`. A component declares one namespace and
may depend only on component IDs explicitly listed in its `dependencies` field.

```elixir
alias PtcRunner.Kernel
alias PtcRunner.Kernel.Component

{:ok, component} =
  Component.new(
    id: "math",
    source: """
    (ns math "Small arithmetic helpers." {:visibility :prompt})
    (defn double [x] (* x 2))
    """
  )

{:ok, bundle} = Kernel.compile_bundle([component])
```

Public `defn` and `def` forms become qualified exports. `defn-` remains
private to its namespace. Cross-component calls require both a declared
component dependency and a public export in the dependency.

Public exports may declare runtime contracts in their ordinary metadata map:

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
[PTC-Lisp specification](../ptc-lisp-specification.md#910-public-component-contracts).

Tool authority is explicit. Every `tool/name` used by an export is recorded
as `tool:name`, including calls reached through private helpers or component
dependencies. Environment assembly rejects a bundle unless the destination
environment grants every required tool. Requirements validate authority; they
never create it.

Use `PtcRunner.Kernel.Library.components/1` for the shipped libraries such as
`runtime`, `cap`, `kernel`, `llm`, `fs`, `log.core`, and the agent/result
libraries. Workflow and mission bundles are compiled separately and attached
to structurally distinct environments.

For deployable runs, prefer a versioned JSON manifest and `mix ptc.run`. The
manifest selects component sources and trusted provider names; executable
callbacks remain in the host-owned provider registry.

The current manifest supports built-in or embedder-registered capability
builders, including the host-installed MCP source described in the
[Kernel maintainer guide](kernel-maintainer.md). Future OpenAPI, database, or
command sources must resolve to the same immutable capability boundary without
granting manifests arbitrary endpoints, credentials, SQL, commands, or
callbacks.

Human inspection is implemented as a separate host-selected private artifact,
also documented in the maintainer guide. Writable prelude workspaces remain
deferred: any future candidate must be a versioned host resource compiled and
promoted into a new frozen revision for later environments, never a mutation
of the active run bundle.
