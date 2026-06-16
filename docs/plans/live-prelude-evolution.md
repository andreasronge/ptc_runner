# Prelude Evolution and Versioning — Plan

**Status:** design plan, not yet implemented. This is a companion to
[`turn-log-and-prelude-derivation.md`](turn-log-and-prelude-derivation.md),
[`prelude-source-discovery.md`](prelude-source-discovery.md), and
[`capability-prelude-discovery.md`](capability-prelude-discovery.md).

## Motivation

The turn-log derivation loop is now concrete enough to show the next gap:
an agent can inspect logs and source, propose a better prelude, and prove that
the better prelude reduces wasted turns. The `paged/profile` smoke is the
current example:

1. A Claude run wasted turns reading private source and probing upstream shape.
2. A second model inspected the logs and suggested a prelude change.
3. The prelude docs and `row_count` result were updated.
4. A fresh Claude run used `doc paged/profile`, `paged/inspect`, and
   `paged/profile`, finishing successfully in 7 turns.

That loop currently works by editing files and restarting or starting fresh
processes. The desired direction is modest: avoid process-restart latency,
preserve turn-log continuity across A/B attempts, and make programmatic
in-process verification possible. This is **not** a plan for an agent to
hot-patch its own already-running tool context. Fresh model context still
matters.

The user-facing editing workflow should itself be expressed as editable
preludes. The host provides a tiny store substrate; the model-facing behavior
such as "read with dependencies", "summarize public contract", or "write a new
version" lives in the built-in `prelude/` prelude that can be improved like any
other prelude.

This follows an existing pattern in the codebase. `PtcRunner.TraceLog.Introspection`
already exposes a boring Elixir substrate (`tools/1`) and a model-facing
prelude (`prelude_source/0`): the Elixir tools page and project turn-log data,
while the `log/` namespace gives Lisp programs a small stable API such as
`log/sessions`, `log/turns`, `log/programs`, and `log/tool-calls`. Prelude
editing should reuse that split rather than inventing a special MCP-only
control plane.

## Design Constraints

- **Core first.** The MCP server stays a thin projection. Anything exposed as
  `lisp_session_*` should also be available through core APIs used by SubAgent
  and embedding applications.
- **Fresh model context matters.** Updating a prelude changes the Lisp runtime,
  not an LLM's already-seen context. Verification should start a fresh
  agent/session or explicitly inject a prelude-change card.
- **Mutation is privileged and prelude-shaped.** Ordinary PTC-Lisp user
  programs should not get default prelude editing authority. Hosts may grant a
  derivation agent a small store tool set, but the model-facing workflow lives
  in the `prelude/` prelude.
- **Compile-on-write.** A write compiles the new source immediately. If
  compilation fails, nothing is stored and the LLM receives a structured error
  it can repair from.
- **Consumer-bound authority.** Capability `requires` are validated against the
  consuming session/run's grants at attach time, not against the editing
  agent's grants.
- **Preludes are existing compiled artifacts plus provenance.** Do not invent a
  second compiled shape beside `%PtcRunner.Lisp.Prelude{}`. Wrap or pair the
  existing compiled prelude (`source_hash`, namespaces, exports, `private_env`)
  with source, origin, metadata, and store version identity.
- **Every successful write is a version.** `PreludeStore.write/4` compiles the
  source and appends a new version for that prelude id. If the caller does not
  specify a base version, the store writes on top of the current version. This
  keeps the base workflow small: no separate draft/approve state machine.
- **Policy is optional and host-owned.** A store may later require human review
  or policy checks before a version becomes the default for bare-name selection,
  especially for persistent/shared stores. V1 should not require that workflow.
- **Editor prelude is review TCB.** A meta-editor may write new versions of
  the `prelude/` prelude, but a persistent/shared store may choose to require review
  before such a version becomes the default. This does not protect raw runtime
  authority (that is still consumer-bound at attach); it protects the standing
  source disclosure and review workflow that future agents rely on.
- **Stored preludes are untrusted instruction surfaces.** Recorded sessions are
  untrusted data, and agent-authored prelude source/docstrings are too. Any
  policy that changes defaults must treat docs and prompt-visible strings as
  instructions that will be injected into future worker context.

## Reusable Surface Pattern

When a capability needs host state, persistence, external IO, or authority, use
the same two-layer shape as `log/`:

```text
Elixir substrate        owns state, authority, validation, paging, and limits
host-bound tools        tiny tool closures over that substrate
capability prelude      Lisp-facing workflow API over those tools
session/SubAgent/MCP    selects which preludes and grants are attached
```

The Elixir substrate should stay intentionally boring. It should expose data
operations like list/read/write/page, fail closed, and return structured errors.
The prelude owns names, workflow, summaries, source navigation, paging strategy,
and model ergonomics. That keeps the MCP server thin and keeps the ergonomic
API evolvable: improving the `prelude/` prelude is just another prelude improvement.

Current and likely instances:

- `TraceLog.Introspection.tools/1` + `log/` prelude: read-only turn-log
  introspection. This is the shipped precedent.
- Future `PreludeStore` + `prelude/` prelude: list/read/write versioned preludes,
  bounded source-with-deps, and compile-error repair loops.
- Host paginated file/upstream tools + `paged/` or future `data/`: read large
  data through bounded pages and fold in Lisp.
- Upstream runtime/catalog + discovery preludes if the built-in discovery forms
  need a higher-level model-facing workflow.

This does not require every Elixir API to become a prelude. The useful test is:
if an LLM benefits from composing the operation, improving its workflow, or
inspecting it with `doc`/`apropos`, put the model-facing part in a prelude. If
the operation is pure host policy or deployment configuration, keep it in the
host.

`PreludeStore` is intentionally prelude-specific. Do not generalize it into a
polymorphic compiled-artifact store until there is a real second consumer; the
strong invariant here is that the stored compiled value is exactly
`%PtcRunner.Lisp.Prelude{}`.

## Core Abstractions

### Prelude Candidate

Introduce a small candidate/provenance wrapper owned by core. It should wrap
the existing compiled `%PtcRunner.Lisp.Prelude{}` rather than duplicating its
runtime fields:

```elixir
%PtcRunner.PreludeCandidate{
  id: "paged",
  version: 8,
  source: "...",
  compiled: %PtcRunner.Lisp.Prelude{},
  origin: {:file, path} | {:memory, session_id} | {:upstream, ref},
  metadata: %{
    "reason" => "Add row_count and better docs",
    "parent_version" => 7,
    "parent_checksum" => "...",
    "source_session_id" => "...",
    "created_by" => "agent"
  }
}
```

Two invariants matter: compiled runtime state stays
`%PtcRunner.Lisp.Prelude{}`, and identity is single-sourced. A candidate's
checksum is an accessor for `compiled.source_hash` (bare hex as the compiler
emits it), never a second independently stored digest that can drift. Store
versions are assigned by the store on successful write.

### PreludeStore

`PtcRunner.PreludeStore` is the shared source/version store. It is
prelude-specific by design. It is not a second compiler, not an attach path, and
not a policy engine. It stores versioned prelude candidates, calls the existing
`PtcRunner.Lisp.Prelude.Compiler.compile/1` on write, and exposes source plus
compiled metadata for later selection.

Minimal V1 API:

```elixir
PtcRunner.PreludeStore.new(opts \\ [])
PtcRunner.PreludeStore.list(store)
PtcRunner.PreludeStore.read(store, id_or_ref)
PtcRunner.PreludeStore.write(store, id, source, metadata \\ %{})
```

`read/2` returns the candidate record, including source, compiled prelude, and
provenance; callers project source text or compiled metadata as needed. This
keeps the store API small while avoiding separate read paths for editors and
bundle resolution.

The store `id` is a **namespace name** — the single PTC-Lisp namespace the
stored source declares (`"paged"`, `"log"`, `"prelude"`). One store entry owns
exactly one namespace, and that name is the prelude's stable identity across
versions: `list/1` enumerates namespaces, while `read/2` and `write/4` address a
whole namespace, never an individual export. `write/4` enforces the binding — it
compiles the source and, storing nothing, rejects any write whose
`compiled.namespaces` is not exactly `[id]`. A model can therefore rely on "the
id I write is the namespace I get back," and bundle selection is just a set of
namespace ids. This is a store-level invariant for store-managed ids, not a
change to the compiled `%PtcRunner.Lisp.Prelude{}` struct, whose `namespaces`
stays a list for host-shipped multi-namespace preludes.

Function-level operations are deliberately **not** core store primitives.
Reading one export's source or deleting an export are derived workflows in the
`prelude/` prelude: read the whole-namespace source, project or rewrite it, then
`write/4` the whole namespace back as a new compile-checked version. Keeping the
core at namespace granularity keeps list/read/write small and pushes ergonomics
into an evolvable prelude, matching the `log/` precedent.

`write/4` compiles immediately. On failure, nothing is stored:

```elixir
{:error,
 %{
   reason: :prelude_compile_error,
   id: "paged",
   message: "...",
   base_version: 7,
   parent_checksum: "<old source_hash>"
 }}
```

On success, it appends a new version:

```elixir
{:ok, updated_store,
 %{
   id: "paged",
   version: 8,
   checksum: "<new source_hash>",
   namespaces: ["paged"],
   exports: ["inspect", "profile"],
   metadata: %{
     "reason" => "Add row_count and better docs",
     "parent_version" => 7,
     "parent_checksum" => "<old source_hash>"
   }
 }}
```

Do not add `validate` or `diff` host primitives in V1. `write/4` is validation
by construction. Source comparison, dependency following, and summaries should
live in the `prelude/` prelude until repeated usage proves a core primitive is
needed.

Store writes need host-side bounds because they run outside the per-eval Lisp
sandbox. V1 should bound source bytes, compile time, version count, and version TTL;
failed bounds return structured errors and store nothing.

### Prelude Bundle / Attach Selection

Bundle selection is an attach-path concern, not a store concern. The store
returns candidates; the session/SubAgent/MCP start path selects prelude ids,
version pins, or checksum-pinned refs, composes the selected candidates into the single compiled
prelude artifact that today's `Lisp.run/2` accepts as `:prelude`, and freezes
that artifact for the session/run.

`requires` are never discharged by storage, write, or name resolution.
`Lisp.run/2` must re-run the existing fail-closed attach validation against the
consuming run's own `tools`/`runtime` grants on every eval, even when the
compiled bundle was frozen at session start.

Version/checksum refs should be explicit and checksum-pinned when
reproducibility matters:

```elixir
[
  "log",
  "prelude",
  %{id: "paged", version: 8, checksum: "<new source_hash>"}
]
```

Bare names resolve through the store's current default version for that name at
session start, then the resolved versions/checksums are frozen and logged for
the session lifetime. In a simple memory store, `write/4` may make the new
version the default immediately. Future persistent/shared stores may add policy
for changing the default, but versioned writes stay the base primitive.
Reproducibility-sensitive sessions should use explicit version pins, for example
`"paged@7"` or `{id: "paged", version: 7, checksum: "..."}`.

Multi-prelude composition is a real design point because the runtime currently
accepts one `:prelude` artifact. E3 must define composition before implementation
(for example, concatenate selected sources then compile once, or merge compiled
artifacts with equivalent validation) and fail closed on namespace/export
collisions unless a deliberate precedence rule is chosen.

## Session API

`PtcRunner.Session` should be the embedding-friendly stateful surface. A
session starts with a selected prelude bundle and freezes it for the session's
lifetime. New prelude versions are tested by starting a fresh verifier session
with an explicit version/checksum, not by silently mutating an existing worker
session.

Candidate API:

```elixir
session =
  PtcRunner.Session.new(
    prelude_store: store,
    preludes: ["log", "paged"],
    tools: tools,
    upstream_runtime: runtime
  )

{:ok, preludes} = PtcRunner.Session.preludes(session)

{{:ok, step}, session} =
  PtcRunner.Session.eval(session, "(paged/profile ...)")
```

Editor sessions are ordinary sessions started with the `prelude/` prelude and the
store tools it requires. Their outputs are new store versions, not mutations of
other sessions.

## SubAgent API

SubAgent should use the same store and attach-path bundle selection. This is
not MCP-specific; MCP is just one host.

```elixir
{:ok, result} =
  PtcRunner.SubAgent.run(agent, input,
    prelude_store: store,
    preludes: ["log", "prelude"],
    tools: Map.merge(app_tools, prelude_store_tools(store))
  )
```

The host-owned store tools are intentionally boring, but they should use tool
metadata to mark them as prelude-private rather than model-visible. This
requires adding `visibility:` to `%PtcRunner.Tool{}` normalization and
validation; today unknown keyword options would not create an enforced private
tool.

```elixir
tools = %{
  "prelude_store_list" =>
    {fn _ -> PtcRunner.PreludeStore.list(store) end,
     signature: "() -> [:map]",
     description: "List available prelude candidates.",
     expose: :ptc_lisp,
     visibility: :private},

  "prelude_store_read" =>
    {fn %{"id" => id} -> PtcRunner.PreludeStore.read(store, id) end,
     signature: "(id :string) -> :map",
     description: "Read a prelude candidate.",
     expose: :ptc_lisp,
     visibility: :private},

  "prelude_store_write" =>
    {fn %{"id" => id, "source" => src, "metadata" => meta} ->
       PtcRunner.PreludeStore.write(store, id, src, meta)
     end,
     signature: "(id :string, source :string, metadata :map) -> :map",
     description: "Compile and store a new prelude version.",
     expose: :ptc_lisp,
     visibility: :private}
}
```

This should be an ordinary tool-metadata feature, not a one-off
`prelude_backing_tools:` API, but V1 should be deliberately narrow:
`visibility: :private` only. A tool must first be available to the PTC-Lisp
execution surface via the existing `expose:` metadata (`:ptc_lisp` or `:both`);
`visibility: :private` then further restricts that PTC-exposed tool to compiled
prelude code. In other words, visibility is subordinate to `expose:`, not an
independent execution dial.

V1 private tool semantics:

- Omit the tool from the normal `tool/` prompt inventory.
- Omit the tool from tool discovery.
- Reject direct user-program calls such as `(tool/prelude_store_write ...)`.
- Allow calls only while executing an attached prelude export whose compiled
  tool dependency set includes that private tool.
- Validate the tool call's argument map against the tool signature before
  invoking the Elixir function. Signature failures should be recoverable
  `:invalid_tool_args` errors, not `FunctionClauseError` or raw host crashes.

This requires evaluator support; it is not true in today's dispatch path merely
because the tool exists in `tools:`. The implementation should thread prelude
call origin to tool dispatch: prelude closures already carry prelude namespace /
private-env context, and the compiler already records each export's tool refs.
Tool dispatch must consult that origin and allow a `visibility: :private` tool
only when the current call is inside a prelude export whose compiled tool refs
include the requested tool. Without that origin check, a granted tool is
directly callable by user code.

Private-tool failures should include a compact diagnostic trace suitable for
turn-log analysis and prelude repair, not a raw BEAM stacktrace. Suggested
shape:

```json
{
  "reason": "invalid_tool_args",
  "tool": "prelude_store_write",
  "expected": "(id :string, source :string, metadata :map) -> :map",
  "received_keys": ["source"],
  "errors": ["missing required key id", "missing required key metadata"],
  "lisp_trace": [
    {"kind": "prelude_export", "ref": "prelude/write"},
    {"kind": "tool_call", "ref": "tool/prelude_store_write"}
  ],
  "source_refs": ["prelude/write", "tool/prelude_store_write"]
}
```

The trace should point to Lisp/prelude call sites and source refs that an
analysis agent can inspect with `source` / `source-with-deps`. It should avoid
host stack frames, absolute paths outside the configured store/root, secrets,
and full argument values unless separately bounded and redacted.

The same idea may later grow into prompt/discoverable visibility for ordinary
app tools, but that needs a real tool discovery/indexing surface. Do not build
`:prompt`/`:discoverable` tool visibility in V1 just to mirror prelude export
visibility.

The model-facing API on top of those tools lives in the selected
`prelude/` prelude. It declares the Lisp namespace `prelude` and wraps the
host tools:

```clojure
(ns prelude
  "Read and write versioned capability preludes."
  {:visibility :prompt})

(defn list
  "List available preludes and versions."
  []
  (tool/prelude_store_list {}))

(defn source
  "Return the source text for a prelude id or explicit ref."
  [id]
  (get (tool/prelude_store_read {:id id}) "source"))

(defn write
  "Compile and store a new prelude version."
  [candidate]
  (tool/prelude_store_write candidate))
```

The host does not bind tools to a namespace manually. It attaches the
`prelude/` prelude and grants tools with matching names in `tools:`. The
compiler sees `(tool/prelude_store_read ...)` and records `tool:prelude_store_read`
on the exported `prelude/source`; attach fails closed if that tool is not
granted. Because the tool is `visibility: :private`, only the compiled prelude
export should be able to call it once the evaluator origin check above exists.
This is the same pattern as `TraceLog.Introspection.tools/1` plus the `log/`
prelude, with stricter visibility for the raw backing tools.

The resulting model-facing calls look like:

```clojure
(prelude/list)
(prelude/source "paged")
(prelude/source-with-deps "paged/profile")
(prelude/write
  {:id "paged"
   :source new-source
   :metadata {:reason "Add row_count and better docs"}})
```

The `prelude/` prelude is an E4 facade over the E2 store tools, not core substrate.
The store should stay usable directly from Elixir and from simple host tools
without depending on any particular editor prelude implementation.

`prelude/source` returns the current source text for a prelude candidate by id
or explicit ref. It is the direct wrapper over `PreludeStore.read/2` for agents
that need full-source editing.

`prelude/source-with-deps` should be deliberately bounded. For an exported
symbol like `"paged/profile"`, it should return that export's source, the
compiler-known transitive same-namespace private helpers that back it, and the
declared `requires` references. It should not become arbitrary cross-prelude
source dumping. Normal worker agents should use public docs and shape helpers;
editor agents get `source-with-deps` because they are explicitly changing
source. Implement it as a projection over the compiler's existing source index
and backing metadata; do not reimplement a separate source walk in the host.

The SubAgent loop should not silently inherit prelude editing capability into
child agents. Hosts opt in per agent/run.

## MCP Server Projection

The MCP server should expose only:

```text
lisp_session_list_preludes
lisp_session_start(preludes: [...])
lisp_session_eval
```

`lisp_session_list_preludes` calls `PreludeStore.list/1`.
`lisp_session_start` resolves the requested bare-name preludes or explicit
version/checksum refs through the core attach-path bundle selection and freezes that
bundle for the session. Editing operations are not bespoke MCP tools; an editor
session gets the `prelude/` prelude plus host-bound store tools, then uses normal
`lisp_session_eval`.

The MCP layer owns only transport concerns: argument validation, owner checks,
envelope shaping, output limits, and turn-log events. It should not compile,
diff, checksum, or persist preludes itself.

## Context Refresh Workflow

Updating a prelude changes the Lisp runtime, not the LLM's already-loaded
context. The near-term workflow should therefore use fresh agents for each
phase:

```text
1. Worker agent
   - Starts a PTC session with current default preludes.
   - Attempts the task.
   - Produces turn logs.

2. Analyst/editor agent
   - Starts a fresh session with ["log", "prelude"].
   - Reads turn logs plus current prelude source through prelude exports.
   - Calls (prelude/write ...) to create a compile-checked new version.

3. Optional meta-editor agent
   - Starts a fresh session with ["log", "prelude"].
   - Inspects the editor run's logs.
   - Writes improvements to the `prelude/` prelude itself as a new version.

4. Verifier agent
   - Starts a fresh PTC session with the new version/checksum selected.
   - Runs the same task.
   - Compares correctness, turns, cost, tool calls, and source/doc usage.

5. Default-selection step
   - In a scratch memory store, the new version may already be the default.
   - In a persistent/shared store, host policy may decide whether that exact
     version/checksum becomes the default for bare-name selection.
```

This can be simulated today with Claude Code/Codex subprocesses and files:

```bash
claude -p "$TASK" --mcp-config current.json > run-1.jsonl
claude -p "$ANALYZE_LOGS_AND_WRITE_VERSION" > edit-1.jsonl
mix test ...
claude -p "$TASK" --mcp-config paged-v8.json > verify-1.jsonl
```

Later, `PreludeStore.write/4` plus prelude selection on session start removes
the need to restart the MCP server and makes in-process A/B possible, but the
verifier should still be a fresh model context unless the host explicitly
injects a compact prelude-change card.

## Persistence Direction

Do not implement database/upstream persistence in V1, but keep the API
storage-agnostic.

For MCP deployments, stricter policy about changing defaults should live beside
the existing upstream endpoint selection in the MCP JSON/config layer, not in
the Lisp-facing editor API. SubAgent hosts configure the equivalent policy
directly in Elixir when they choose `prelude_store:`, `preludes:`, `tools:`,
and any future default-selection options.

Example future MCP config shape:

```json
{
  "preludes": {
    "store": {
      "backend": "filesystem",
      "root": "./preludes"
    },
    "defaults": {
      "auto_update_defaults": true,
      "review_required_namespaces": ["prelude"]
    }
  }
}
```

Possible future store behaviour:

```elixir
PtcRunner.PreludeStore.list(store)
PtcRunner.PreludeStore.read(store, id_or_ref)
PtcRunner.PreludeStore.write(store, id, source, metadata)
PtcRunner.PreludeStore.set_default(store, id, version, opts)
PtcRunner.PreludeStore.history(store, id)
```

Candidate stores:

```text
PtcRunner.PreludeStore.Memory
PtcRunner.PreludeStore.FileSystem
PtcRunner.PreludeStore.Upstream
```

The store assigns `version` during `write/4`. A simple memory store can make
each successful write the default immediately. A persistent/shared store can
keep the same versioned write primitive but require policy before `set_default/4`
changes bare-name resolution.

The initial `prelude/` prelude is bootstrapped as a host-shipped, checked-in
prelude, for example origin `{:file, "priv/preludes/prelude.clj"}`.
Later improvements to the editor can go through the same versioned write and
verification loop as any other prelude.

Current turn logs record the attached prelude provenance as the existing
`TurnEvent.prelude_provenance/1` shape:

```json
[
  {
    "source_hash": "<bare-hex source_hash>",
    "namespaces": ["paged"]
  }
]
```

The target extension is to add origin/version identity to each entry when
the host knows it:

```json
{
  "source_hash": "<bare-hex source_hash>",
  "namespaces": ["paged"],
  "origin": "file:examples/paged_data_prelude/paged_data.clj",
  "version": 7
}
```

The existing turn-log provenance already records namespaces and `source_hash`;
adding origin/version to that existing provenance field is a cheap
near-term improvement and does not require the full store.

## Phases

### E1. Documented Manual Loop

- Keep using file edits and fresh Claude/Codex runs.
- Record traces before and after each prelude improvement.
- Compare turn count, cost, correctness, and whether the model used public
  docs instead of private source.
- Pull forward the cheap provenance improvement: extend existing turn-log
  prelude provenance beyond namespaces + `source_hash` when the host knows
  origin/version.

### E2. Core PreludeStore

- Add candidate/source/provenance data structures that wrap existing compiled
  `%PtcRunner.Lisp.Prelude{}`.
- Add `PreludeStore.list/read/write`.
- Compile writes atomically through the existing compiler.
- Add tests for successful write, compile failure storing nothing,
  checksum/provenance, source-size and version-count bounds, and explicit
  version/checksum reads.

### E3. Session Integration

- Let `PtcRunner.Session` resolve a selected prelude bundle at start.
- Define how multiple selected candidates compose into the single
  `%PtcRunner.Lisp.Prelude{}` artifact accepted by `Lisp.run/2`; fail closed on
  namespace/export conflicts until a precedence rule is deliberately chosen.
- Freeze the bundle for the session lifetime.
- Re-run attach-time fail-closed `requires` validation against the consuming
  session's grants on every eval, even for a frozen bundle.
- Emit turn-log provenance for the active prelude versions.
- Add a regression test where a worker with a strict-subset grant set selects an
  prelude name and fails closed on first eval.

### E4. SubAgent Integration

- Let SubAgent accept `prelude_store:` and `preludes:`.
- Extend `%PtcRunner.Tool{}` normalization and validation with
  `visibility: :private` for PTC-exposed tools.
- Thread prelude export call origin to tool dispatch so private tools are
  executable only from compiled prelude exports whose tool refs include that
  tool; direct user-program calls fail closed.
- Validate PTC-Lisp tool-call args against tool signatures before invoking
  private tools, returning structured `:invalid_tool_args` diagnostics with a
  compact Lisp/prelude call trace for log-driven repair.
- Grant `prelude_store_list/read/write` as private PTC-exposed tools: available
  to prelude exports for `requires` validation and execution, but not rendered
  in `tool/`, not discoverable, and not directly callable by user programs.
- Build the `prelude/` prelude over those tools.
- Prevent implicit inheritance of prelude editing authority into child
  SubAgents.

### E5. MCP Projection

- Add `lisp_session_list_preludes`.
- Extend `lisp_session_start` with `preludes: [...]`.
- Keep `lisp_session_eval` as the only execution/editing path.
- Keep MCP-specific code limited to validation, ownership, envelopes, and
  output limits.

### E6. Persistent Defaults / Policy

- Add `set_default/history` only after versioned writes + verifier sessions have
  proven useful.
- Start with filesystem or memory-backed persistence.
- Keep default changes explicit and auditable when a store is persistent/shared.
- Assign monotonic versions in the store write layer.

## Open Questions

- Bundle composition is mostly settled by binding each store `id` to a single
  namespace: two store entries can never own the same namespace, so the only
  residual conflict is selecting two versions of the same namespace id in one
  bundle, which must fail closed. (Open: whether a deliberate precedence rule is
  ever worth adding instead of failing closed.)
- How much of the selected prelude docs/discovery card should be returned by
  `session_start`?
- Should the `prelude/` prelude expose multi-edit patches, or require full-source
  writes until a clear need appears?
- What policy decides that a tested prelude version becomes the default in a
  persistent/shared store?
- Should tool prompt/discovery visibility beyond `:private` ever be added, or
  should ordinary app-tool discovery remain outside V1 until a concrete user
  appears?
