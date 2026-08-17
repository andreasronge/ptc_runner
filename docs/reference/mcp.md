# MCP reference

> **Audience:** operators and application authors who need the complete MCP
> installation, mapping, effect, authentication, and lifecycle contract.

MCP is the only way to add an external tool to a PtcRunner application. The
operator fixes the server, transport, credentials, public names, and read/write
effects in the host document. The application manifest may select and narrow
that installation but cannot invent or widen it.

Start with [Building agents](../guides/building-agents.md) if you have not yet run the
shipped agent loop. This guide adds one file-reading tool to that working path.

Two small servers are ready to copy:

- [`examples/mcp/filesystem`](https://github.com/andreasronge/ptc_runner/tree/main/examples/mcp/filesystem) is a
  paginated, read-only file grant with a committed JavaScript bundle.
- [`examples/mcp/writer`](https://github.com/andreasronge/ptc_runner/tree/main/examples/mcp/writer) is a confined
  report writer with an explicit write effect and retry guidance.

They are source examples, not release payloads. A separately cloned project
should vendor the chosen bundle or install an equivalent server at a stable
location; the PtcRunner release does not add Node.js or copy these examples.

## Protocol compatibility

PtcRunner implements the final MCP `2026-07-28` profile. Acquisition starts
with `server/discover`; it does not retry the legacy `initialize` handshake or
downgrade to an older protocol revision. A server must advertise `2026-07-28`
in `supportedVersions` and implement the tools surface from that profile.

An incompatible but responsive endpoint fails with
`provider_protocol_version_unsupported`. This diagnosis is intentionally
closed: it publishes the required PtcRunner-owned revision, but not the remote
error message, response data, endpoint, process stderr, or launch arguments.
Upgrade or replace the MCP server rather than adding a fallback handshake.

As of 2026-08-17, the official
`@modelcontextprotocol/server-filesystem@2026.7.10` package negotiates
`2025-11-25` through `initialize` and answers `server/discover` with JSON-RPC
`-32601 Method not found`. It is therefore not compatible with this PtcRunner
profile, despite starting and serving legacy clients normally. The checked-in
filesystem example listed above implements the required profile and is the
deterministic baseline for this reference.

A cold `npx` launch can spend more than the manifest's default one-second
evaluation budget before that protocol response arrives. To reproduce the
compatibility diagnosis, give both the application operation and the stdio
startup enough time:

```json
{"limits": {"evaluation_timeout_ms": 20000}}
```

In `ptc-host.json`, inside the stdio transport:

```json
{"start_timeout_ms": 15000}
```

The application limit is the outer budget. Raising only
`start_timeout_ms` cannot widen it; if the outer budget expires first, the
closed result is `provider_unavailable` because PtcRunner never received the
response needed to prove a protocol mismatch.

## Run the checked-in file agent

The tutorial server is a committed JavaScript bundle. It requires Node.js 22 or
newer but no npm install or build:

```console
ptc doctor examples/kernel-tutorial/03-file-agent.ptc-project.json
```

Passive doctor validates the application, resolves `node`, and checks the
selected installation without loading the model credential or starting the
server. After completing the [model-authored Quickstart](../guides/quickstart.md#run-a-model-authored-program),
run the agent:

```console
ptc run examples/kernel-tutorial/03-file-agent.ptc-project.json
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

The checked-in [writer sample](https://github.com/andreasronge/ptc_runner/tree/main/examples/mcp/writer) shows the
complete installation, mandatory `allow` list, basename confinement, and the
rule that the caller must reconcile an indeterminate result rather than repeat
the mutation blindly.

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

Relative entries in `args` are interpreted by the child under that resolved
`cwd`. If the host document lives outside this checkout, a path into
`examples/mcp/...` must therefore be copied into the project or expressed as a
deliberate cross-repository/absolute path.

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

The endpoint must be `https`, with one narrow exception for local development
described below. It is checked when the document loads, not when the server is
contacted, so a malformed endpoint fails as `installation_endpoint_invalid`.
The rejected plain-HTTP and loopback-allowance combinations use clause-specific
codes that state whether the allowance, a literal loopback address, removal of
the allowance, or HTTPS for configured credentials is required. Every form
names the installation before anything is dialled.

When direct endpoint acquisition does dial the server, `ptc run` and
`ptc doctor --connect` distinguish three closed connection failures:

- `provider_endpoint_connection_refused` means the endpoint rejected the TCP
  connection and is marked retryable;
- `provider_endpoint_name_unresolved` means the endpoint hostname did not
  resolve; and
- `provider_endpoint_tls_failed` means an admitted TLS configuration or
  protocol alert prevented the handshake.

These diagnostics name only the installed provider occurrence. They never
include the endpoint, DNS response, certificate, TLS alert text, Mint value, or
operating-system error. Other connection failures retain the generic
`provider_unavailable` code. OAuth discovery and token traffic retain their
existing closed authorization transport errors rather than exposing endpoint
causes through grant state.

Supported static schemes are `bearer`, `basic`, and header-named `api_key`.
Protocol headers such as `authorization`, `content-type`, `host`, and `mcp-*`
cannot be supplied as API-key headers. Upstream tool names are the server's own,
so they are held to the MCP protocol rule rather than PtcRunner's; only the
public `as` name must be lowercase-dotted. The generated host schema contains
the complete transport shape and bounds.

## Reach a local server over plain HTTP

TLS against a development server is usually more trouble than it is worth, so a
transport may opt out for loopback only:

```json
"transport": {
  "type": "streamable_http",
  "endpoint": "http://127.0.0.1:8055",
  "allow_insecure_loopback": true
}
```

The rule is deliberately narrow. Plain `http` is admitted only when

- `allow_insecure_loopback` is `true`,
- the host is the literal `127.0.0.1` or `[::1]` — `localhost` is a name that
  resolves wherever the resolver says, so it is not a loopback address here,
- the transport declares no `auth` entries, and
- the transport declares no `oauth` block.

The last two make the allowance credential-free: **no configured host credential
crosses a plaintext socket.** That is a guarantee about `auth` bindings and
OAuth tokens, and nothing more — tool arguments and results still travel over
that socket in the clear, so do not point this at data you would not want a
local process to read.

Setting the flag against an `https` endpoint is refused rather than ignored, so
moving a server to TLS without removing the allowance fails loudly.

### A complete local example

The repository ships a server to check this against, so remote MCP has a
baseline that runs before you debug one that does not. From a source checkout:

```console
go -C test/support/mcp_go_stateless build -o /tmp/ptc-mcp-http-server .
/tmp/ptc-mcp-http-server -host 127.0.0.1 -port 8055 &
```

It exposes one read tool, `cityTime`. Four files reach it, with no credential
anywhere. The host document installs it:

```json
{
  "install": {
    "workspace": {
      "source": "mcp",
      "installation_revision": "workspace-v1",
      "transport": {
        "type": "streamable_http",
        "endpoint": "http://127.0.0.1:8055",
        "allow_insecure_loopback": true
      },
      "tools": {
        "cityTime": {
          "as": "workspace.city_time",
          "effect": "read",
          "description": "Get the current time in nyc, sf, or boston."
        }
      }
    }
  }
}
```

`cityTime` is the server's own name and is written exactly as the server spells
it; only the public `as` name follows PtcRunner's lowercase-dotted rule.

The manifest selects the installation into a mission, because **MCP providers
are mission-only** — a workflow component that calls `tool/workspace.city_time`
directly fails with `capability_requirement_missing`:

```json
{
  "version": 1,
  "workflow": {
    "components": [
      {"id": "main", "path": "main.clj", "dependencies": ["kernel"]},
      {"library": "kernel"}
    ],
    "entry": "main/run"
  },
  "input": {"value": {"city": "nyc"}},
  "providers": {
    "mission": [{"name": "workspace", "config": {"allow": ["workspace.city_time"]}}]
  },
  "missions": {
    "default": {
      "components": [{"id": "clock", "path": "clock.clj"}],
      "providers": ["workspace"]
    }
  }
}
```

The mission component owns the tool call, and the workflow drives the mission
through `kernel/eval-source`, so this example needs no model:

```clojure
;; clock.clj — mission-only access to the installed server
(ns clock "Mission-only access to the installed MCP server." {:visibility :prompt})

(defn city-time
  "Return the current time in one named city."
  {:signature "(city :string) -> :any"}
  [city]
  (let [response (tool/workspace.city_time {"city" city})]
    (if (= :ok (get response :status))
      (get response :value)
      (fail response))))
```

```clojure
;; main.clj — workflow entry
(ns main "Workflow entry: drive the mission without a model." {:visibility :prompt})

(defn run
  "Ask the mission for one city's time."
  {:signature "(input :map) -> :any"}
  [input]
  (return (kernel/eval-source "default"
            (str "(clock/city-time \"" (get input "city") "\")"))))
```

`doctor --connect` proves the installation is reachable:

```console
$ ptc doctor ptc.json --host-config ptc-host.json --connect
{"checks":[…,{"code":"available","name":"provider/workspace/connectivity","status":"pass"}],
 "readiness":"ready"}
```

That check answers for the transport only. A configuration can pass it and
still fail at run time — a mission the manifest never grants the provider to,
for instance — so run the thing as well:

```console
$ ptc run ptc.json --host-config ptc-host.json
{"outcome":"continued","duration_ms":19,
 "value":{"text":["The current time in New York City is 2026-08-16T07:07:52-04:00"]}}
```

That is the baseline to diff a real host document against when a remote
installation will not connect.

## Authorize OAuth-protected HTTP explicitly

OAuth replaces static `auth` with host-owned policy that pins the resource,
issuer, client, scope ceiling, refresh policy, loopback authority, and permitted
network origins. The application and server cannot widen them.

This is a complete pre-registered installation. Replace the endpoint, issuer,
resource, client ID, scopes, and tool mapping with values issued for your
server:

```json
{
  "install": {
    "workspace": {
      "source": "mcp",
      "installation_revision": "workspace-oauth-v1",
      "transport": {
        "type": "streamable_http",
        "endpoint": "https://mcp.example.com/mcp",
        "oauth": {
          "installation_id": "workspace-oauth",
          "issuer": "https://auth.example.com",
          "resource": "https://mcp.example.com/mcp",
          "scope_ceiling": ["tools.read", "offline_access"],
          "default_scopes": ["tools.read"],
          "refresh_access": "when_supported",
          "network": {
            "additional_origins": [],
            "private_network_origins": []
          },
          "client": {
            "registration": "pre_registered",
            "client_id": "ptc-workspace",
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "loopback_redirect": {
              "host": "127.0.0.1",
              "path": "/callback"
            }
          }
        }
      },
      "ceilings": {"timeout_ms": 30000},
      "tools": {
        "cityTime": {"as": "workspace.city_time", "effect": "read"}
      }
    }
  }
}
```

OAuth MCP endpoints must use `https`. The plaintext-loopback allowance is
credential-free and cannot be combined with an `oauth` block. PtcRunner also
does not accept a custom CA path in the host document: use a certificate trusted
by the runtime's operating-system trust store. The repository E2E harness is a
test-only exception; it loads an ephemeral CA directly into the test VM before
exercising this exact host-document and command path.

Interactive authorization is currently available only from a source checkout:

```console
ptc run ptc.json --host-config ptc-host.json \
  --authorize-mcp workspace
```

The command prints a URL and waits on an operating-system-selected loopback
port. The shipped CLI store is process-local, so a later invocation must
authorize again; embedding hosts may provide a secure principal-scoped store.
The runtime-included `ptc` frontend does not currently initiate this flow.

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

- [Manifests and capabilities](application-manifest.md) covers mission
  selection, narrowing, and prompt-visible facades.
- [Host configuration](host-installation.md) covers credentials, provider
  aliases, data classes, and installed policy shared by every source type.
- [Building agents](../guides/building-agents.md)
  explains effect-aware correction and retry behavior.
