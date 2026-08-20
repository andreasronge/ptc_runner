# MCP reference

> **Audience:** operators and application authors who need the complete MCP
> installation, mapping, effect, authentication, and lifecycle contract.

MCP is the only way to add an external tool to a PtcRunner application. The
operator fixes the server, transport, credentials, public names, and read/write
effects in the host document. The application manifest may select and narrow
that installation but cannot invent or widen it.

Start with [Building agents](../guides/building-agents.md) if you have not yet run the
shipped agent loop. This guide adds one file-reading tool to that working path.

The published [`ptc-fs-mcp@0.1.0`](https://www.npmjs.com/package/ptc-fs-mcp)
package (MIT, [source](https://github.com/andreasronge/ptc-fs-mcp)) is a
confined read/write filesystem server over live bytes. Pin it from a host
document with `npx`; a hermetic spawn that does not inherit `PATH` must run
absolute `node` against the installed `dist/cli.js`.

It is a demo server, not a release payload. A separately cloned project should
install that package at a pinned version; the PtcRunner release does not add
Node.js.

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
profile, despite starting and serving legacy clients normally.
[`ptc-fs-mcp@0.1.0`](https://www.npmjs.com/package/ptc-fs-mcp) implements the
required profile and is the deterministic baseline for this reference.

A cold `npx` launch can spend more than the default budget before that protocol
response arrives. Acquisition derives one per-operation budget and then applies
it to each step separately: once to starting the transport, which for stdio
covers launcher staging and the child spawn, and again to each discovery request,
beginning with `server/discover`. It is not a single budget for the whole
sequence, so a slow start and a slow answer can add up past any one of them.

That per-operation value is the lowest of:

- the installation's `ceilings.timeout_ms` in `ptc-host.json`, default `5000`;
- for a mission provider, the manifest's `limits.evaluation_timeout_ms`,
  default `1000`; and
- the provider entry's own `config.timeout_ms` under the manifest's `providers`,
  when it sets one. It may only narrow the two above, never widen them — a
  larger value is refused as an invalid selection.

Every one of them must be wide enough, because the lowest wins. Raising one
while another stays at its default changes nothing. In `ptc.json`:

```json
{"limits": {"evaluation_timeout_ms": 20000}}
```

and in `ptc-host.json`, beside the installation's `transport`:

```json
{"ceilings": {"timeout_ms": 20000}}
```

`start_timeout_ms` inside the stdio transport bounds one step: the launcher
handshake that spawns the child. The runtime applies it as
`min(start_timeout_ms, remaining transport-start budget)`, so it can only narrow,
never widen, the values above — but once those are raised past its `5000`
default, that default becomes the narrower cap on the handshake. Raise it too if
the step that expires is the spawn rather than the answer:

```json
{"start_timeout_ms": 15000}
```

When a budget expires, the closed result is `provider_acquisition_timeout`,
which is retryable and distinct from `provider_unavailable`. It reports only
that the clock ran out: the step that expired may have been the spawn or the
discovery answer, so PtcRunner cannot say the server was reached, only that it
never received the response needed to prove a protocol mismatch. Raise the
budgets and run it again. A first launch on a cold npm cache, or any launch on a
loaded machine, is the usual cause.

## Run the checked-in file agent

The tutorial launches [`ptc-fs-mcp@0.1.0`](https://www.npmjs.com/package/ptc-fs-mcp)
through `npx`. It requires Node.js 22 or newer; the first run may download that
package.

```console
ptc init kernel-tutorial --example kernel-tutorial
ptc doctor kernel-tutorial/03-file-agent.ptc-project.json
```

Passive doctor validates the application, resolves `node`, and checks the
selected installation without loading the model credential or starting the
server. After completing the [model-authored Quickstart](../guides/quickstart.md#run-a-model-authored-program),
run the agent:

```console
ptc run kernel-tutorial/03-file-agent.ptc-project.json
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
non-empty `allow` list, even when it selects only reads. A timed-out or
transport-failed write is never retried automatically and may report
`mutation_state: "indeterminate"`; the external mutation may already have
happened. A complete decoded refusal (`isError: true`) or JSON-RPC error is
not indeterminate: the server answered, so the caller can treat that outcome
as known.

The
[`named-mission-reader-writer`](https://github.com/andreasronge/ptc_runner/tree/main/examples/named-mission-reader-writer)
example shows the complete installation: two occurrences of `ptc-fs-mcp@0.1.0`
with different roots, a mandatory `allow` list on the write mapping, basename
confinement, and the rule that the caller must reconcile an indeterminate
result rather than repeat the mutation blindly.

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
`cwd`. Pin a published package with `npx` when the host document lives outside
this checkout; a relative path into another repository is a deliberate
cross-tree choice, not a default.

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
claim. Install the field when the server actually publishes a whole-corpus
digest; [`ptc-fs-mcp`](https://www.npmjs.com/package/ptc-fs-mcp) does not,
because it serves live bytes and reports a per-call `content_hash` instead.

## Next steps

- [Manifests and capabilities](application-manifest.md) covers mission
  selection, narrowing, and prompt-visible facades.
- [Host configuration](host-installation.md) covers credentials, provider
  aliases, data classes, and installed policy shared by every source type.
- [Building agents](../guides/building-agents.md)
  explains effect-aware correction and retry behavior.
