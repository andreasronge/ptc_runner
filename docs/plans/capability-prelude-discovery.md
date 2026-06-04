# Capability Prelude V1 Requirements

## Problem

PtcRunner should let deployments expose curated, Lisp-facing APIs without
hard-coding each API into PtcRunner core or prompt-stuffing full prelude source.

Today, agent-visible inputs are split across several useful surfaces:

- `data/` bindings from runtime context;
- typed `tool/name` calls for registered tools;
- upstream MCP/OpenAPI discovery through `(tool/servers)`, `dir`, `doc`,
  `meta`, and `apropos`;
- session memory and journal state carried separately.

Those surfaces should keep working. The V1 problem is narrower: a deployment
should be able to load a stateless PTC-Lisp prelude that defines protected
namespaces such as `crm`, `workflow`, or `journal`, then have agent code call
and discover those exports normally:

```clojure
(def user-result (crm/get-user data/user-id))
(doc 'crm/get-user)
(ns-publics 'crm)
```

The first shipped slice proves one thing: deployment-defined Lisp APIs can be
compiled, attached to a real run, protected, resolved by the analyzer/evaluator,
discovered by Lisp-facing namespace/documentation forms, and summarized in the
prompt.

## Non-goals

V1 deliberately does not include:

- hidden mutable sandbox state;
- append-only hidden prelude events;
- `ptc/wrap-stateful`;
- `ptc.author`, `defcap`, `defsandbox`, `defagent`, or any authoring DSL;
- LLM-authored prelude workflows;
- generic `cap/list`, `cap/search`, or `cap/meta` migration;
- full descriptor taxonomy;
- SubAgent-as-tool registry unification;
- agent-published capabilities;
- expanded REPL LLM/model/credential configuration;
- removing `(tool/servers)` or changing existing `tool/`, `data/`, or upstream
  behavior.

This is a 0.x library, so backward compatibility shims are not required. Still,
ship smaller breaking changes one at a time: add protected prelude exports while
keeping existing `tool/`, `data/`, and discovery behavior working.

## V1 Requirements

### 1. Compiled Stateless Prelude

PtcRunner should support loading a configured PTC-Lisp prelude before user code.
The prelude is stateless in V1. It may define namespaces, constants, functions,
docstrings, and metadata, but it does not receive or commit hidden state.

`(ns ...)` is a prelude-compiler directive in V1, not a general user-runtime
form. Ordinary user programs should not gain partial Clojure namespace loading
semantics as part of this slice.

Example prelude:

```clojure
(ns crm
  "CRM helpers."
  {:visibility :prompt})

(defn get-user
  "Return a CRM user by id."
  [id]
  (tool/call {:server "crm"
              :tool "get_user"
              :args {:id id}}))
```

The compiled prelude artifact should include:

- protected namespace tables;
- public export records;
- captured private prelude environment;
- source hash and enough metadata for traces/debugging;
- validation errors when prelude compilation fails.

V1 should use focused structs for the compiled artifact rather than passing raw
maps through analyzer, evaluator, discovery, and prompt code. Initial modules may
include:

- `PtcRunner.Lisp.Prelude` for the compiled prelude artifact;
- `PtcRunner.Lisp.Prelude.Export` for public export records;
- `PtcRunner.Lisp.Prelude.Compiler` for source compilation and validation.

`-l/--load` remains ordinary user-code loading. Deployment preludes should use a
separate loader path so protected namespaces and export metadata are exercised
the same way in REPL and SubAgent execution.

### 1A. Run Attachment API

V1 needs one explicit API seam for attaching a compiled prelude to a real run.
The intended attachment points are:

- direct Lisp execution accepts a `prelude:` option, where the value is either a
  compiled prelude artifact or prelude source that is compiled before user-code
  analysis;
- SubAgent execution accepts a `runtime_prelude:` field on
  `%PtcRunner.SubAgent.Definition{}` and passes the same compiled artifact into
  the Lisp analyzer/evaluator path;
- `mix ptc.repl --prelude file.clj` compiles the file into the same artifact
  shape and passes it through the same `prelude:` execution path.

Future sandbox profiles may own this setting, but V1 should not wait for a
first-class sandbox profile before supporting deployment preludes.

### 2. Protected Namespaces

Configured prelude namespaces are protected. User programs must not redefine:

- configured namespaces;
- public prelude exports;
- private prelude helpers inside configured prelude namespaces;
- reserved namespaces such as `tool`, `data`, `budget`, `ptc.core`, and the
  chosen future catalog namespace.

Attempts to write protected names with `def`, `defn`, or namespace forms should
return a programmer fault with a clear message.

Prelude compilation must also reject declarations for reserved namespaces. A
deployment prelude cannot define `(ns tool ...)`, `(ns data ...)`,
`(ns budget ...)`, or any other reserved namespace. This should fail at prelude
compile time before any user program runs.

Even if general qualified `def` / `defn` remains unsupported, the analyzer must
recognize qualified definition targets well enough to reject writes into
protected namespaces with a protection error rather than a generic invalid
syntax error.

Qualified definitions do not need to become generally supported in V1. Required
behavior is targeted:

- `(defn crm/get-user ...)` returns a protected namespace/export programmer fault
  when `crm/get-user` is protected;
- `(def crm/x ...)` returns a protected namespace programmer fault when `crm` is
  protected;
- qualified definitions outside protected namespaces may remain unsupported and
  return an explicit unsupported qualified-definition error.

The mutable `user` namespace remains available for agent/user code. Shadowing
ordinary user bindings is allowed when it does not target a protected namespace
or symbol. If a private prelude helper is captured under the hood, user code may
still define an unrelated unqualified helper with the same display name in the
mutable `user` namespace; it must not be able to write into the protected
prelude namespace or alter the captured helper used by public exports.

### 3. Export Records

V1 should use simple export records rather than the full future descriptor
taxonomy.

An export record is the per-sandbox projection that the analyzer, evaluator,
discovery, and prompt renderer consult. It is derived from compiled prelude
facts plus host policy. It is not an independent source of authority.

Minimal shape:

```elixir
%{
  ref: "crm/get-user",
  namespace: "crm",
  symbol: "get-user",
  arity: 1,
  doc: "Return a CRM user by id.",
  visibility: :prompt,
  effect: :read,
  provider_ref: "upstream:crm/get_user",
  requires: ["upstream:crm/get_user"]
}
```

Rules:

- `ref` is the Lisp-facing export ref.
- `provider_ref` identifies the backing provider or operation.
- `requires` entries resolve to canonical backing ids, not display-only names.
- `provider_ref`, `requires`, and resolved `effect` should come from explicit
  host or prelude metadata in V1.
- V1 may infer backing metadata only for simple literal patterns such as
  `(tool/call {:server "crm" :tool "get_user" ...})`.
- Dynamic backing calls, such as `(tool/call {:server server :tool tool ...})`,
  should resolve to `effect: :unknown` unless explicit host metadata narrows
  them.
- Lisp-facing names should use the curated Lisp spelling selected by the
  prelude, usually kebab-case.
- Host/external data should use string keys and snake_case when serialized.
- PTC-Lisp metadata may use kebab-case keywords such as `:provider-ref`; the
  compiler normalizes them at the host boundary.

V1 export records are enough for prelude functions and configured namespaces.
Native tool, SubAgent, and generic capability unification is deferred.

Prelude validation is split into two phases:

- compile-time validation checks source syntax, `(ns ...)` directives, duplicate
  refs, reserved namespace declarations, export metadata, visibility values,
  arity/doc metadata, and other facts that do not depend on a selected runtime;
- attach-time validation checks `requires` against the selected upstream runtime,
  tool grants, and host policy before user code is analyzed.

This allows a compiled prelude artifact to be reused across runs while still
failing before execution when the selected runtime does not provide a required
backing operation.

### 4. Analyzer Resolution

Prelude exports must be known before user code is analyzed. A runtime-defined
wrapper value cannot retroactively become an analyzer-known callable export.

The analyzer should accept a namespaced call such as `crm/get-user` only when
the selected sandbox export table contains that export and the arity is valid.
Unknown namespaced calls should remain programmer faults with actionable
messages.

The static bounded namespace vocabulary should be augmented or replaced by the
selected sandbox's namespace/export table for this path. Do not broaden the
global allowed namespace set just to make one deployment prelude work.

### 5. Evaluator Resolution

The evaluator must use explicit namespace storage, not only the existing flat
mutable `user_ns`.

V1 should define resolver order for user code. A reasonable order is:

1. lexical/local bindings;
2. mutable `user` namespace;
3. public protected prelude exports;
4. built-ins and configured runtime namespaces.

Private prelude helpers live in the captured compiled prelude environment, not
in the public export table. Public prelude exports may call those helpers through
their captured environment, but user code must not resolve private helpers by
qualified symbol. Private helpers are implementation details of the compiled
prelude artifact, not discoverable API entries.

### 6. Existing Tool Paths Stay Unchanged

V1 prelude exports call existing tool surfaces. They do not create a new
transport or authority layer.

Two tool-call forms remain first-class:

- `(tool/call {:server ... :tool ... :args ...})` is the generic upstream
  virtual tool. It dispatches through `PtcRunner.Upstream.CallTool` and
  `PtcRunner.Upstream.Runtime.call_tool/5`.
- `(tool/name {:arg ...})` is a typed registered tool call.

Prelude exports may wrap either surface. Existing validation, effects,
idempotency, authorization, resource caps, transport dispatch, MCP result
normalization, and recoverable failure values stay in the existing tool/upstream
paths.

Prelude exports should be recoverable-by-default when wrapping recoverable tool
surfaces. A wrapper around `(tool/call ...)` should normally return the same
recoverable result map that `tool/call` returns so agent code can branch on
`:ok`, `:reason`, and related fields. Prelude authors may define explicit
abort-on-error helpers, preferably with names that make the behavior visible
such as `get-user!`, by calling `fail` themselves. `fail` should remain reserved
for programmer faults or intentionally aborting convenience functions, not be the
default behavior of every curated wrapper.

### 6A. Relationship to Upstream Configuration

V1 does not change the existing upstream MCP/OpenAPI endpoint configuration
format. Endpoint definitions, credentials, static headers, auth emitters,
timeouts, response caps, schema sources, and insecure-HTTP gates remain
host/deployment configuration.

The existing upstream transports stay explicit:

- `"openapi"` for curated JSON OpenAPI operations;
- `"mcp_stdio"` for external MCP servers launched over stdio;
- `"mcp_http"` for external MCP servers reached over Streamable HTTP/SSE.

Prelude source must not define new upstream endpoints or credentials. A prelude
may wrap already-configured upstream operations through `(tool/call ...)`, and
its export metadata may declare `requires` entries such as
`"upstream:crm/get_user"`.

Prelude attachment should fail before user-code analysis when a public export
requires an upstream operation that is not configured or not granted to the
selected runtime. Dynamic upstream calls whose server/tool are runtime values
should remain unknown-effect unless explicit host metadata narrows them.

Future sandbox profiles may own upstream selection and narrowing. V1 should only
consume the already-selected upstream runtime.

`"mcp_http"` upstream configuration is distinct from the `ptc_runner_mcp` HTTP
listener. The former is an outbound/client transport for calling external MCP
servers; the latter exposes PtcRunner's own MCP server over HTTP.

### 7. Runtime Ledger Stays Unchanged

Use the existing upstream `RunContext` / `Collector` ledger unchanged in V1.
Do not add a second ledger.

The V1 prompt projection may summarize existing ledger entries, for example:

```text
;; === execution state ===
;; Tool calls made: 1
;; Tool call errors: 0
```

Do not add cache behavior to V1. Existing typed Lisp tool caching through
`tools_meta` remains unchanged. A later cache-policy plan can decide whether
upstream `(tool/call ...)` participates in a canonical cache engine and how
cache hits should be represented.

Stable ledger refs must not depend on append order under parallel execution.
If V1 exposes stable refs, they should include deterministic metadata such as
provider id, export ref, call-site or expression path, worker identity, and
worker-local sequence. Friendly display counters such as `#1` are presentation
only.

### 8. Discovery

V1 should expose prelude namespaces and public exports through Lisp-facing
discovery forms. `doc`, `dir`, `meta`, `apropos`, and `ns-publics` are existing
forms being extended; `all-ns` and `ns-name` are new V1 namespace-reflection
forms.

```clojure
(all-ns)
(ns-name 'crm)
(ns-publics 'crm)
(dir 'crm)
(doc 'crm/get-user)
(meta 'crm/get-user)
(apropos "user")
```

Discovery should use the same export records as the analyzer/evaluator. Do not
build a separate prompt/discovery registry.

Namespace refs in V1 should be concrete and testable:

- discovery inputs accept quoted namespace symbols such as `'crm` and namespace
  strings such as `"crm"`;
- namespace names are represented at the host boundary as strings;
- `(ns-name 'crm)` returns `"crm"`;
- `(all-ns)` returns a sorted list of namespace-name strings;
- `(ns-publics 'crm)` returns a map keyed by public symbol strings, with values
  carrying doc/meta data in the existing Lisp-friendly representation.

`all-ns` should expose a curated Lisp-facing namespace set, not the raw internal
bounded namespace vocabulary. It must not leak BEAM internals, Java classes, or
implementation-only namespaces.

Discovery source precedence should be deterministic:

- exact prelude export refs should resolve through the prelude export table and
  should not fall through to MCP discovery;
- exact built-in/local refs keep their current local discovery behavior;
- prelude compilation rejects namespace conflicts with reserved/built-in
  namespaces, so exact prelude-vs-built-in conflicts should not occur in V1;
- `apropos` merges prelude exports, existing local/built-in matches, and MCP
  matches with a stable source order and score sort. The chosen source order
  should be pinned in tests.

Public export visibility values:

- `:prompt` - included in prompt inventory and discoverable;
- `:discoverable` - omitted from prompt inventory but available through
  discovery forms.

Private prelude helpers are not public exports and should not have export
records in V1. They live only in the captured private prelude environment used by
public exports, so user code cannot resolve or discover them by qualified symbol.

Host policy may only narrow visibility. Prelude metadata is advisory and cannot
broaden authority.

### 9. Prompt Inventory

V1 should render a compact prompt inventory from the same export records used by
analysis, evaluation, and discovery.

The prompt inventory should include:

- prompt-visible namespace summaries;
- prompt-visible export names, short docs, arity/signature where available;
- effect hints after host/runtime resolution;
- discovery hints for omitted discoverable exports;
- compact existing ledger summary when available.

The prompt renderer should be deterministic and bounded by implementation
limits. Avoid baking unvalidated numeric limits into this requirements doc; the
implementation should choose and test caps.

Core prompt text must remain domain-blind. Deployment-specific terms should
come from the selected prelude/export records or deployment config, not from
maintained core prompts.

The prompt inventory should be inserted through dynamic SubAgent context
assembly, not by editing static core prompt templates with deployment-specific
content. Static prompt templates may mention only stable, domain-blind discovery
mechanics.

### 10. Metadata Precedence

Prelude metadata is not a security boundary. Host policy and runtime facts are
authoritative.

Precedence is highest-wins:

1. runtime facts, such as actual arity and backing provider;
2. host policy and host overrides;
3. prelude metadata;
4. namespace defaults;
5. global defaults.

Runtime facts are non-overridable. Host policy may narrow or replace advisory
metadata. Prelude metadata and defaults must never weaken host policy, broaden
granted authority, or override runtime facts.

Bad export metadata should fail fast at prelude load time when it affects V1
behavior. Examples include reserved namespace declarations, invalid visibility
values, duplicate public refs, invalid arity/signature metadata, and metadata
that conflicts with host policy.

### 11. REPL Support

V1 REPL support should be minimal:

```bash
mix ptc.repl --prelude crm.clj
mix ptc.repl --prelude crm.clj --show-prompt-inventory
mix ptc.repl --prelude crm.clj -e "(ns-publics 'crm)"
```

The REPL should use the same prelude compiler, protected namespace tables,
export records, analyzer/evaluator resolution, and prompt inventory renderer as
SubAgent execution. It should not become a parallel implementation.

### 12. Traceability

Trace/debug output should include enough information to reproduce the V1
capability environment:

- prelude source hash;
- compiled prelude artifact hash if applicable;
- export record summary;
- selected protected namespaces;
- host policy hash or identifier when available.

Secrets and credential values must not appear in prompts, descriptor dumps,
traces, debug records, or error messages.

## V1 Acceptance Cases

V1's success bar is that the mechanism works end to end. It does not need to
prove that agents perform better than prompt-stuffed tools/context. Benchmark
comparisons are deferred until the prelude mechanism exists and can be tested
against real agent workflows.

### Attach a Prelude to Execution

Given a compiled prelude artifact for `crm`, each supported execution surface can
attach it through the V1 seam:

```elixir
PtcRunner.Lisp.run(program, prelude: crm_prelude)

%PtcRunner.SubAgent.Definition{
  runtime_prelude: crm_prelude
}
```

```bash
mix ptc.repl --prelude crm.clj -e "(ns-publics 'crm)"
```

Expected:

- direct Lisp execution, SubAgent execution, and REPL execution use the same
  compiled prelude artifact shape;
- user-code analysis sees the same protected namespace/export table in each
  surface;
- behavior does not depend on prompt-only configuration.

### Load and Call a Prelude Export

Given a prelude:

```clojure
(ns crm
  "CRM helpers."
  {:visibility :prompt})

(defn get-user
  "Return a CRM user by id."
  [id]
  (tool/call {:server "crm"
              :tool "get_user"
              :args {:id id}}))
```

And user code:

```clojure
(def res (crm/get-user "u_123"))
(if (res :ok)
  (return {:user (res :value)})
  (return {:error (res :reason)}))
```

Expected:

- analyzer accepts `crm/get-user`;
- evaluator resolves it from protected prelude exports;
- existing `tool/call` path runs;
- existing upstream ledger records one upstream attempt;
- the recoverable `tool/call` result remains available for user code to branch
  on;
- result is returned through the existing Lisp/MCP response path.

### Discover a Prelude Export

Program:

```clojure
(ns-publics 'crm)
(doc 'crm/get-user)
(meta 'crm/get-user)
```

Expected:

- public export appears in `ns-publics`;
- docstring is available through `doc`;
- metadata is available through `meta`;
- private helpers do not appear.

### Reject Protected Redefinition

Program:

```clojure
(defn crm/get-user [id] {:fake true})
```

Expected:

- compile/analyze/eval returns a protected namespace/symbol programmer fault,
  not a generic invalid qualified-name syntax error;
- message names the protected namespace or symbol;
- protected prelude export remains unchanged.

### Reject Unknown Namespaced Call

Program:

```clojure
(crm/delete-user "u_123")
```

Expected:

- analyzer returns an unknown export / unbound namespaced symbol error;
- message suggests discovery forms such as `(ns-publics 'crm)` or
  `(apropos "user")` when appropriate.

### Private Helper Is Not User-visible

Given a public export that uses an internal helper, user code cannot call the
helper directly:

```clojure
(crm/normalize-user {:id "u_123"})
```

Expected:

- user code receives an unknown export / private helper error;
- public `crm/get-user` can still call the helper internally.

### Prompt Inventory

With `crm/get-user` marked `:prompt`, prompt inventory includes a compact entry
for `crm/get-user` and a hint that additional exports can be discovered through
`doc`, `dir`, `apropos`, or `ns-publics`.

With an export marked `:discoverable`, prompt inventory omits the detailed entry
but discovery forms can still find it.

## Delivery Slices

V1 can ship in two smaller slices if the evaluator changes prove invasive:

1. Core resolver/protection: prelude attachment, prelude compilation, protected
   namespace/export tables, analyzer resolution, evaluator resolution, protected
   redefinition rejection, reserved-namespace rejection, and private helper
   capture.
2. Discovery/prompt inventory: `doc`, `dir`, `meta`, `apropos`, `ns-publics`,
   new `all-ns` / `ns-name`, prompt inventory rendering, and compact existing
   ledger summary.

The first slice should not expose a partial prompt/discovery registry. The
second slice should reuse the export records and compiled prelude artifact from
the first slice.

For the first spike, prefer this implementation order:

1. Add `PtcRunner.Lisp.Prelude`, `PtcRunner.Lisp.Prelude.Export`, and
   `PtcRunner.Lisp.Prelude.Compiler` with tests for `(ns ...)`, `defn`,
   docstrings, visibility, duplicate refs, and reserved namespace rejection.
2. Add attach-time `requires` validation against the selected upstream runtime
   and host policy.
3. Thread the compiled prelude artifact into analyzer/evaluator options.
4. Add protected write rejection for qualified `def` / `defn` targets.
5. Extend discovery and dynamic prompt inventory rendering.

## Implementation Notes

- Prefer adding a compiled prelude artifact over interpreting prelude source
  before every user program.
- Keep namespace and export refs string-backed at the host boundary to avoid
  atom leaks.
- Use existing safe interning rules where atoms are unavoidable.
- Keep V1 export records small and implementation-shaped; do not implement the
  future descriptor taxonomy unless V1 needs it.
- Integration tests should exercise the full path: prelude load -> analyzer ->
  evaluator -> discovery -> prompt inventory.
- Bug fixes should include failing tests before implementation.

## Deferred Work

The following ideas are plausible later, but are out of V1:

- hidden append-only prelude events and pmap merge semantics;
- stateful prelude wrappers;
- cache policy declarations in prelude/export metadata;
- moving existing `tools_meta` cache flags into a descriptor model;
- generic capability catalog APIs such as `cap/list`, `cap/search`, and
  `cap/meta`;
- migration or removal of `(tool/servers)`;
- full descriptor taxonomy with `descriptor_type`, `provider_kind`, and
  `facets`;
- SubAgent-as-tool, native tool, and upstream operation unification under one
  registry;
- `ptc.author`, `defcap`, `defsandbox`, `defagent`;
- LLM-authored prelude proposal/approval workflows;
- agent-published capabilities;
- expanded REPL LLM/model/credential configuration;
- benchmark-gated prompt/discovery comparisons.
