# Declared Prelude-to-Prelude Dependencies — Implementation Plan

## Status

**Implemented** 2026-07-03 (all four phases; see the `feat(prelude)`,
`feat(store)`, `feat(attach)`, and `feat(mcp)` commits landing compiler
dep-scoped compilation, store pins + retention, attach closure expansion,
and seed-order resolution). The keystone integration test
(`test/ptc_runner/sub_agent/prelude_deps_integration_test.exs`) proves the
runtime model end-to-end through all three attach entry points. One planned
behavior change: duplicate identical session refs now deduplicate to one
component instead of raising (decision 4).

Approved design derived from the investigation
in the external repo `ptc-bench-comparison`
(`notes/prelude-deps-options-2026-07-03.md`, commits `f6be0cd`..`a859aeb`),
which evaluated five options against source-verified experiments at
ptc_runner `7f621a90` and selected **Option 1: dependency-scoped
compilation, pinned at write**, with the write-op declaration surface.
All file:line anchors below verified at `7f621a90`.

## Problem

A prelude cannot reference another prelude's exports. `(base/helper x)`
inside prelude `audit` fails at write time with `unknown namespace base/`,
and the attach-time bundle compile (concatenated sources) fails
identically — the blocker is the compiler's analysis pass, not store
policy. Today's multi-attach works only because attached preludes never
reference each other. This blocks the composable-capability-library North
Star: shared helpers must currently be copy-pasted into every prelude.

The resolution machinery already exists and is proven daily: qualified
calls from user session code resolve through
`PtcRunner.Lisp.Analyze.PreludeScope` against the public export table with
precise arity errors and a discovery hint for non-exports
(`lib/ptc_runner/lisp/analyze.ex:300,569`). The gap is that
`Compiler.compile/1`'s internal analysis passes `prelude = nil`
(`lib/ptc_runner/lisp/prelude/compiler.ex:1408`, and `build_runtime`'s
per-namespace analyze at `compiler.ex:1191`), overwriting any installed
scope. This is a missing parameter thread, not a missing mechanism.

## Design summary

- `prelude/write` (and `prelude/edit`) accept a declared dependency list.
  Write resolves each dep from the store, compiles the candidate with the
  deps' export tables installed as analysis scope, and records resolved
  pins `{id, version, checksum}` in candidate metadata.
- Attach (`Selection.resolve!`) expands the transitive pin closure,
  topologically orders components, and compiles the aggregate with
  per-namespace dependency scope.
- A dep must exist in the store before a dependent can be written, and
  pins are immutable versions, so the dependency graph is **acyclic by
  construction** — no cycle detection needed.
- `defn-` privates have no export record, so cross-prelude calls to them
  are unreachable by construction — the correct library boundary, for free.

### Decisions (settled — do not reopen during implementation)

1. **Pinned at write, not float-at-attach.** A bare-id declaration
   resolves to the current version at write time and is stored as an
   explicit pin. Upgrading `base` does not affect `audit` until `audit` is
   rewritten/rebased (deliberate; a `prelude/rebase` op is v2).
2. **Declaration surface: write-op argument** (`requires_preludes`, a
   vector of strings `"id"` or `"id@<version>"`). In-source
   `(ns audit (:require [base]))` is the durable v2 direction. Never both
   as simultaneous sources of truth.
3. **`def`-position dep references are REJECTED fail-closed.** Top-level
   `(def x <expr>)` initializers evaluate at prelude compile time in a
   bare context with a **no-op tool executor**
   (`compiler.ex:1421-1432`) — a dep call there would compute garbage
   silently. v1 rejects any dep-namespace reference (call or value
   position) inside a `def` value form with a clear `ValidationError`.
   `defn` bodies cover composition.
4. **Version conflicts fail closed.** One session needing `base@2` and
   `base@3` (directly or transitively) is an attach error naming both
   requirers. Same id + same version deduplicates to one component.
5. **Undeclared cross-namespace references stay errors.** A qualified ref
   into a namespace that exists in the store but is NOT declared in
   `requires_preludes` fails at write exactly as today (unknown
   namespace), with the error message extended to hint at
   `requires_preludes`. Declarations are the only path to visibility.
6. **The fold lives INSIDE `Compiler.compile`, not in Bundle.** A
   bundle-level fold over separately compiled components would need a
   `Prelude.merge` across exports, per-namespace `private_env`,
   `source_index`, `form_graph`, and metadata — five structures to merge
   wrongly. Instead the ONE aggregate compile processes namespaces in
   dependency order with progressively accumulated scope.
7. **Direct source attach keeps today's behavior.** `Attach.attach/2`'s
   source-binary clause (`attach.ex:104`) and raw selection-list clause
   (`attach.ex:110`) carry no dep metadata; cross-namespace refs there
   keep failing closed. Only store-resolved attach supports deps in v1.

## Runtime model (source-verified; no eval changes)

Function/value-position dep calls need **no evaluator changes**. Analysis
with a dep scope emits `{:prelude_call, ref, args}` (call position) or
`{:prelude_ref, ref}` (value position, `analyze.ex:300-305`). Both are
dormant during `build_runtime`'s closure capture and resolve
**dynamically at session runtime** against `eval_ctx.prelude_exports` —
the attached bundle's full export table (`lib/ptc_runner/lisp/eval.ex:816-838`
and `800-808`). `invoke_prelude_export` derives the export's context from
the caller's, replacing only `user_ns` (`eval.ex:926-934`), so
`prelude_exports` flows into nested frames. The private-tool guard
authorizes against the **current frame's** origin `tool_refs`
(`lib/ptc_runner/lisp.ex:1643-1659`): when `base/helper` runs, its own
origin is on top, so runtime tool authorization composes across
namespaces with no union needed at that layer.

## The fail-open hazard (must land atomically with scope threading)

`:ns_symbol` is in the raw-AST walkers' `@leaf_tags`
(`compiler.ex:1011`), so the form-graph collectors silently skip
qualified refs today. Once dep-scope threading makes analysis pass, a
dependent's export would compile with `requires`/`tool_refs` that OMIT
everything reached through the dep — the #1095 fail-open authority
pattern. The runtime per-frame guard is unaffected; the holes are the
pre-execution surfaces (`collect_prelude_tool_refs`, `lisp.ex:1255`) and
capability grants.

**Hard rule: Phase 1 must ship the dep-ref collector and the
requires/tool_refs union in the SAME change as the scope threading.**
A commit that threads scope without the collector is a security
regression and must not exist, even transiently.

## Phases

Each phase lands green (`mix precommit`) and gets a `codex review` round
before the next starts. Phases 1→2→3 are strictly ordered; Phase 4 can
overlap Phase 3.

### Phase 1 — Compiler: dependency-scoped compilation

All in `lib/ptc_runner/lisp/prelude/compiler.ex` unless noted.

1. **API**: `Compiler.compile(source)` →
   `Compiler.compile(source, opts \\ [])` with:
   - `deps: [%Prelude{}]` — compiled dep artifacts whose PUBLIC exports
     form the external analysis scope (write path).
   - `namespace_deps: %{namespace => [dep_namespace]}` — per-namespace
     declared deps, used both to order the aggregate compile (attach
     path) and to gate which namespaces a given namespace may reference.
   Update the other production callers to pass no opts (behavior
   unchanged): `attach.ex:105`, `bundle.ex:73,86`,
   `prelude_store.ex:361`, `prelude_store/tools.ex:152`,
   `mix/tasks/ptc.repl.ex:160,192`, and in `mcp_server/`:
   `application.ex:701`, `sessions/config.ex:397`.
2. **Scope construction**: a synthetic scope prelude is trivial —
   `Prelude.fetch_export/2` is a linear scan over an exports list
   (`lib/ptc_runner/lisp/prelude.ex:125-130`), so scope for namespace N =
   `%Prelude{namespaces: allowed_ns, exports: allowed_exports}` where
   allowed = N's declared deps (external `deps` artifacts ∪
   already-compiled sibling namespaces of this compile). The scope for N
   **excludes N itself**, preserving the `qualified_self_reference`
   rejection (`compiler.ex:359-372`, which runs on the raw AST at spec
   collection and is scope-independent anyway).
3. **Ordering**: topologically sort the namespace groups in
   `build_exports` and `build_runtime` (both currently iterate
   `Enum.group_by(& &1.namespace)` unordered — `compiler.ex:1185-1199`
   for build_runtime) by `namespace_deps`. Unknown dep namespace in the
   map, or a namespace referencing an undeclared one → `ValidationError`.
   A cycle "cannot happen" (acyclic by construction) but the sort must
   still fail closed on one rather than loop.
4. **Scope threading**: install the per-namespace scope via
   `Analyze.analyze(program, scope_prelude)` at `build_runtime`'s analyze
   call (`compiler.ex:1191`) and the top-level analyze
   (`compiler.ex:1408`). `PreludeScope` is process-local with
   save/restore (`analyze/prelude_scope.ex:39-51`); nesting is safe.
5. **Dep-ref collector** (the fail-open fix): extend
   `namespace_form_graph` (`compiler.ex:645-693`) with a raw-AST
   collector for qualified refs into DECLARED dep namespaces — call-head
   AND value position (`(map base/helper xs)` counts). Follow the
   container-set discipline from #1095: the walker must cover
   `:list/:vector/:map/:set/:short_fn` and treat reader-macro leaves per
   `@leaf_tags`; model it on `collect_tool_names_raw`
   (`compiler.ex:699-725`). Store per-symbol `dep_calls`
   (direct/transitive, like `requires`/`tool_refs`).
6. **Requires/tool_refs union**: in `build_exports`
   (`compiler.ex:492-519`), union each referenced dep export's stored
   `requires` and `tool_refs` into the dependent export's transitive
   sets. Dep export records come from the scope (external artifacts or
   earlier-compiled siblings, available thanks to ordering). Pins make
   the union stable.
7. **`def`-position rejection**: for each constant spec (`params_form:
   nil`), walk the value form for dep-namespace refs (same walker
   discipline; reuse the `self_ref` shape at `compiler.ex:374-386`) and
   reject with a new `ValidationError` reason `:dep_ref_in_def` and a
   message telling the author to use `defn`.
8. **Error taxonomy**: add `:unknown_dependency`, `:dep_ref_in_def`,
   `:dependency_cycle` to
   `lib/ptc_runner/lisp/prelude/validation_error.ex`; extend the
   unknown-namespace analysis error with the `requires_preludes` hint.

Tests (extend `test/ptc_runner/lisp/prelude/compiler_test.exs`):
cross-namespace call resolves with scope; wrong arity and non-export
rejected with today's precise messages; undeclared namespace rejected;
value-position ref unions requires; transitive union through a dep's own
private helpers; def-position rejection; topological compile of an
aggregate in both source orders; `@leaf_tags` walker coverage for the new
collector (mirror the existing `leaf_node?` gate tests).

### Phase 2 — Store: declared deps, pins, retention

All in `lib/ptc_runner/prelude_store.ex`,
`lib/ptc_runner/prelude_store/server.ex`,
`lib/ptc_runner/prelude_candidate.ex`.

1. **Declaration intake**: `write/4` reads the declared list from
   metadata key `"requires_preludes"` (vector of `"id"` / `"id@<v>"`
   strings), following the `parent_checksum` precedent of
   metadata-carried protocol keys (`prelude_store.ex:120,325-337`).
2. **Resolution at write**: each ref resolves through the existing read
   path (bare id → current version; explicit version → that version;
   missing → `:unknown_dependency` error naming the ref). The dep
   candidates' compiled artifacts feed `Compiler.compile(source, deps:
   ...)` inside `compile_bounded` (`prelude_store.ex:122,360-389`).
   `validate_compiled_namespace` (`:465-481`) is untouched — dep scope
   adds no namespaces. Since store policy guarantees namespaces == [id],
   dep namespace == dep id everywhere.
3. **Pins**: the store COMPUTES resolved pins
   `[%{"id" => _, "version" => _, "checksum" => _}]` and writes them to
   candidate metadata under `"prelude_deps"`, overriding any
   caller-supplied value for that reserved key (metadata is untrusted).
   Add `prelude_deps` to `@public_metadata_keys`
   (`prelude_candidate.ex:16`) so pins appear in write echoes and
   `prelude/read`/`list` projections.
4. **Prune retention**: superseded versions are pruned beyond
   `:max_versions` with only `set_default`-pinned versions retained
   (`server.ex:299-326,390-392`). Register dep pins in the same
   `pinned_versions` set when a dependent version is appended, so a
   pinned dep version cannot be pruned away. (Pruning of the DEPENDENT
   releases nothing in v1 — acceptable growth; revisit with refcounts
   only if real stores hit the bound.)
5. **`edit/4` inheritance**: edit routes through `write/4`
   (`prelude_store.ex:180`); it must copy the base version's
   `"requires_preludes"` declaration into `write_metadata` when the
   caller did not supply one (explicit supply overrides — including `[]`
   to drop deps). Pins re-resolve from the declaration at the edit's
   write; carrying the base's pins forward unchanged is correct because
   bare-id declarations re-resolving to a NEWER current version would be
   float-at-attach through the back door — so: **edit inherits the
   base's resolved pins (id@version), not the raw declaration**, unless
   the caller supplies a new declaration.
6. **Ops surface** (`lib/ptc_runner/prelude_store/tools.ex`): extend the
   `prelude/write` Lisp op (`tools.ex:106-114`) and `prelude/edit`
   (`:116-125`) to read a `"requires_preludes"` key from the candidate
   map and pass it through metadata; extend `write_tool`
   (`:509-528`) / `edit_tool` (`:530-549`) matches accordingly. Keys are
   hyphen-free strings per the existing normalizer convention. Note the
   existing `prelude/deps` op is FORM-level introspection — docs must
   distinguish "prelude dependencies (pins)" from "form dependencies".

Tests (extend `test/ptc_runner/prelude_store_test.exs`,
`test/ptc_runner/prelude_store_tools_test.exs`): write with deps
succeeds and echoes pins; unknown dep fails with `:unknown_dependency`;
bare id pins the then-current version; explicit `id@v` pins that
version; caller-supplied `"prelude_deps"` metadata is ignored/overridden;
pruning retains dep-pinned versions (extend the pruning describe);
edit inherits pins, explicit override works, `[]` drops; `prelude/write`
op end-to-end through the Lisp surface.

### Phase 3 — Attach: transitive closure, ordering, conflicts

1. **`Selection.resolve!`**
   (`lib/ptc_runner/prelude_store/selection.ex:21-41`): after
   `read_candidate!`, expand the transitive closure from each
   candidate's `"prelude_deps"` pins — read dep candidates by
   `%{id, version, checksum}` (checksum verified by the existing read
   path), recurse. Dedup by id: identical version → one component;
   differing versions → raise with an error naming the conflicting
   requirers and both versions (decision 4). A pinned dep missing from
   the store (pre-retention data, or cross-store misuse) → a precise
   fail-closed error, not `unknown namespace` later.
2. **Ordering + compile opts**: topologically order components (deps
   before dependents; preserve user selection order among independents
   for provenance), derive `namespace_deps` from the pins (id ==
   namespace), and pass through `Bundle.compile_precompiled/1` →
   `compile_components` (`bundle.ex:70-80`) → `Compiler.compile(source,
   namespace_deps: ...)`. `Bundle.compile/1`'s per-component validation
   compiles (`bundle.ex:86`) stay dep-blind (they serve the raw
   selection-list path, which does not support deps — decision 7).
3. **Refs transparency**: the resolved refs list returned by
   `resolve!/3` (and frozen into `Session.preludes` /
   `lisp_session_list_preludes`) includes auto-pulled deps, marked
   (e.g. `required_by: [ids]`), so a session can see exactly what got
   attached and why.
4. **Requires validation**: no new surface — the unioned export
   `requires` flow through the existing
   `PreludeAttach.validate_requires/2` (`attach.ex:131-…`) at the single
   attach seam all three execution paths converge on
   (`lisp.ex:407,474-489`).

Tests: extend `test/ptc_runner/lisp/prelude/bundle_test.exs` and store
tests for closure expansion, ordering (write base+audit, attach
`["audit"]`, observe base auto-pulled), version-conflict rejection,
missing-pin error. **The keystone integration test** (the investigation's
former "runtime spike", now the first end-to-end proof): store `base`
(tool-backed helper) and `audit` (declares base, `defn` calls
`base/helper`, plus a value-position `(map base/helper …)` and an export
returning a closure that calls `base/helper`); attach `["audit"]` via a
Session; run user code calling `audit/check`; assert correct result,
single ledger entry attributed through the nested origin, unioned
`requires`/`tool_refs` visible pre-execution, and `defn-` privates of
`base` unreachable from `audit` and from user code. Repeat attach through
all three entry points (`session.ex:101`, `sub_agent.ex:375`,
`definition.ex:291`) — the seam is shared but each caller's opts plumbing
is not.

### Phase 4 — Surface polish (can overlap Phase 3)

1. **MCP seeding** (`mcp_server/lib/ptc_runner_mcp/application.ex:643-671`):
   seeding writes `.clj` files via `PreludeStore.write/4`; with deps this
   is order-sensitive. Simplest robust fix: collect failures with
   `:unknown_dependency` and retry them after the pass; no progress →
   error listing the stuck files. (Seed-file dep declarations ride in a
   sidecar metadata convention — decide the exact form when touching the
   seeder; do not invent an in-source surface for it.)
2. **Docs** (fix together with code, per repo rules):
   `docs/guides/` prelude guide (dependency authoring section: declare →
   pin → attach closure; def-position rule; privates are not importable),
   `docs/function-reference.md` (`prelude/write`/`edit`
   `requires_preludes` arg, pins echo), and the `prelude/*` op docstrings
   in `tools.ex` (`@prelude_source` is code, not a priv/prompts
   template — no prompt recompile concern, but keep op docs domain-blind
   per repo prompt rules).
3. **Introspection nicety (optional, cut first if squeezed)**: surface
   per-form `dep_calls` in `prelude/form-deps` output so form-level
   introspection shows cross-prelude edges.

## Out of scope (v2+)

- In-source `(ns audit (:require [base]))` declaration surface (makes the
  aggregate compile self-describing; composes with form-keyed edits).
- `prelude/rebase` (re-pin a dependent to a dep's newer version).
- Float-at-attach as an opt-in mode.
- Dep-pin refcounting/GC for dependent pruning.
- `def`-position dep references (rejected fail-closed in v1; revisit only
  with a concrete use case).

## Implementation notes for subagents

- **Never split Phase 1 items 4-6 across commits** (fail-open window).
- Walker discipline: any new raw-AST walker must handle
  `:list/:vector/:map/:set/:short_fn` containers and only the
  `@leaf_tags` leaves; everything else falls to `leaf_or_reject`
  (`compiler.ex:1033-1039`). Short-fn bodies are implicit applications.
- `PreludeScope` is process-local (`analyze/prelude_scope.ex`); install
  scope with `with_prelude/2` around the analyze call, never by mutating
  broader state. Analysis runs inside the bounded sandbox process during
  store writes (`compile_bounded`), which is fine — the scope travels
  with the closure executed in that process.
- Do not touch `@leaf_tags`, `reject_qualified_self_refs`, or
  `validate_compiled_namespace` semantics.
- Timestamps `:utc_datetime`; no `Process.sleep` in tests; bug-fix tests
  reproduce first; run `mix precommit` before every commit and re-run
  any tool after fixing its finding.
- Verification gate per phase: `mix precommit`, then targeted suites
  (`compiler_test.exs`, `prelude_store_test.exs`,
  `prelude_store_tools_test.exs`, `bundle_test.exs`, the new integration
  test), then a `codex review` round; stop on first clean round.
