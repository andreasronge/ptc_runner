# PtcRunner Capability & Integration Platform — Direction

> **Status:** direction / discussion material. This is a north star for many
> future PRs, not a single implementation plan. It describes the *shape* we
> want the integration surface to converge on. Individual PRs should each be a
> faithful instance of the grammar below; if a PR needs to break the grammar,
> that is a signal to revisit this document, not to special-case the code.

## 0. What this document is

**Scope.** How PtcRunner connects to the outside world and how you configure
and extend it: **capabilities, providers/sources, host config, credentials,
preludes, and schema/validation**. Upstream integration (MCP, HTTP, OpenAPI) is
the driving use case, but the goal is the *whole* extension surface.

**Out of scope** (except where they touch this surface): the PTC-Lisp language
spec, Kernel internals, and agent-behavior libraries (planning, retries,
memory).

**The single test every proposal must pass:**

> *If you have learned how one provider, one config block, or one prelude
> works, you can guess how the next one works without reading new docs.*

Consistency is the feature. A smaller surface that is perfectly predictable
beats a larger one that is individually clever. When two designs are equally
good locally, choose the one that matches an existing pattern.

---

## Part I — Design principles

These are the "learn once" facts. Every feature in Parts II–V is an application
of one of them.

### P1. The authority ladder

Four roles, always in the same order, each strictly weaker than the one above:

| Rung | Who | Verb | May declare | May **not** |
|------|-----|------|-------------|-------------|
| **Host** | Elixir builder or host-owned JSON | *freezes* | endpoints, commands, credentials, installed ceilings | — |
| **Manifest** | model-authorable | *selects & narrows* | which installed names to expose, hide some, lower ceilings | add endpoints, credentials, tools, or raise a ceiling |
| **Prelude** | frozen Lisp shipped by the host | *composes* | named wrappers over primitives, docs, `:visibility` | reach anything not already installed |
| **Program** | generated Lisp | *executes* | calls what it was given | everything else |

Every configuration question is answered by naming the rung. "Where does the
API key go?" → Host. "Can the model pick which tools are visible?" → Manifest
(narrow only). "Where does pagination live?" → Prelude. This ladder never
changes shape between providers, so once you know it you can place any new
concern.

### P2. Capabilities are primitives; behavior is Lisp

The runtime ships **small, bounded, effectful primitives** — an LLM call, a
file read, an HTTP GET, one upstream tool. Everything above that — retries,
planning, pagination, response shaping, multi-call workflows, domain wrappers —
is a **PTC-Lisp library**. Before adding a runtime feature, ask: *is this a
prelude pattern?* Usually it is. The runtime stays a thin, auditable set of
primitives; richness lives in replaceable Lisp.

### P3. Present at authoring time; validate best-effort at runtime

A full schema is reference material for whoever **writes the wrapper** (a human,
or a generator). The runtime never needs to hand a full schema to the model to
make a call succeed. **Validation is fast feedback, never a gate on existence.**
A tool whose schema is too rich to compile safely is still exposed — we simply
skip local validation and let the upstream reject a bad call.

### P4. One capability contract, regardless of source

`llm`, `file-read`, `http/get`, an MCP tool, an OpenAPI operation — all surface
as the **same `Capability`**: a name, an `effect`, input/output schemas,
`model_visible`, and a deterministic secret-free snapshot. Learn the capability
contract once and every provider, present or future, produces it. Nothing
downstream (the Kernel, the trace, the Viewer) needs to know where a capability
came from.

### P5. One config grammar; source is a field

Every external connection is declared with the **same** `{credentials,
install}` shape. The only thing that differs between `mcp_http`, `mcp_stdio`,
`http_get`, and `openapi` is a `source` value and its typed fields. Adding a
source kind is choosing a new value, **not** inventing a new shape. (See the
Rosetta table in Part II — it is the clearest expression of this whole
document.)

The field is named `source`, not `transport`, because a source is either
*reached* (the connector family: `mcp_*`, `http_get`, `openapi`) or *captured*
(the local snapshot family in the manifest-authored-applications direction) —
snapshot providers transport nothing. `Transport` survives only as the name of
the internal connector seam (III.1).

### P6. BEAM-native safety: a bad call kills a process, not the node

The threat model is explicit and narrow. Process crashes and deadline-kills are
**normal and cheap** — the Kernel already runs every call in a bounded owner
process. We do **not** restrict schema vocabulary, response size, or call depth
"to be safe"; those failures just kill a process. The only hard guards are the
three **node-level** invariants in Part IV (regex/`:re`, unbounded memory,
egress). Features uphold those three and otherwise stay permissive.

### P7. Determinism and redaction are invariants, not features

Every capability yields a **deterministic, secret-free snapshot** (content
addressed by hash). Secrets flow **only** through a per-request callback and
never enter capabilities, snapshots, errors, logs, telemetry, traces, or crash
dumps. New features inherit this; they never re-decide it.

### P8. Naming is a contract

Namespaces and suffixes are predictable, so if you can name a thing you can
guess where it lives:

- **Pure helpers** live in a topic namespace: `json/`, `str/`, `regex/`,
  `schema/`, `mcp/` (unwrap helpers). No effects, no host wiring, available to
  every program.
- **Effectful host capabilities** are `tool/<public-name>` (installed
  providers) or a reserved effect namespace (`llm/`, `http/`, `file/`).
- **Public capability names are dotted lowercase** (`workspace.search`,
  `fs.read`). The existing hyphenated built-ins (`fs-read`, `cap-list`,
  `cap-describe`) are renamed to dotted form before new providers multiply
  names.
- **Read vs write** is declared by `effect: :read | :write`, never inferred
  from a remote hint.

---

## Part II — The unified model (the grammar you learn once)

### II.1 The four layers, end to end

One journey, all four rungs, using a weather HTTP API as the running example.
Every provider type follows this exact path.

**1. Host freezes a provider** (Elixir builder, or the JSON equivalent in II.3):

```elixir
Upstream.Source.builder(
  source: :http_get,
  base_url: "https://api.weather.example",
  auth: [%{scheme: :bearer, binding: "weather_key"}],
  ceilings: %{timeout_ms: 5_000, max_result_bytes: 200_000}
)
```

**2. Manifest selects & narrows** (model-authorable; never carries the URL or
key):

```json
"providers": {
  "mission": [
    { "name": "weather", "config": { "allow": ["http.get"], "timeout_ms": 3000 } }
  ]
}
```

**3. Prelude composes** — turns the primitive into a named, documented,
model-visible function. The full API schema is consulted *here*, by the author,
not at runtime:

```clojure
(ns weather "Weather lookups." {:visibility :prompt})

(defn forecast [city]
  (http/get "weather" {:path "/v1/forecast" :query {:q city :days 3}}))
```

**4. Program executes** — the model calls the prelude wrapper it can see:

```clojure
(weather/forecast "Gothenburg")
```

The same four steps describe an MCP server, an OpenAPI spec, or the built-in
`llm` provider. Only step 1's fields change.

### II.2 The capability contract (P4)

Every provider emits `{capabilities, snapshot, close}` where each capability is:

| Field | Meaning |
|-------|---------|
| `name` | public, lowercase, dotted identifier — what the program calls |
| `effect` | `:read` or `:write`, host-declared |
| `input_schema` / `output_schema` | bounded JSON Schema; used for best-effort validation (P3) |
| `model_visible` | whether it appears in the model's catalog |
| `callback` | the bounded, deadline-scoped invocation |
| snapshot entry | `{name, effect, input_schema_hash, output_schema_hash}` — secret-free, deterministic (P7) |

### II.3 The provider/source grammar (P5)

The host-owned JSON config — the operator-supplied channel that replaces any
special CLI flag:

```json
{
  "credentials": {
    "weather_key": { "env": "WEATHER_API_KEY" }
  },
  "install": {
    "<provider-name>": {
      "source": "mcp_http | mcp_stdio | http_get | openapi",
      "auth":     [ { "scheme": "bearer | basic | api_key", "binding": "<name>", "header": "<only for api_key>" } ],
      "tools":    { "<upstream>": { "as": "<public>", "effect": "read" } },
      "ceilings": { "timeout_ms": 5000, "max_result_bytes": 200000 }
    }
  }
}
```

`auth`, `tools`/mapping, and `ceilings` are **identical** across every
source. Only the "how to reach it / how to discover it" fields differ — and
they occupy the same conceptual slot. This is the Rosetta table:

| Concern | `mcp_http` | `mcp_stdio` | `http_get` | `openapi` |
|--------|-----------|------------|-----------|----------|
| **reach** | `endpoint` | `command`, `args`, `env` | `base_url` | `base_url` |
| **discover** | `initialize`+`tools/list` (auto) | `initialize`+`tools/list` (auto) | none — prelude declares | compile `schema` (file/inline/url) |
| **expose** | `tools` map | `tools` map | `allow_query` / `allow_headers` | `include` operationIds |
| **auth** | `auth` binding | `env` binding | `auth` binding | `auth` binding |
| **ceilings** | `ceilings` | `ceilings` | `ceilings` | `ceilings` |
| **effect** | `:read` (v1) | `:read` (v1) | `:read` | `:read` (GET, v1) |

Learn one column; you can fill in the next.

Two decided conventions keep this document and the manifest readable side by
side:

- **The top-level key is `install`, not `providers`.** The manifest's
  `providers` section holds per-destination *selection* lists; the host
  document holds a name → *installation* map. Using the same word for two
  shapes was the most confusing thing in early tutorial drafts, so the host
  side owns the distinct verb: the host *installs*, the manifest *selects*.
- **`tools` is optional for fixed-shape sources.** A source whose
  operations are closed and known at compile time (e.g. the local snapshot
  providers in the manifest-authored-applications direction) surfaces them
  under default dotted names — `<provider>.<operation>`, as in
  `workspace.search` — with host-declared effects. An explicit `tools` map
  remains available for renames, and remains **mandatory** for
  discovery-based sources (`mcp_http`, `mcp_stdio`, `openapi`), where the
  map is the security allowlist.

### II.4 The manifest selection grammar

Narrowing keys are the **same for every provider**, and every one can only
tighten:

| Key | Effect |
|-----|--------|
| `allow` | optional subset of installed public names to expose (default = every installed name) |
| `model_visible` | subset of `allow` the model sees in its catalog (default = `allow`) |
| `timeout_ms` | may only *lower* the installed ceiling |
| `max_result_bytes` | may only *lower* the installed ceiling |

Because selection can only narrow, omitting `allow` is never an escalation —
the host already froze the outer bound. Write `allow` only to expose less;
the common manifest entry is just `{"name": "workspace"}`.

There is never a per-source selection dialect. If you can narrow an MCP
provider you can narrow an OpenAPI provider identically.

### II.5 The prelude grammar

A prelude wraps **any** capability the same way, and advertises its call shape
so the model calls it correctly (this is also how we retire the "bare
capabilities carry no invocation syntax" wart):

```clojure
(ns <name> "<one-line doc>" {:visibility :prompt})   ; :prompt | :internal

(defn <fn> [args...]
  (tool/<public-name> { ... })      ; or (http/get ...), (llm/complete ...)
  )
```

Conventions that make preludes guessable:

- `:visibility :prompt` → the function appears in the model's catalog with its
  signature and docstring. `:internal` → callable by other prelude code only.
- Wrappers are where **pagination, retries, and response shaping** live (P2):
  a cursor loop over `http/get`, not a runtime feature.
- A generator (Track E) can *emit* a prelude from an OpenAPI spec — the output
  is an ordinary prelude, indistinguishable from a hand-written one.

### II.6 The builtin namespaces

| Namespace | Kind | Examples |
|-----------|------|----------|
| `json/` | pure | `parse-string`, `generate-string`, **`validate`** (new) |
| `schema/` | pure | `compile` → handle, `valid?` (new; JSV-backed) |
| `str/`, `regex/`, `set/`, `walk/`, `math/` | pure | existing |
| `mcp/` | pure | `text`, `json` result-unwrap helpers |
| `cap/` | pure | `list`, `describe` (existing); **`unwrap!`**, **`paginate`** (new; blessed result/paging helpers) |
| `http/` | effectful capability | `get` (new; host-installed, bounded) |
| `llm/`, `file/` | effectful capability | existing built-in providers |

---

## Part III — The surfaces in depth

### III.1 Providers & sources

The `Transport` behaviour is the implementation seam for **connector**
sources (`mcp_*`, `http_get`, `openapi`); snapshot sources capture at build
and implement the same Capability contract directly, without a remote-shaped
exchange. For connectors, a single generic **`Transport` seam** sits at the
*exchange* layer (one bounded request), not the old `list_tools/call` layer.
Above the seam, one shared
`Upstream.Source` owns all transport-agnostic work — normalization, schema
compilation, Capability assembly, the deterministic snapshot, owner lifecycle,
and kill-requests-before-close ordering. Below the seam, each connector
implements the same tiny contract:

```
open(frozen_config, owner)          -> {:ok, conn} | {:error, reason}
discover(conn, deadline)            -> {:ok, [raw_tool_schema]} | {:error, reason}   # openapi: from spec; http_get: none
exchange(conn, req, payload, max, deadline) -> {:ok, raw_envelope} | {:error, closed_reason}
close(conn)                         -> :ok    # idempotent
```

**Adding a connector source is a closed recipe** (Appendix A): implement those
four, add a `source` value + typed fields to the grammar, and you inherit
Capability emission, narrowing, snapshotting, and redaction for free.

Much of this is **portable from the pre-rewrite `lib/ptc_runner/upstream/`
subsystem** (removed in `ec5806d1`, intact at `8f0a69bb`): the stdio Port /
framing / deadline-drain mechanics, the OpenAPI compiler, the `Credentials`
vault, and `Config.load`'s validators. What does **not** come back is the old
architecture — the long-lived multi-upstream aggregator, live mutable catalog,
remote-derived effects, and default-ALLOW grants — all of which conflict with
the owner-based, frozen, deterministic model.

### III.2 Config & credentials

Trust-bearing config (endpoints, commands, `base_url`, credentials) is
**host-owned** and arrives through exactly two channels, both operator-supplied:

1. **Elixir builder** — `Upstream.Source.builder(...)` registered in a
   `ProviderRegistry`.
2. **Host-loaded JSON** — the `{credentials, install}` document of II.3,
   resolved into registry builders before the run. This is the "config-driven,
   no-Elixir" channel.

**Credentials are declared once and bound by reference** (never inline):

```json
"credentials": { "weather_key": { "env": "WEATHER_API_KEY" } }
```

- Sources: `env`, `file`, `literal`. Secrets materialize inside the host/owner,
  are exposed only through the per-request headers callback (P7), and are
  scrubbed from every trace and error.
- **Bindings are validated at config load**: a provider referencing an unknown
  binding, or a binding whose `env`/`file` source cannot be resolved, fails
  before any provider is built or model called. Because the document holds
  only pointers, host JSON is safe to commit and share.
- **Schemes render the resolved value into a header** at the moment of each
  exchange: `bearer` → `Authorization: Bearer <secret>`, `basic` →
  `Authorization: Basic <secret>`, `api_key` → the header named by the entry's
  `header` field. The capability itself stores a header-producing *callback*,
  never a header — which is why snapshots, serialized errors, telemetry, and
  crash dumps are structurally unable to leak it, and why short-lived or
  rotated credentials need no downstream changes.
- **`mcp_stdio` is the one different channel**: there is no request to put a
  header on, so a binding materializes into the subprocess environment at
  spawn:

  ```json
  "env": { "GITHUB_TOKEN": { "binding": "gh_token" } }
  ```

  The env map is redacted from logs and `format_status`, and the
  owner-monitored lease guarantees the subprocess — and the secret in its
  memory — dies with the run.
- The **manifest may never carry** an endpoint, command, `base_url`, header, or
  credential. It selects an installed provider by name and narrows it (II.4).
- The **prelude is not a config channel** — it is frozen source resolving to
  components and cannot register providers or read connection config.

This asymmetry (JSON = install; manifest = narrow; prelude = compose) **is** the
security boundary of P1, made concrete.

### III.3 Preludes as the composition layer

Preludes are where the platform gets its ergonomics (P2). The pattern is always
the same: wrap a primitive, name it, document it, mark visibility. Because the
wrapper is authored with the full schema in hand (P3), the model only ever sees
clean, typed functions — never a raw HTTP verb or a giant schema.

- **Pagination** is a prelude loop over `http/get`, following the API's own
  `next`/cursor — more general than any built-in and zero runtime surface.
  A blessed `cap/paginate` helper ships in the shared prelude so every
  wrapper drives cursors the same way, alongside `cap/unwrap!` for the
  ubiquitous ok-or-`fail` unwrap.
- **OpenAPI** can be delivered as a *prelude generator* (Track E): feed a spec,
  get a prelude of wrappers. The generated prelude is an ordinary prelude.

### III.4 Schema & validation

One pure builtin, JSV-backed (JSV is already a dependency and validates full
JSON Schema 2020-12):

```clojure
(json/validate schema value)   ; -> {:ok value} | {:error errors}
(schema/compile schema)        ; -> opaque handle, for hot loops
```

- **Present-full, validate-best-effort** (P3): schemas are exposed verbatim for
  authoring; validation is advisory and never gates existence.
- **The one security-bearing rule** (P6, and Part IV): because a *program* can
  now author a schema, `pattern`/`patternProperties` must be stripped or
  restricted to a linear-time subset before compilation — this is the single
  place the regex/`:re` node-level hazard is guarded. Everything else in
  2020-12 passes.
- Reuse: validating a model-constructed request body before sending, checking a
  response, gating structured outputs, general data hygiene — not just
  upstream tools.

---

## Part IV — Safety invariants (the three hard guards)

Everything not on this list is allowed to fail by killing a process (P6).

1. **Node vs process — regex.** `pattern`/`patternProperties` run in the Erlang
   `:re` NIF, which can peg a scheduler and is **not reliably aborted by killing
   the owner**. Guard: strip patterns or allow only a bounded linear-time
   subset, everywhere a schema is compiled — most importantly in the
   program-facing `json/validate`. Belt: `max_heap_size` on owner processes and
   `atoms: false` on schema builds (already used) so memory and the atom table
   can't take the node down.
2. **Egress / confidentiality.** Targets are host-frozen: HTTPS-only (loopback
   HTTP behind an explicit flag), no redirects, no userinfo/fragment, optional
   host allow-list, and **never** remote `$ref` resolution. The manifest never
   influences the target host. This is a broader surface for `http_get`/
   `openapi` than for MCP and must be constrained at install time.
3. **Determinism & redaction** (P7). Discovery is once-at-build; every list is
   sorted before hashing; snapshots contain only names, effects, and hashes;
   secrets live only in the per-request callback and are scrubbed from traces.

---

## Part V — Roadmap: separable tracks

Each track is independently landable and is an instance of the same grammar.
Order reflects dependency and risk, not a hard sequence.

- **Track A — Smallest end-to-end.** `http/get` capability (factor out
  MCPSource's bounded HTTP layer) + `json/validate` builtin (pattern-guarded) +
  one example prelude wrapping a public GET API. Proves the whole path with no
  protocol work.
- **Track B — Transport seam.** Define the `Transport` behaviour; refactor the
  current MCP HTTP logic behind it as `mcp_http`; generalize `MCPSource` →
  `Upstream.Source`. **No behavior change** — tests stay green.
- **Track C — MCP stdio.** Port the pre-rewrite Port mechanics into a stdio
  transport + owner-monitored subprocess lease (os_pid tracking, kill-before-
  close, brutal_kill deadline, redacted `format_status`). Delivers the original
  stdio-MCP ask.
- **Track D — Config-driven install.** Adapt `Config.load` + `Credentials` +
  validators so a host JSON `{credentials, install}` document resolves into
  registry builders. Now every source is declarable without Elixir.
- **Track E — OpenAPI.** As a connector source and/or a prelude generator: port the
  compiler, feed schemas through the present-full pipeline, host-derive
  effects (GET → `:read`), carry forward same-origin / reserved-header /
  requestBody guards.
- **Track F — Ergonomics.** Auto-render a canonical `(tool/NAME {...})` example
  from each frozen input schema into `Capability` metadata; list-valid-names on
  unknown-name errors; a `describe-tool` meta-capability for oversized schemas.
  **Front-load this track**: land it alongside Tracks A–B rather than last —
  rendered call examples and valid-names errors are what let models (and
  tutorials) self-correct instead of being defensively documented.
- **Track G — The guide.** Written last, documenting the finished, consistent
  model — the two host install channels, the manifest narrow surface, the
  prelude composition layer, and the explicit non-role of the prelude as config.

---

## Part VI — Open questions

Genuine forks that this document deliberately leaves open for discussion:

1. **Config channel** — host-owned JSON (recommended; preserves P1) vs allowing
   endpoints in the manifest (explicit weakening of the boundary).
2. **Write-capable sources** — POST-for-read (search, GraphQL, batch) and MCP
   write tools break the v1 `effect: :read` freeze. Which destination (mission
   vs workflow) may hold a `:write` capability, and under what host policy?
3. **Multi-source catalog** — merging several frozen provider snapshots for the
   model is the one genuinely missing capability vs the old aggregator, but it
   must be a merge over already-frozen snapshots (stable order, no live
   re-listing), never a shared long-lived connection.
4. **Remote OpenAPI specs** — compile at install (deterministic thereafter,
   couples network I/O to install) vs per-run under a deadline/owner. Static
   `schema` files always compile at install.
5. **Compiled-schema handles** — expose `schema/compile` opaque handles to
   programs for hot loops, or keep validation compile-per-call?
6. **Pagination** — resolved: a prelude pattern (Part III) with a blessed
   `cap/paginate` helper in the shared prelude so every wrapper does it the
   same way, plus `cap/unwrap!` for result unwrapping.

---

## Appendix A — Consistency checklists ("how to add a new X")

These operationalize the guessability test. If a change can't be expressed as
one of these recipes, this document needs updating first.

**Add a new connector source**
1. Implement `open/exchange/discover/close`.
2. Add a `source` value + its "reach/discover/expose" fields to the II.3
   grammar (fill the same slots as the Rosetta table).
3. You inherit Capability emission, II.4 narrowing, the snapshot, redaction, and
   the owner lifecycle for free. Do not re-implement any of them.

**Add a new snapshot source**
1. Implement capture-at-build plus bounded query operations in an owner
   process (the `TraceSnapshot` pattern); no `Transport` behaviour.
2. Add a `source` value whose "reach" fields are local (`root`, `directory`);
   operations surface under default `<provider>.<operation>` names.
3. Emit the same Capability contract; narrowing, snapshotting, redaction, and
   the owner lifecycle apply unchanged.

**Add a new provider instance (operator)**
1. Add a `credentials` binding if it needs a secret.
2. Add an `install` entry filling the same slots as every other provider.
3. Reference it from a manifest by name; add `allow` or lower ceilings only to
   narrow. Done — no Elixir.

**Add a new pure builtin**
- Effect-free → a topic namespace (`json/`, `schema/`, `str/` …). Available to
  every program with no host wiring.

**Add a new effectful capability**
- Host-installed, `effect`-tagged, emits the II.2 contract, secret-free
  snapshot, per-request credential callback.

**Wrap an endpoint for the model**
- A prelude `(ns … {:visibility :prompt})` with `defn` wrappers over the
  primitive. Pagination/retries/shaping go here, not in the runtime.
