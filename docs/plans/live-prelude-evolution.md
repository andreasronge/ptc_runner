# Prelude Evolution and Promotion — Plan

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
matters; the useful product is a shared core API where sessions, SubAgents, and
MCP tools can all read, replace in a scratch environment, test, and eventually
promote preludes without duplicating mutation logic in the MCP server.

## Design Constraints

- **Core first.** The MCP server stays a thin projection. Anything exposed as
  `lisp_session_*` should also be available through core APIs used by
  SubAgent and embedding applications.
- **Fresh model context matters.** Updating a prelude in a running Lisp session
  changes the runtime, not an LLM's already-seen context. The verification path
  should start a fresh agent/session or explicitly inject a prelude-change card.
- **Mutation is privileged.** Ordinary PTC-Lisp user programs should not get a
  default `(prelude/replace ...)` capability. Hosts may grant prelude-editing
  tools to a derivation agent.
- **Atomic replacement.** Compile the new source first. If compilation fails,
  keep the old prelude. Capability `requires` are validated against the
  consuming session/run's grants at attach time, not against the editing
  agent's grants.
- **Preludes are existing compiled artifacts plus provenance.** Do not invent a
  second compiled shape beside `%PtcRunner.Lisp.Prelude{}`. Wrap or pair the
  existing compiled prelude (`source_hash`, namespaces, exports, `private_env`)
  with origin/metadata/promotion identity.
- **Promotion is explicit.** A self-improvement loop may test a session-local
  prelude, but persisting it to a filesystem/database/upstream store should be
  a separate host-approved step.
- **Session-local drafts have no store version.** Drafts are identified by
  checksum/proposal id. Monotonic versions are assigned only by a store during
  promotion.

## Proposed Core Abstractions

### Prelude Candidate

Introduce a small candidate/provenance wrapper owned by core. It should wrap
the existing compiled `%PtcRunner.Lisp.Prelude{}` rather than duplicating its
runtime fields:

```elixir
%PtcRunner.PreludeCandidate{
  id: "paged",
  source: "...",                 # canonical text; compiled + checksum derive from it
  compiled: %PtcRunner.Lisp.Prelude{},
  checksum: compiled.source_hash, # NOT a second hash — alias of the compiler's bare-hex source_hash
  draft_id: "draft-...",
  version: nil,                  # store-assigned only after promotion
  origin: {:file, path} | {:memory, session_id} | {:upstream, ref},
  metadata: %{
    "title" => "Paged data helpers",
    "created_by" => "human" | "agent",
    "proposal_id" => "..."
  }
}
```

The exact struct can be smaller in V1. Two invariants matter: compiled runtime
state stays `%PtcRunner.Lisp.Prelude{}`, and identity is single-sourced —
`checksum` is exactly `compiled.source_hash` (bare hex as the compiler emits it,
no `sha256:` prefix), never a second independently computed digest that can
drift. The new layer adds only provenance, draft identity, and later
store-assigned promotion identity.

### PreludeEnv

`PtcRunner.PreludeEnv` is a value-shaped experiment environment. It is not a
GenServer and not a second compiler, **and it is not a second attach path**. It
holds candidates and calls the existing
`PtcRunner.Lisp.Prelude.Compiler.compile/1` to stage them. It never binds
authority itself: authority-bearing attach happens only through
`PtcRunner.Lisp.run/2` / `PtcRunner.Lisp.Prelude.Attach.attach/2` with an
`%AttachContext{runtime, tools}` carrying the **consuming** run's grants. MCP
sessions and SubAgents should call this module rather than implementing their
own prelude editing.

Candidate API (compile/provenance only — no `attach`, to avoid colliding with
the authority-bearing `Prelude.Attach.attach/2`):

```elixir
PtcRunner.PreludeEnv.new(opts \\ [])
PtcRunner.PreludeEnv.stage(env, namespace, source, meta \\ [])  # compile + hold candidate
PtcRunner.PreludeEnv.list(env)
PtcRunner.PreludeEnv.source(env, namespace)
PtcRunner.PreludeEnv.replace(env, namespace, source, opts \\ [])
PtcRunner.PreludeEnv.compile_bundle(env)
```

Successful replacement returns the updated env plus a structured change
summary:

```elixir
{:ok, updated_env,
 %{
   namespace: "paged",
   candidate: %PtcRunner.PreludeCandidate{},  # the staged candidate to promote
   old_checksum: "<old source_hash>",
   new_checksum: "<new source_hash>",
   draft_id: "draft-...",
   exports_added: ["inspect"],
   exports_removed: [],
   exports_changed: ["profile"]
 }}
```

Compile failure keeps the old env:

```elixir
{:error,
 %{
   reason: :prelude_compile_error,
   namespace: "paged",
   message: "...",
   old_checksum: "<old source_hash>"
 }}
```

## Session API

`PtcRunner.Session` should be the embedding-friendly stateful surface. It can
store a `PreludeEnv` or a compiled prelude snapshot derived from it. Worker
sessions should normally freeze the selected prelude bundle for the session's
lifetime. Replacement is for scratch/experiment sessions and verification
harnesses, not for ordinary mission self-mutation.

Candidate API:

```elixir
session =
  PtcRunner.Session.new(
    prelude_env: prelude_env,
    tools: tools,
    upstream_runtime: runtime
  )

{:ok, preludes} = PtcRunner.Session.preludes(session)
{:ok, source} = PtcRunner.Session.prelude_source(session, "paged")

{:ok, session, update} =
  PtcRunner.Session.replace_prelude(session, "paged", new_source)

{{:ok, step}, session} =
  PtcRunner.Session.eval(session, "(paged/profile ...)")
```

The session-local replacement is for experiments and verification. It should
not imply persistence to disk or a shared store. A later eval must still attach
the current compiled bundle against that session's own tools/runtime grants, so
an editing agent cannot launder its broader grants into a worker session.

## SubAgent API

SubAgent should accept the same environment and optionally expose
host-controlled prelude editing tools to the model.

Candidate direct use:

```elixir
{:ok, result, updated_env} =
  PtcRunner.SubAgent.run(agent, input,
    prelude_env: prelude_env,
    prelude_tools: [:source, :replace]
  )
```

The tool implementations remain host-owned wrappers over `PreludeEnv`:

```elixir
tools: %{
  "prelude_source" => fn %{"namespace" => ns} ->
    PtcRunner.PreludeEnv.source(env, ns)
  end,
  "prelude_replace" => fn %{"namespace" => ns, "source" => src} ->
    PtcRunner.PreludeEnv.replace(env, ns, src)
  end
}
```

The SubAgent loop should not silently inherit prelude editing capability into
child agents. Hosts opt in per agent/run.

## MCP Server Projection

The MCP server should expose thin wrappers only:

```text
lisp_session_preludes
lisp_session_prelude_source
lisp_session_prelude_replace
```

Each tool should call the core session/prelude APIs. The MCP layer owns only
transport concerns: argument validation, owner checks, envelope shaping,
output limits, and turn-log events for the tool call. It should not compile,
diff, checksum, or persist preludes itself.

## Context Refresh Workflow

Updating a prelude changes the Lisp runtime, not the LLM's already-loaded
context. The near-term workflow should therefore use fresh agents for each
phase:

```text
1. Worker agent
   - Starts a PTC session with current prelude.
   - Attempts the task.
   - Produces turn logs.

2. Analyst agent
   - Reads turn logs plus current prelude source.
   - Suggests or applies a prelude replacement in a session-local env.
   - Runs focused tests if allowed.

3. Verifier agent
   - Starts a fresh PTC session with the updated prelude.
   - Runs the same task.
   - Compares correctness, turns, cost, tool calls, and source/doc usage.

4. Promotion step
   - Human or host policy decides whether to persist the improved prelude.
```

This can be simulated today with Claude Code/Codex subprocesses and files:

```bash
claude -p "$TASK" --mcp-config current.json > run-1.jsonl
claude -p "$ANALYZE_LOGS_AND_PATCH" > patch-1.jsonl
mix test ...
claude -p "$TASK" --mcp-config updated.json > run-2.jsonl
```

Later, `PreludeEnv.replace/4` removes the need to restart the MCP server and
makes in-process A/B possible, but the verifier should still be a fresh model
context unless the host explicitly injects a compact prelude-change card.

## Persistence Direction

Do not implement database/upstream persistence in V1, but keep the API
storage-agnostic.

Possible future store behaviour:

```elixir
PtcRunner.PreludeStore.list(store)
PtcRunner.PreludeStore.get(store, id)
PtcRunner.PreludeStore.put(store, candidate)  # promotes; returns a versioned store record
PtcRunner.PreludeStore.history(store, id)
```

Candidate stores:

```text
PtcRunner.PreludeStore.Memory
PtcRunner.PreludeStore.FileSystem
PtcRunner.PreludeStore.Upstream
```

Runtime replacement and persistence stay separate:

```elixir
{:ok, env, update} = PtcRunner.PreludeEnv.replace(env, "paged", source)
{:ok, record} = PtcRunner.PreludeStore.put(store, update.candidate)
# record carries the store-assigned version; the compiled %Prelude{} never
# mints or carries store version identity.
```

The store assigns `version` during `put/promote`; session-local candidates
remain unversioned and are keyed by checksum/draft id. This avoids two scratch
sessions both producing a misleading local `"version 8"`.

Every turn log should record the prelude artifact identity used for the run:

```json
{
  "namespace": "paged",
  "checksum": "<bare-hex source_hash>",
  "origin": "file:examples/paged_data_prelude/paged_data.clj",
  "version": 7,
  "draft_id": null
}
```

This lets future log analysis answer which prelude produced which behavior.
The existing turn-log provenance already records namespaces and `source_hash`;
adding origin/version/draft id to that existing provenance field is a cheap
near-term improvement and does not require `PreludeEnv`.

## Phases

### E1. Documented Manual Loop

- Keep using file edits and fresh Claude/Codex runs.
- Record traces before and after each prelude improvement.
- Compare turn count, cost, correctness, and whether the model used public
  docs instead of private source.
- Pull forward the cheap provenance improvement: extend existing turn-log
  prelude provenance beyond namespaces + `source_hash` when the host knows
  origin/version/draft id.

### E2. Core PreludeEnv

- Add candidate/source/provenance data structures that wrap existing compiled
  `%PtcRunner.Lisp.Prelude{}`.
- Add `PreludeEnv.stage/source/list/replace/compile_bundle` (compile/provenance
  only; no `attach` — authority binding stays in `Prelude.Attach.attach/2`).
- Compile replacement atomically through the existing compiler.
- Add tests for successful replacement, compile failure preserving old env,
  checksum/provenance changes, and export diff summaries.
- Reuse compiler export metadata for export diffs; host/MCP code should not
  re-parse source to compute diffs.

### E3. Session Integration

- Let `PtcRunner.Session` carry a `PreludeEnv`.
- Add session-local `preludes/source/replace` functions.
- Ensure `eval/3` uses the current compiled environment.
- Re-run attach-time fail-closed `requires` validation against the consuming
  session's grants on every attach/eval.
- Emit turn-log provenance for the active prelude candidates/artifacts.

### E4. SubAgent Integration

- Let SubAgent accept `prelude_env`.
- Add opt-in host tools for `prelude_source` and `prelude_replace`.
- Return the updated env or a structured update log from the run.
- Prevent implicit inheritance of prelude mutation authority into child
  SubAgents.

### E5. MCP Projection

- Add `lisp_session_preludes`, `lisp_session_prelude_source`, and
  `lisp_session_prelude_replace`.
- Route them to core session APIs.
- Keep MCP-specific code limited to validation, ownership, envelopes, and
  output limits.

### E6. Stores and Promotion

- Add store behaviour only after session-local replacement has proven useful.
- Start with filesystem or memory-backed persistence.
- Keep promotion explicit and reviewable.
- Assign monotonic versions only in the store/promotion layer.

## Open Questions

- Should replacement be namespace-scoped only, or should an env support
  multi-namespace bundles that replace atomically?
- How much of the prelude doc/discovery card should be returned by
  `session_start` after a replacement?
- Should SubAgent expose prelude-editing tools as ordinary tools, a special
  control channel, or both?
- What policy decides that a tested prelude improvement is promotable?
