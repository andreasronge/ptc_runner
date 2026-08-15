# Connecting tools with MCP

MCP is the only way to add an external tool to a PtcRunner application. The
operator fixes the server, transport, credentials, public names, and read/write
effects in the host document. The application manifest may select and narrow
that installation but cannot invent or widen it.

Start with [Building agents](building-agents.md) if you have not yet run the
shipped agent loop. This guide adds one file-reading tool to that working path.

## Run the checked-in file agent

The tutorial server is a committed JavaScript bundle. It requires Node.js 22 or
newer but no npm install or build:

```console
mix ptc doctor examples/kernel-tutorial/03-file-agent.ptc-project.json
```

Passive doctor validates the application, resolves `node`, and checks the
selected installation without loading the model credential or starting the
server. After completing the [Quickstart credential step](quickstart.md#2-supply-a-model-credential),
run the agent:

```console
mix ptc run examples/kernel-tutorial/03-file-agent.ptc-project.json
```

The model sees one prompt-visible `tutorial.files/read-page` function. It does
not see an unrestricted filesystem or the server command.

## Install and rename a server tool

An MCP installation belongs in `ptc-host.json`:

```json
"workspace": {
  "source": "mcp",
  "installation_revision": "workspace-v1",
  "transport": {
    "type": "stdio",
    "command": "node",
    "args": ["server.js"]
  },
  "tools": {
    "read_text_file": {
      "as": "workspace.read",
      "effect": "read",
      "description": "Read one UTF-8 file beneath the granted root.",
      "model_visible": true,
      "error_feedback": "closed"
    }
  }
}
```

`read_text_file` is the upstream name. `workspace.read` is the stable public
capability name exposed by PtcRunner. Change `installation_revision` whenever
the transport, mapping, effect, snapshot policy, or server behavior changes.

The operator's required `effect` declaration is authoritative; server
annotations cannot change it. `model_visible` controls prompt discovery, not
call authority. `error_feedback: "bounded"` may expose up to 1,024 bytes of
validated server error text as untrusted model feedback, so enable it only when
the server cannot return secrets, paths, or stack traces.

## Select less authority in the manifest

The application selects the installed alias in its mission provider list:

```json
"providers": {
  "mission": [
    {"name": "workspace", "config": {"allow": ["workspace.read"]}}
  ]
}
```

If an installation maps any write tool, every selecting manifest must provide a
non-empty `allow` list, even when it selects only reads. A failed or timed-out
write is never retried automatically and may report
`mutation_state: "indeterminate"`; the external mutation may already have
happened.

A prompt-visible PTC-Lisp wrapper can present a smaller domain API than the raw
tool:

```clojure
(ns my.files "Mission access to the granted file root." {:visibility :prompt})

(defn read-page
  "Read one bounded UTF-8 page. Pass nil first, then next_cursor."
  {:signature "(path :string, cursor :string?) -> :any"}
  [path cursor]
  (let [args (if cursor {"path" path "cursor" cursor} {"path" path})
        response (tool/workspace.read args)]
    (if (= :ok (get response :status))
      (get response :value)
      (fail response))))
```

When prompt-visible wrappers exist, the model sees them instead of the raw
`tool/...` entries. The underlying capability still enforces its schema, byte
ceiling, timeout, quota, and manifest grant.

## Choose a transport

Stdio launches one local process. Relative working directories resolve against
the host document, and credentials enter through named bindings rather than
literal environment values:

```json
"transport": {
  "type": "stdio",
  "command": "node",
  "cwd": ".",
  "args": ["server.js"],
  "inherit_environment": true,
  "env": {"VENDOR_TOKEN": {"binding": "vendor_token"}}
}
```

Plain doctor resolves the executable without launching it. Missing commands
fail their local provider check as `command_not_found`. The optional
[launcher companion](https://github.com/andreasronge/ptc_runner/tree/main/ptc_runner_launcher)
adds executable identity and stronger stdio containment.

Streamable HTTP names a remote endpoint and optional static authentication:

```json
"transport": {
  "type": "streamable_http",
  "endpoint": "https://mcp.example.com/v1",
  "auth": [{"scheme": "bearer", "binding": "vendor_token"}]
}
```

The endpoint must be `https`. A host document cannot name a plain-`http`
endpoint, including on loopback, so a local server reached this way needs TLS;
the in-process Elixir API has a separate loopback allowance that host documents
deliberately do not expose. A rejected endpoint fails the installation's
connectivity check, which `mix ptc doctor --connect` reports as
`provider_unavailable`.

Supported static schemes are `bearer`, `basic`, and header-named `api_key`.
Protocol headers such as `authorization`, `content-type`, `host`, and `mcp-*`
cannot be supplied as API-key headers. The generated host schema contains the
complete transport shape and bounds.

## Authorize OAuth-protected HTTP explicitly

OAuth replaces static `auth` with host-owned policy that pins the resource,
issuer, client, scope ceiling, refresh policy, loopback authority, and permitted
network origins. The application and server cannot widen them.

Interactive authorization is currently available only from a source checkout:

```console
mix ptc run ptc.json --host-config ptc-host.json \
  --authorize-mcp workspace
```

The command prints a URL and waits on an operating-system-selected loopback
port. The shipped CLI store is process-local, so a later invocation must
authorize again; embedding hosts may provide a secure principal-scoped store.
The runtime-included `bin/ptc` frontend does not currently initiate this flow.

Normal execution never starts authorization. Missing authority fails closed,
and PtcRunner never retries the original call after `401` or `403` because the
request may have performed a write. Dynamic Client Registration, DPoP, and
signed authorization metadata are unsupported.

## Publish immutable content identity

For immutable content, `snapshot_identity` may name an installed read tool and
a result field containing a lowercase `sha256:` digest:

```json
"snapshot_identity": {"tool": "snapshot_info", "field": "snapshot_hash"}
```

PtcRunner calls that tool once during assembly and publishes the digest as
`content_snapshot_hash`. It validates the shape, not the server's immutability
claim. The
[filesystem sample](https://github.com/andreasronge/ptc_runner/tree/main/examples/mcp/filesystem#publishing-the-content-identity)
shows the complete contract.

## Next steps

- [Manifests and capabilities](manifests-and-capabilities.md) covers mission
  selection, narrowing, and prompt-visible facades.
- [Host configuration](host-configuration.md) covers credentials, provider
  aliases, data classes, and installed policy shared by every source type.
- [Building agents](building-agents.md#handle-failures-without-repeating-effects)
  explains effect-aware correction and retry behavior.
