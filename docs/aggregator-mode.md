# PtcRunner MCP Aggregator Mode

Reference for operating PtcRunner's MCP server as a programmatic
tool-calling aggregator over configured upstream MCP servers.

## Overview

Aggregator mode does not advertise upstream tools individually. It
adds `(tool/mcp-call ...)` to the PTC-Lisp sandbox — a programmatic
primitive that calls configured upstream MCP servers and composes their
results deterministically inside the sandbox. In an aggregator-only
configuration, the MCP server advertises `lisp_eval`; optional
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
  multi-turn `lisp_eval` instead, or hand-written
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
parsed literally.

### Format — HTTP upstream + credentials

Aggregator mode also supports Streamable HTTP upstreams (MCP rev
2025-06-18) alongside stdio, with a credentials registry:

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
  Logger output. Structural isolation is the primary guarantee.
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

`:server` and `:tool` are required keys. `:args` is optional and
defaults to `{}` when omitted; include it whenever the upstream tool
takes arguments.

`tool/mcp-call` is a runtime callable in value position, so direct
higher-order use is valid:

```clojure
;; OK
(map tool/mcp-call
     [{:server "github" :tool "get_pr" :args {:number 101}}
      {:server "github" :tool "get_pr" :args {:number 102}}])

;; OK
(pmap tool/mcp-call
      [{:server "fs" :tool "read" :args {:path "a.txt"}}
       {:server "fs" :tool "read" :args {:path "b.txt"}}])

;; Also OK when argument construction is needed
(map (fn [n]
       (tool/mcp-call {:server "github"
                       :tool "get_pr"
                       :args {:number n}}))
     pr-numbers)
```

### Return-value handling

A successful call returns tagged PTC-Lisp data. The program checks `:ok`
and then treats `:value` as an ordinary value:

```clojure
(def repos
  (let [r (tool/mcp-call {:server "github"
                          :tool "search_repos"
                          :args {:query "infra" :limit 50}})]
    (if (:ok r)
      (:value r)
      (fail (:message r)))))

(count repos)              ;; just a number
(map :name repos)          ;; pluck a field per repo
```

### JSON helpers (`json/*`)

`tool/mcp-call` returns tagged data. Always inspect `:ok` before using
`:value`.

| Shape | Meaning |
|---|---|
| `{:ok true :value payload :value_kind :json}` | `payload` came from `structuredContent` or parsed JSON text. |
| `{:ok true :value text :value_kind :text}` | First MCP text content was not JSON. |
| `{:ok true :value nil :value_kind :none}` | The call succeeded, but no default payload was selected. |
| `{:ok false :reason kw :message text}` | Recoverable upstream/tool failure. |

Many MCP upstreams wrap their payload in the standard envelope
`%{"content" => [%{"type" => "text", "text" => "..."}]}`, sometimes
with typed JSON in `"structuredContent"`. The aggregator unwraps the
common domain payload for you:

```clojure
(let [r (tool/mcp-call {:server "issues" :tool "list" :args {}})]
  (if (:ok r)
    (get (:value r) "items")
    (fail (:message r))))
```

### World-fault vs programmer-fault

| Class | Behavior | When |
|---|---|---|
| **World-fault** | `(tool/mcp-call ...)` returns `{:ok false :reason kw :message text}`; entry recorded in `upstream_calls`; program continues | Upstream couldn't be started, returned a JSON-RPC error, timed out, oversized response, per-program cap exhausted, or returned an MCP `isError` envelope |
| **Programmer-fault** | Raises a runtime error; program terminates | Unknown server, unknown tool on a healthy upstream, malformed args |

World-faults are **expected runtime conditions** — write
defensive code: inspect `:ok` before using `:value`, keep successful
results with `(filter :ok batch)`, and inspect `:reason` / `:message`
when a call fails.

Programmer-faults are **defects in the program** — the message
identifies the bad call site so the LLM can fix the program and
retry on the next turn.

## Catalog

In aggregator mode, upstream-capable `lisp_eval` and
`lisp_session_eval` descriptions start with a short discovery hint:
use `(apropos ...)`, `(dir ...)`, and `(doc ...)`, then call the
selected upstream with `tool/mcp-call`. In inline catalog mode the
dynamic tail also includes a synthetic discovery snapshot:

```
Configured upstream MCP servers:
- fs: Filesystem MCP server. 2 tools. files.
  Tools:
  - read_text_file - Read the contents of a UTF-8 text file
  - list_directory - List the entries in a directory
- github: GitHub MCP server. 2 tools. issues, pull requests.
  Tools:
  - search_repos - Search repositories
  - get_pr - Get a pull request
```

### Reading the catalog

- **`dir` / `apropos`**: list tool names and short descriptions only.
  Use them to choose a tool, not to infer schemas.
- **`doc`**: shows args, required args, the call form, and the
  Clojure-ish `Result<...>` payload shape.
- **Args in `doc`**: `:name type` for required, `:name type?` for
  optional. The optional `?` is the LLM's signal to omit the arg or pass
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
- **Description**: optional prose is normalized to one line and capped.
  Auto mode drops descriptions before the renderer falls back to lazy
  mode.

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

### REPL discovery from PTC-Lisp

The inline catalog above is a static snapshot baked into the tool
description. Lazy mode shows configured server names plus discovery
guidance instead of individual tools. PTC-Lisp also has local discovery
for executable PTC/Clojure builtins and curated Java interop. Aggregator
mode extends the same REPL-style forms so programs can inspect configured
upstreams at runtime — enumerate servers, page through a server's tools,
search across catalogs, or read a tool's full input schema.

| Form | Signature | Returns |
|------|-----------|---------|
| `mcp/servers` | `(mcp/servers)` | A list of `{"name" "description" "tool_count" "catalog_loaded"}` maps, sorted by name. |
| `apropos` | `(apropos query)`<br>`(apropos query opts)` | A list of compact discovery strings ranked by lexical relevance to `query`. Loaded MCP tool matches rank before unloaded MCP server hints, and both rank before local PTC/Clojure/Java matches. `opts`: `:limit` (integer `1..50`, default `8`) and `:load` (boolean, default `false`). With `:load false` an unloaded server contributes a server-level placeholder string with a `dir` next-step hint instead of triggering a load; with `:load true` every configured upstream is `ensure_started`ed first and only tool-level matches are returned. |
| `dir` | `(dir ref)`<br>`(dir ref opts)` | For known local namespaces/classes, lists executable local members. Otherwise, lists `tool - description` strings for one MCP server, sorted by tool name. `opts`: `:limit` (integer `1..200`, default `50`) and `:offset` (integer `≥ 0`, default `0`) for pagination. |
| `doc` | `(doc ref)` | One detailed local or MCP description string. Known local refs win; unknown refs fall through to MCP tool refs shaped as `server/tool`. MCP docs include args, required args, a ready-to-edit `(tool/mcp-call …)` example, and the `Result<...>` payload shape. |
| `meta` | `(meta ref)` | Structured local or MCP metadata. Known local refs win; unknown refs fall through to MCP tool refs. |
| `ns-publics` | `(ns-publics ns)` | Local-only map of public names to compact metadata for PTC/Clojure namespaces. Java classes and MCP servers are not supported. |

`apropos` ranks each candidate with a deterministic
lexical score: `query` tokens are matched against the tokenized
server/tool names (boosted) and the tokenized
descriptions/arg-keys/annotations (unboosted), scoring `10` for an
exact token match, `5` for a prefix match, `2` for a substring
match, plus a `+2` boost on the name fields. Tokenization splits
camelCase, snake_case, and kebab-case. Only positive-scoring
entries are returned; ties break on `{server, tool}` so ordering
is stable across runs.

`dir`, `doc`, and `meta` (and `apropos` when called with `:load true`)
trigger a lazy `ensure_started/1` for the target upstream if its tools
aren't cached yet — using the same per-program failure cache and ensure
locks as `(tool/mcp-call ...)`, so concurrent `pmap` children cooperate
instead of stampeding. Result lists are size-capped at
`--max-catalog-result-bytes` (default 256 KiB) of JSON: an over-cap
`dir` / `apropos` list is truncated entry-by-entry, an over-cap `doc`
or `meta` result becomes a world fault.

**Error model** — identical split to `(tool/mcp-call ...)`:

- **World fault → `nil`**: upstream can't be started, the result
  is too large to cap, or the per-program discovery op budget is
  exhausted. The program keeps running.
- **Programmer fault → program raises**: `server` not configured,
  `tool` not found on that server, or a bad argument (e.g.
  `:limit` out of range, `:load` not a boolean, an empty `query`,
  `server`/`tool` not a non-empty string).

The discovery op budget is a **separate** atomics counter from the
`(tool/mcp-call ...)` budget — discovery calls never eat into a
program's upstream-call quota.

```clojure
;; List the tools the "github" upstream exposes
(dir 'github {:limit 100})

;; Only describe a tool if its server is actually configured
(when (some (fn [s] (= (:name s) "fs")) (mcp/servers))
  (doc 'fs/read_text_file))

;; Search every configured upstream for "read"-related tools,
;; loading any cold catalogs so only tool-level matches come back
(apropos "read" {:limit 20 :load true})
```

## Three example programs

### Example 1 — Simple read

Read a single text file via the filesystem MCP and return its
contents:

```clojure
(let [r (tool/mcp-call {:server "fs"
                        :tool   "read_text_file"
                        :args   {:path "/tmp/sandbox/notes.md"}})]
  (if (:ok r)
    (:value r)
    (fail (:message r))))
```

The program is one expression; its value is the unwrapped file body.

### Example 2 — Cross-server filter

List GitHub PRs and filter to those mentioning a particular
file path discovered from the filesystem upstream:

```clojure
(def unwrap
  (fn [r]
    (if (:ok r)
      (:value r)
      (fail (:message r)))))

(def open-prs
  (unwrap (tool/mcp-call {:server "github"
                          :tool   "list_prs"
                          :args   {:state "open" :limit 50}})))

(def watched-paths
  (unwrap (tool/mcp-call {:server "fs"
                          :tool   "read_text_file"
                          :args   {:path "/etc/watched-paths.txt"}})))

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
(def good (map :value (filter :ok items)))

(map :name good)
```

`pmap` parallelism is bounded by the per-program upstream-call
cap (see Limits in §9 of the spec). Filter on `:ok` before taking
`:value` to handle partial failure.

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

### World-fault (returns tagged error, recorded in `upstream_calls`)

| `reason` | Cause |
|---|---|
| `upstream_unavailable` | The upstream couldn't be started, its `initialize` handshake failed, or it's in its post-crash recovery window |
| `upstream_error` | The upstream returned a JSON-RPC error to a `tools/call` |
| `tool_error` | The upstream returned a successful MCP envelope with `"isError": true` |
| `timeout` | The upstream call exceeded `upstream_call_timeout_ms` |
| `response_too_large` | The upstream's response exceeded `max_upstream_response_bytes` before decode |
| `cap_exhausted` | The program made more than `max_upstream_calls_per_program` calls |

Each entry in `upstream_calls` carries `server`, `tool`,
`status`, `duration_ms`, and on error `reason` and `error` (the
detail string).

## Payload reduction

The whole point of programmatic tool calling is that the program
fetches from upstream MCP tools and **collapses** the results down to
a small answer before handing it back. Aggregator-mode responses
can carry deterministic accounting for that work: a `ptc_metrics`
block plus `result_bytes` / `oversize` on each `upstream_calls[]`
entry. Where those fields appear depends on the response profile:
`debug` exposes them inline, while slim/structured model-facing
responses omit them and keep the details for `lisp_debug recent` /
`get` / `stats`. For sessions, metrics are **per eval** — they account
for the calls drained in that turn, not the session's cumulative
`upstream_calls` history:

```jsonc
// structuredContent (abridged) — lisp_eval, aggregator mode
{
  "result": "…the program's answer (812 bytes)…",
  "upstream_calls": [ { "server": "github", "tool": "search_issues",
                        "status": "ok", "duration_ms": 142,
                        "result_bytes": 48122, "oversize": false } ],
  "ptc_metrics": {
    "schema_version": 1,
    "final_result_bytes": 812,           // byte size of the `result` field (the answer; not prints/feedback)
    "prints_bytes": 0,
    "upstream_call_count": 3, "upstream_ok_count": 3,
    "upstream_error_count": 0, "upstream_oversize_count": 0,
    "upstream_result_bytes": 48122,      // Σ result_bytes over status==ok, non-oversize calls — the denominator
    "upstream_error_bytes": 0, "upstream_oversize_bytes": 0,
    "payload_reduction_ratio": 59.26,    // round(upstream_result_bytes / max(final_result_bytes, 1), 2); null when either side is 0
    "estimated_final_result_tokens": 203, "estimated_upstream_result_tokens": 12031,
    "token_estimate_method": "utf8_bytes_div_4",
    "baseline": {
      "conservative": { "name": "successful_upstream_results_only", "bytes": 48122, "ratio": 59.26, "note": "…" },
      "optimistic":   { "name": "no_ptc_direct_llm_workflow", "available": false, "note": "…" }
    }
  }
}
```

**Honest framing.** `payload_reduction_ratio` is "how much upstream
tool-result payload the program collapsed into its answer" — a real
number the server can measure. It is **not** "tokens saved by PTC"
(that needs the no-PTC counterfactual and the server-side LLM usage,
neither of which the server can know), and it is **not** the literal
reduction in the MCP response the client receives. In `debug`, the
envelope mirrors the full structured payload (`ptc_metrics`,
`upstream_calls`, `prints`, `feedback`) into `content[0].text`, so the
actual response is larger than `final_result_bytes`; in slim/structured
profiles, those observability fields are omitted from normal eval
responses. Bytes are primary and exact; token figures are explicitly
estimates (`utf8_bytes_div_4`) — clients that care tokenize
themselves. Only `status: "ok"`, non-`oversize`
upstream calls count toward `upstream_result_bytes`; failed-call and
oversize bytes are reported separately and never inflate the ratio.
On an error envelope, `final_result_bytes` is `0` and the ratio is
`null` (the bytes fetched before the failure are still reported). The
optimistic baseline is always `{ "available": false }` — the server
never invents it.

**`lisp_task` planner cost.** A `lisp_task` response's `ptc_metrics`
also carries a `server_side_llm` line item — the planner LLM's
prompt/completion byte sizes (always available) and provider token
counts (`provider_reported: true` with real numbers when the LLM
adapter surfaces `usage`, else `null` + byte estimates). The
`payload_reduction_ratio` for `lisp_task` is answer/result-payload
reduction *only*; an `efficiency_note` states verbatim that it
excludes the planner cost. See [Agentic Mode](agentic-mode.md) for
the planner contract.

When `--debug-tool` is enabled, `lisp_debug op=stats` rolls these
per-call blocks up into a `payload_reduction` aggregate — totals,
p50/p95/max/weighted ratio (skipping `null`s), the top-N reducers,
and (for windows containing `lisp_task` calls) an `agentic_planner`
sub-block with the summed planner tokens/bytes. `lisp_debug recent` /
`get` records carry the per-call `ptc_metrics`. See
[Diagnostics: lisp_debug](mcp-debug.md).
