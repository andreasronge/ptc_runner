# Kernel component bundles

Kernel components are immutable PTC-Lisp modules compiled by
`PtcRunner.Kernel.compile_bundle/1`. A component declares one namespace and
may depend only on component IDs explicitly listed in its `requires` field.

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
