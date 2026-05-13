# PtcRunner MCP Aggregator Mode

Reference for operating PtcRunner's MCP server as a programmatic
tool-calling aggregator over configured upstream MCP servers.

Spec: [`Plans/ptc-runner-mcp-aggregator.md`](../Plans/ptc-runner-mcp-aggregator.md).

## Overview

Aggregator mode does not advertise upstream tools individually. It
adds `(tool/mcp-call ...)` to the PTC-Lisp sandbox — a programmatic
primitive that calls configured upstream MCP servers and composes their
results deterministically inside the sandbox. In an aggregator-only
configuration, the MCP server advertises `ptc_lisp_execute`; optional
features such as sessions, diagnostics, or agentic tools may add their
own top-level tools. One LLM-authored, sandboxed PTC-Lisp program
replaces N round-trip `tools/call` invocations against the calling
client.

Best fit:

- Ad-hoc cross-server joins (search server A, filter on facts from
  server B).
- Filtering / aggregating large upstream tool outputs before they
  reach the calling LLM.
- Reducing context pressure: only the program's final value
  crosses back to the client.
- Deterministic transforms over upstream results.

Poor fit:

- Workflows requiring model judgment between tool calls (use
  multi-turn `ptc_lisp_execute` instead, or hand-written
  application code).
- Mature repeated workflows that should be hand-written
  application code.
- Setups needing broad MCP gateway features from day one — the
  aggregator is a primitive, not a gateway. See §15 Positioning.

The aggregator is **not** an agent framework. It is one
deterministic step.

## Configuration

Aggregator mode is opt-in. The MCP server resolves the upstreams
config from the first match in:

1. `--upstreams-config <path>` flag.
2. `PTC_RUNNER_MCP_UPSTREAMS` env var.
3. `~/.config/ptc_runner_mcp/upstreams.json` (XDG default).

If none is found, the server runs in MCP v1 (`:mcp_no_tools`)
mode and `(tool/mcp-call ...)` is unavailable.

### Format — stdio upstream

```json
{
  "upstreams": {
    "fs": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp/sandbox"]
    },
    "github": {
      "command": "github-mcp",
      "args": [],
      "env": {
        "GITHUB_TOKEN": "${GITHUB_TOKEN}"
      }
    }
  }
}
```

`${VAR}` placeholders inside stdio `env` values are resolved
from the parent-process environment at startup. Unset
variables abort startup with a clear error. **Note**: the
`${VAR}` resolver is narrowed to stdio `env` only — credentials,
HTTP `url`, `static_headers`, `proxy`, and other fields are
parsed literally (see `Plans/http-transport-credentials.md` §5.2).

### Format — HTTP upstream + credentials

`Plans/http-transport-credentials.md` adds Streamable HTTP
transport (MCP rev 2025-06-18) and a credentials registry:

```json
{
  "credentials": {
    "github-pat": {
      "source": "env",
      "var": "GITHUB_PAT"
    }
  },
  "upstreams": {
    "github": {
      "transport": "http",
      "url": "https://api.githubcopilot.com/mcp/",
      "auth": [
        { "scheme": "bearer", "binding": "github-pat" }
      ],
      "static_headers": {
        "X-MCP-Readonly": "true"
      }
    },
    "fs": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp/sandbox"]
    }
  }
}
```

Mixed transports are fully supported. From the program's
perspective, an HTTP upstream and a stdio upstream are
indistinguishable.

**Credentials.** Top-level `credentials:` block holds named
bindings. Three sources are supported in v1: `env` (read from
process env at request time, never cached), `file` (read +
trim trailing whitespace at request time), and `literal`
(value embedded in config — emits a `Logger.warning` outside
`MIX_ENV: :test`). The reserved source `exec` is deferred to
v1.1.

**Auth emitters.** Each HTTP upstream's `auth:` is an ordered
list. Three schemes:

- `bearer` → `Authorization: Bearer <value>`
- `basic` → `Authorization: Basic base64(user:pass)`. The
  binding's `value` may be either `user:pass` or a JSON
  `{"user":"…","pass":"…"}` shape.
- `custom_header` → `<header>: <value>`. The header name MUST
  match RFC 7230 token grammar and MUST NOT be `Authorization`
  (use `bearer`/`basic`) or any of the impl-controlled
  protocol headers (`MCP-Protocol-Version`, `Mcp-Session-Id`,
  `User-Agent`).

**Static headers.** `static_headers:` sets literal non-secret
headers (e.g., `X-MCP-Readonly`, `X-Tenant`). The `${VAR}`
resolver does NOT touch these — they are parsed verbatim.
Sensitive header names are rejected at config-load:
`Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie`,
`X-Api-Key`, plus the protocol-controlled triple. Use `auth:`
emitters for any secret-bearing header.

**HTTPS by default.** Plain `http://` URLs are rejected unless
`allow_insecure_http: true` is set. Sending `auth:` over plain
HTTP additionally requires `allow_insecure_auth: true` — two
explicit opt-ins.

**Optional `:req` dep.** HTTP transport requires the `:req`
package. It's an optional Mix dep — stdio-only operators don't
need it. If a `transport: "http"` entry is configured but
`:req` is unloaded, boot fails loudly with a clear message.

**Resolution semantics.**

- Resolved auth bytes are NEVER stored in upstream config maps,
  Connection state, trace JSONL, `upstream_calls` envelopes, or
  Logger output. Structural isolation per
  `Plans/http-transport-credentials.md` §4.2 is the primary
  guarantee.
- The redactor (substring-replaces registered plaintext with
  `[REDACTED]` in any formatted string the logger / trace /
  upstream_calls writers emit) is defense in depth.
- env / file bindings are re-resolved on every request — no
  in-process value cache. Rotating an env var or replacing a
  file is picked up on the next request without restart.

### Operational notes

- Self-as-upstream is rejected at startup (a configured
  `command` whose resolved path equals the running PtcRunner
  release). The check applies to stdio entries; an HTTP URL
  pointing at this PtcRunner's loopback is technically possible
  and unsafeguarded — programs that loop will eventually hit
  `max_upstream_calls_per_program`.
- `fake` fields are NOT honored from the JSON config — fakes
  exist only for tests and require the `Upstream.Registry`
  test API.
- Boot-time HTTP failures (handshake 503, binding resolution
  failure) are non-fatal — the upstream renders as
  "(unavailable at startup)" in the catalog and arms backoff
  for the next call. The aggregator does not refuse to boot
  because a remote MCP is down.

## Writing PTC-Lisp programs against `tool/mcp-call`

### Call shape

```clojure
(tool/mcp-call {:server "<configured-name>"
                :tool   "<upstream-tool>"
                :args   {<args map>}})
```

`:server`, `:tool`, and `:args` are required keys. `:args` may
be omitted when the upstream tool takes no arguments — the safer
default is `{}`.

`tool/mcp-call` is **not** a first-class function value.
Higher-order use **MUST** wrap it in a closure:

```clojure
;; OK
(pmap #(tool/mcp-call {:server "github"
                       :tool "get_pr"
                       :args {:number %}})
      pr-numbers)

;; OK
(map (fn [n] (tool/mcp-call {:server "fs"
                             :tool "read"
                             :args {:path n}}))
     paths)
```

### Return-value handling

A successful call returns the upstream's JSON payload converted
to PTC-Lisp data (string, number, boolean, list, map). The
program treats it as an ordinary value:

```clojure
(def repos
  (tool/mcp-call {:server "github"
                  :tool "search_repos"
                  :args {:query "infra" :limit 50}}))

(count repos)              ;; just a number
(map :name repos)          ;; pluck a field per repo
```

### JSON helpers (`json/*`, `mcp/*`)

Many MCP upstreams wrap their payload in the standard envelope
`%{"content" => [%{"type" => "text", "text" => "..."}]}`, sometimes
with the typed JSON also placed in `"structuredContent"`. PTC-Lisp
provides four helpers so programs don't hand-roll `get-in` chains
or parse JSON-as-text by hand:

| Helper | Returns |
|---|---|
| `(json/parse-string s)` | parsed JSON value, or `nil` on failure (string keys; never raises) |
| `(json/generate-string v)` | JSON-encoded string, or `nil` on non-encodable input (atoms outside `true/false/nil`, atom-keyed maps, tuples, PIDs) |
| `(mcp/text r)` | `r["content"][0]["text"]`, or `nil` for any non-conforming shape |
| `(mcp/json r)` | `r["structuredContent"]` if the key is present (preserving `:json-null` / `false` / `0` / `""` / `[]` verbatim), else `(json/parse-string (mcp/text r))` |

The aggregator also auto-promotes `content[0].text` into
`structuredContent` when the upstream declares
`mimeType: "application/json"` or any `+json` suffix
(RFC 6839). The promotion is additive — `content[]` is preserved —
so reading via either channel works. Programs that hit the
auto-decode path can simply destructure:

```clojure
;; Upstream emits content[0]={text:"{\"items\":[...]}", mimeType:"application/json"}.
;; Aggregator auto-decodes; structuredContent appears for free.
(def result (tool/mcp-call {:server "issues" :tool "list" :args {}}))
(get-in result ["structuredContent" "items"])

;; Or use mcp/json — works whether structuredContent came from
;; auto-decode, native upstream support, or text-parse fallback.
(get (mcp/json result) "items")
```

The previous regex-split workaround for upstreams returning
JSON-as-text is obsolete. See `Plans/json-support.md` §5–§6 for
the full semantics.

### `:json-null` semantics

`nil` and `:json-null` are distinct:

| Value | Meaning |
|---|---|
| `nil` | The call **did not succeed**. World-fault failure. Recorded in `upstream_calls` with a reason. |
| `:json-null` | The call **succeeded** and returned JSON `null` as its top-level payload. Recorded as `status: ok`. |

This invariant matters because an upstream that legitimately
returns JSON `null` would otherwise be indistinguishable from a
failed call. The `:json-null` rewrite is **top-level only** —
nested `null` inside maps and arrays remains `nil`.

Programs that don't care about the distinction can treat
`:json-null` as truthy and continue:

```clojure
(when result
  (process result))           ;; runs for both real values and :json-null
```

Programs that care can compare explicitly:

```clojure
(if (= result :json-null)
  "got null"
  (process result))
```

### World-fault vs programmer-fault

| Class | Behavior | When |
|---|---|---|
| **World-fault** | `(tool/mcp-call ...)` returns `nil`; entry recorded in `upstream_calls`; program continues | Upstream couldn't be started, returned a JSON-RPC error, timed out, oversized response, per-program cap exhausted |
| **Programmer-fault** | Raises a runtime error; program terminates | Unknown server, unknown tool on a healthy upstream, malformed args |

World-faults are **expected runtime conditions** — write
defensive code: `(when result ...)`, `(remove nil? results)`,
`(filter some? batch)`.

Programmer-faults are **defects in the program** — the message
identifies the bad call site so the LLM can fix the program and
retry on the next turn.

## Catalog

In aggregator mode the `ptc_lisp_execute` tool description ends
with an inline catalog block — one entry per configured
upstream's tools, in the shape:

```
fs:
  read_text_file(path: string) - Read the contents of a UTF-8 text file
  list_directory(path: string) - List the entries in a directory

github:
  search_repos(query: string, limit: integer?) - Search repositories
  get_pr(owner: string, repo: string, number: integer) - Get a pull request
```

### Reading the catalog

- **Args**: `name: type` for required, `name: type?` for
  optional. The optional `?` mirrors Python type-hint
  conventions and is the LLM's signal to omit the arg or pass
  `nil`.
- **Argument order**: required args first in the JSON Schema's
  `required`-array order; optional args alphabetical. This is a
  rendering-side determinism rule; the upstream itself accepts
  any order.
- **Types**: `string`, `integer`, `number`, `boolean`, `object`,
  `array`, `null`. Complex types (`object`, `array`) are rendered
  as the bare type name — the LLM does not see the full nested
  schema.
- **Constraints (priority over `type`)**:
  - `enum` constraints render as `enum<type>` when every listed
    value shares one primitive type (e.g. `enum<string>`,
    `enum<integer>`), or bare `enum` for heterogeneous values.
    The subscript form is the dominant real-world shape — most
    enums are uniformly-typed string sets.
  - `const` renders as `const<json-encoded-value>` so the LLM
    sees both "this argument is a fixed literal" and what the
    literal is. Strings carry their JSON quotes (`const<"fixed">`),
    numbers and booleans render bare (`const<42>`, `const<true>`).
    Falsy consts are detected by key-presence rather than
    truthiness, so `{"const": false}` / `{"const": null}` /
    `{"const": 0}` / `{"const": ""}` all render `const<…>` and do
    not collapse to the primitive type label.
  - Both override the primitive `type` label: a schema like
    `{"type": "string", "enum": ["open","closed"]}` renders as
    `enum<string>`, NOT `string`. Constrained args are exactly
    where the LLM most needs the constraint hint.
- **Description**: hard-truncated at 80 characters with an
  ellipsis suffix. Multi-line upstream descriptions collapse to
  a single line.

### When the catalog is populated

The catalog is built once at MCP-server startup:

1. The supervisor eagerly calls `ensure_started/1` against every
   configured upstream so each Connection's `tools/list` response
   is cached.
2. The catalog string is rendered from those caches.
3. The string is **frozen** into `:persistent_term` and read from
   there on every subsequent `tools/list` request.

The frozen string is **stable for the lifetime of the MCP-server
process**. Post-boot upstream crashes, recoveries, and config
changes do **not** alter what the calling LLM sees — schema
changes require a PtcRunner restart. This matches §12.5's
"rebuilt only on PtcRunner restart" contract; without the freeze,
a crashed upstream would retroactively flip to
`(unavailable at startup)` mid-session and confuse programs that
were authored against the original catalog.

An upstream that fails the boot-time `ensure_started/1` renders
as:

```
upstream-name:
  (unavailable at startup)
```

The Connection is still re-attempted on the first
`(tool/mcp-call ...)` invocation that targets it (per §4.3
backoff) — only the catalog text is frozen, not the runtime
upstream state.

### Catalog discovery from PTC-Lisp — `catalog/` builtins

The inline catalog above is a static, truncated snapshot baked
into the tool description. For programs that need to *inspect*
the configured upstreams at runtime — enumerate servers, page
through a server's tools, search across catalogs, or read a tool's
full input schema — aggregator mode also exposes a `catalog/`
namespace with five builtins. (Outside aggregator mode these forms
do not exist.)

| Form | Signature | Returns |
|------|-----------|---------|
| `catalog/summary` | `(catalog/summary)` | A map `{"mode" <catalog-mode-string> "servers" [...] "catalogs_loaded" <bool>}`. Each server entry has `"name"`, `"description"`, `"tool_count"` (`nil` if its `tools/list` isn't cached yet) and, when present, `"capabilities"`. `"catalogs_loaded"` is `true` only when every configured upstream's tool list is cached. |
| `catalog/list-servers` | `(catalog/list-servers)` | A list of `{"name" "description" "tool_count" "catalog_loaded"}` maps, sorted by name. |
| `catalog/list-tools` | `(catalog/list-tools server)`<br>`(catalog/list-tools server opts)` | A list of compact tool maps — `{"server" "tool" "summary" "arg_keys" "read_only"}` — for `server`, sorted by tool name. `opts` is a map: `:limit` (integer `1..200`, default `50`) and `:offset` (integer `≥ 0`, default `0`) for pagination. |
| `catalog/describe-tool` | `(catalog/describe-tool server tool)` | A detailed map for one tool: `"server"`, `"tool"`, `"summary"`, `"description"` (untruncated), `"input_schema"` (the upstream's JSON Schema), `"arg_keys"`, `"annotations"`, `"call_example"` (a ready-to-edit `(tool/mcp-call …)` snippet) and `"response_notes"`. |
| `catalog/search-tools` | `(catalog/search-tools query)`<br>`(catalog/search-tools query opts)` | A list of compact tool maps — `{"server" "tool" "summary" "arg_keys" "read_only" "catalog_loaded"}` — ranked by lexical relevance to `query` (scoring described below). `opts` is a map: `:limit` (integer `1..50`, default `8`) and `:load` (boolean, default `false`). With `:load false` a server whose catalog isn't cached contributes a single server-level placeholder — `{"server" <name> "tool" nil "summary" "<desc>. Catalog not loaded." "catalog_loaded" false "next" "(catalog/list-tools \"<name>\" {:limit 20})"}` — instead of triggering a load; with `:load true` every configured upstream is `ensure_started`ed first and only tool-level matches are returned. |

`catalog/search-tools` ranks each candidate with a deterministic
lexical score: `query` tokens are matched against the tokenized
server/tool names (boosted) and the tokenized
descriptions/arg-keys/annotations (unboosted), scoring `10` for an
exact token match, `5` for a prefix match, `2` for a substring
match, plus a `+2` boost on the name fields. Tokenization splits
camelCase, snake_case, and kebab-case. Only positive-scoring
entries are returned; ties break on `{server, tool}` so ordering
is stable across runs.

`catalog/list-tools` and `catalog/describe-tool` (and
`catalog/search-tools` when called with `:load true`) trigger a
lazy `ensure_started/1` for the target upstream if its tools
aren't cached yet — using the same per-program failure cache and
ensure locks as `(tool/mcp-call ...)`, so concurrent `pmap`
children cooperate instead of stampeding. Result lists are
size-capped at `--max-catalog-result-bytes` (default 256 KiB) of
JSON: an over-cap `list-tools` / `search-tools` list is truncated
entry-by-entry, an over-cap `describe-tool` result becomes a world
fault.

**Error model** — identical split to `(tool/mcp-call ...)`:

- **World fault → `nil`**: upstream can't be started, the result
  is too large to cap, or the per-program catalog op budget is
  exhausted. The program keeps running.
- **Programmer fault → program raises**: `server` not configured,
  `tool` not found on that server, or a bad argument (e.g.
  `:limit` out of range, `:load` not a boolean, an empty `query`,
  `server`/`tool` not a non-empty string).

The catalog op budget is a **separate** atomics counter from the
`(tool/mcp-call ...)` budget — discovery calls never eat into a
program's upstream-call quota.

```clojure
;; List the read-only tools the "github" upstream exposes
(->> (catalog/list-tools "github" {:limit 100})
     (filter :read_only)
     (map :tool))

;; Only describe a tool if its server is actually configured
(when (some (where :name "fs") (catalog/list-servers))
  (catalog/describe-tool "fs" "read_text_file"))

;; Search every configured upstream for "read"-related tools,
;; loading any cold catalogs so only tool-level matches come back
(map (juxt :server :tool)
     (catalog/search-tools "read" {:limit 20 :load true}))
```

## Three example programs

### Example 1 — Simple read

Read a single text file via the filesystem MCP and return its
contents:

```clojure
(tool/mcp-call {:server "fs"
                :tool   "read_text_file"
                :args   {:path "/tmp/sandbox/notes.md"}})
```

The program is one expression; its value is the response.

### Example 2 — Cross-server filter

List GitHub PRs and filter to those mentioning a particular
file path discovered from the filesystem upstream:

```clojure
(def open-prs
  (tool/mcp-call {:server "github"
                  :tool   "list_prs"
                  :args   {:state "open" :limit 50}}))

(def watched-paths
  (tool/mcp-call {:server "fs"
                  :tool   "read_text_file"
                  :args   {:path "/etc/watched-paths.txt"}}))

(def watch-set
  (set (clojure.string/split-lines watched-paths)))

(def hits
  (filter (fn [pr]
            (some watch-set (:files pr)))
          open-prs))

(map :number hits)
```

Only the final list of PR numbers — perhaps a handful of
integers — crosses back to the calling client. The intermediate
50 PRs and the watched-paths file body never leave the sandbox.

### Example 3 — Parallel batch with `pmap`

Fetch ten upstream items in parallel:

```clojure
(def ids [101 102 103 104 105 106 107 108 109 110])

(def items
  (pmap (fn [id]
          (tool/mcp-call {:server "store"
                          :tool   "get"
                          :args   {:id id}}))
        ids))

;; Drop world-fault failures (e.g. one ID was unknown):
(def good (remove nil? items))

(map :name good)
```

`pmap` parallelism is bounded by the per-program upstream-call
cap (see Limits in §9 of the spec). The `(remove nil? ...)`
idiom is the canonical way to handle partial failure.

## Error reference

### Programmer-fault (program raises, terminates)

| Error message | Cause |
|---|---|
| `tool/mcp-call requires :server (string), got <value>` | `:server` key missing or not a non-empty string |
| `tool/mcp-call on upstream '<server>' requires :tool (string), got <value>` | `:tool` key missing or not a non-empty string |
| `tool '<server>.<tool>' rejected args: :args must be a map, got <value>` | `:args` not a map |
| `tool '<server>.<tool>' rejected args: not JSON-encodable (<reason>)` | `:args` map contains a value Jason can't encode (e.g. a closure) |
| `no upstream '<name>' configured` | `:server` value is not in the configured upstreams |
| `no tool '<tool>' in upstream '<server>'` | `:tool` value is not in the upstream's `tools/list` (only raised when the upstream is healthy and the cache can prove absence) |

### World-fault (returns `nil`, recorded in `upstream_calls`)

| `reason` | Cause |
|---|---|
| `upstream_unavailable` | The upstream couldn't be started, its `initialize` handshake failed, or it's in its post-crash recovery window |
| `upstream_error` | The upstream returned a JSON-RPC error to a `tools/call` |
| `timeout` | The upstream call exceeded `upstream_call_timeout_ms` |
| `response_too_large` | The upstream's response exceeded `max_upstream_response_bytes` before decode |
| `cap_exhausted` | The program made more than `max_upstream_calls_per_program` calls |

Each entry in `upstream_calls` carries `server`, `tool`,
`status`, `duration_ms`, and on error `reason` and `error` (the
detail string). See spec §8.5 for the full envelope shape.
