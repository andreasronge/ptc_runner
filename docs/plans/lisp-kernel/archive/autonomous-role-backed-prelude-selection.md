# Lisp Kernel - Autonomous Role-Backed Prelude Selection Plan

**Status:** closeout/hardening pass in progress on `exp/lisp-kernel`;
updated 2026-07-09 after role-backed PreludeStore selection, D4 kernel
TurnEvents, and deterministic parity/regression coverage. The core
resolver/runtime path exists and closeout now depends on review plus the normal
quality gate.

This plan is not an A/B run and not a live benchmark. It replaces the kernel's
hardcoded `priv/preludes/agent/*.lisp` selection path with a role-resolved
PreludeStore path, while keeping today's embedded defaults as the no-policy
bootstrap source. The goal is one concept for future configuration: **role
decides authority and allowed prelude surface; the run requests a selected
surface within that role, or uses the role's default selection**.

## Current Implementation Audit

Already present:

- `PtcRunner.PreludeRolePolicy.from_map/1` parses the kernel-owned role subset
  without creating atoms from untrusted strings.
- `PtcRunner.PreludeRolePolicy.resolve/2` applies default-role lookup and stable
  grant fingerprinting.
- `PtcRunner.PreludeRolePolicy.selected_refs/2` keeps `preludes` as an
  allowlist and uses `default_preludes` only when the run omits a request.
- `PtcRunner.PreludeRuntime.resolve/3` delegates selected refs and dependency
  closure to `PreludeStore.Selection.resolve!/3`.
- `PtcRunner.Kernel.compile_prelude/1` enters role-backed mode only when
  `:role_policy` is supplied; otherwise it uses the embedded `agent.*` bundle.
- `PtcRunner.Kernel.run/2` records source-free
  `prelude.metadata[:role_prelude_selection]` and D4 TurnEvents consume it.
- `PreludeStore.write/5` accepts a validated per-write `origin:` option while
  preserving the existing store-level origin default.
- Deterministic tests cover basic role parsing, unknown MCP-only keys,
  default-prelude allowlist failures, duplicate grants, atom-key parsing,
  invalid default/role names, invalid requested `preludes:` type,
  checksum-pinned requested refs, role-backed kernel execution, explicit
  requested refs overriding `default_preludes`, missing store, unknown role, no
  selected preludes, source-free provenance, stale-core `turn` fail-closed
  behavior, per-write origin validation, embedded-vs-role bundle parity, and D4
  TurnEvent correlation shape for embedded and role-backed runs.

Known gaps before D20 should be called resolved:

- None for the kernel substrate. MCP adapter unification, external loaders, and
  role-owned presentation extensions remain future work.

## Short Goal Prompt

```text
Run the autonomous Role-Backed Prelude Selection plan described in
docs/plans/lisp-kernel/autonomous-role-backed-prelude-selection.md.

Goal: make PtcRunner.Kernel.run/2 able to resolve its agent preludes through a
PreludeStore plus a role grant, reusing the semantics already implemented for
MCP session roles where practical. Do not introduce a separate "profile" layer.
Do not let Lisp load files, HTTP, or databases. Source loading remains a host
adapter concern that writes candidates into PreludeStore; runtime selection
uses role -> allowed refs -> requested/default refs -> dependency closure ->
compiled bundle.

Keep the change narrow: deterministic tests only, no live model claims, no
MCP server dependency from core ptc_runner, and no new prompt/domain hints.
```

## Objective

Today `PtcRunner.Kernel.compile_prelude/1` embeds and compiles exactly three
files:

- `agent.prompt`
- `agent.feedback`
- `agent.core`

That was the right M2/M3 spike shape, but it is now the wrong long-term
configuration boundary. The repo already has a `PreludeStore`, dependency pins
through `requires_preludes`, and an MCP session role policy that decides:

- which prelude refs a role may request;
- whether the role has no/read/write prelude-store authority;
- which host PTC tools and upstream tools are granted;
- which selected prelude exports are filtered from model-facing discovery;
- which session modes are allowed.

The kernel should reuse that model. A kernel run should be able to say:

```elixir
PtcRunner.Kernel.run(mission,
  prelude_store: store,
  role_policy: policy,
  role: "kernel_default",
  preludes: ["agent.core@1"]
)
```

and have the role check the requested refs against its allowlist. If
`preludes:` is omitted, the kernel uses the role's `default_preludes`.
Later, the same role can decide whether the model may inspect or update store
candidates through curated prelude-store tools. Loading prelude source from
filesystem, HTTP, database, or upstream MCP remains host-side and happens
before runtime by writing into `PreludeStore`.

## Fit With Existing Plans

This plan is a bridge, not a replacement:

- **M2/M3 kernel plans.** M2 proved policy can live in `agent.*` preludes. S19
  proved bundle provenance can attribute a feedback-only swap. This plan keeps
  that evidence intact by compiling the same bundle shape, but resolves the
  component list from a role instead of hardcoded module attributes.
- **D19 / symbol inventory.** Symbol inventory remains the model-visible
  renderer for selected data/tools/memory/prelude exports. Role resolution
  decides which prelude exports exist after grant filtering; the inventory
  renders only that resolved, sanitized surface.
- **MCP role policy.** `PtcRunnerMcp.Sessions.Policy` is the reference
  implementation, but core `ptc_runner` must not depend on the MCP app. The
  durable semantics should move or be mirrored into a library-owned module, and
  MCP should become an adapter over it.
- **Prelude dependencies.** `PreludeStore.Selection` and `requires_preludes`
  remain the dependency mechanism. A run selects direct refs permitted by the
  role; dependency closure is resolved by the store and recorded in provenance.
- **Experiment platform affordances.** This is the non-MCP kernel counterpart
  to role-scoped credentials and profile-like experiment setup. It should make
  future experiments choose a role rather than editing Elixir or naming local
  files.
- **Federated/external stores.** This plan does not implement HTTP/database
  loading. It preserves the future path by making runtime selection depend only
  on store ids, versions, checksums, and origins, never file paths.

## Non-Goals

- No live A/B or conclusion-bearing run.
- No new model-visible domain hints.
- No Lisp API that loads source from filesystem, HTTP, database, or upstream
  MCP.
- No dependency from `lib/ptc_runner` to `mcp_server`.
- No broad rewrite of MCP roles, HTTP admin endpoints, or session lifecycle.
- No source-discovery policy change for `agent.*` implementation source.
- No compatibility shim for the old hardcoded path beyond retaining it as the
  default seed/bootstrap path during the experiment.

## Schema Ownership

The shared core schema is only the subset every participating surface can
enforce:

- role name and fingerprint;
- `preludes` as an allowlist of exact refs;
- `default_preludes` as the role's default requested refs for non-interactive
  kernel runs;
- `prelude_store_access` as no/read/write authority for future curated store
  tools.

Every other key belongs to the surface that enforces it. A key with no
enforcement point on a surface must be rejected there, not silently ignored.
For this plan, MCP-only grant keys such as `ptc_tools`, `upstream_tools`,
`modes`, and `strict_transitive_calls` remain out of the kernel role shape
unless the implementation also adds a concrete kernel enforcement point.

Presentation policy remains a run-level kernel option for now. In particular,
`symbol_inventory_renderer` must not be added to the shared role grant in this
plan; `Kernel.run/2` already accepts `:symbol_inventory_renderer` and validates
it fail-closed. Any future presentation section must be an explicitly owned,
namespaced extension with a documented cross-surface parsing rule.

## Proposed Role Shape

Start with the MCP grant vocabulary that is already tested, but keep the core
shape transport-neutral and limited to keys the kernel can enforce:

```json
{
  "default_role": "kernel_default",
  "roles": {
    "kernel_default": {
      "prelude_store_access": "none",
      "preludes": ["agent.prompt@1", "agent.feedback@1", "agent.core@1"],
      "default_preludes": ["agent.core@1"]
    },
    "kernel_editor": {
      "prelude_store_access": "write",
      "preludes": ["agent.prompt@1", "agent.feedback@1", "agent.core@1"],
      "default_preludes": ["agent.core@1"]
    }
  }
}
```

Important distinction:

- `prelude_store_access` is authority for inspecting/updating the store.
- `preludes` is an allowlist of exact refs, matching MCP role semantics.
- `default_preludes` is the default selected runtime surface when a
  non-interactive kernel run omits `preludes:`.
- `Kernel.run(..., preludes: refs)` is the requested runtime surface and must
  be checked against the role allowlist.
- `requires_preludes` remains per-prelude dependency metadata.

Do not collapse these concepts. A run may request `agent.core`, which pulls
`agent.prompt` and `agent.feedback` as dependencies; that is different from a
role being allowed to directly request or edit those dependencies.

## Implementation Notes

The core implementation copies the MCP role semantics that the kernel can
enforce without depending on `ptc_runner_mcp`: role-name validation, exact
`id@version` prelude grants, role default selection, requested-ref allowlist
checks, no/read/write prelude-store authority as data, and a stable grant
fingerprint over normalized grant data. Runtime selection then delegates the
dependency closure and bundle compilation to `PtcRunner.PreludeStore.Selection`.

MCP-only semantics remain MCP-owned: session modes, PTC tool grants, upstream
tool grants, credentials, strict transitive session calls, outer MCP tool
filtering, HTTP/file/env role parsing, and prelude export projection based on
tool/upstream grants. The kernel rejects those keys in its shared role shape
because it has no enforcement point for them in this plan. Presentation policy
also remains run-level (`:symbol_inventory_renderer`) rather than a role key.

Core JSON-style map parsing is owned by `PtcRunner.PreludeRolePolicy.from_map/1`.
The module accepts string or existing atom keys without creating atoms from
untrusted strings. The no-policy default remains the embedded agent prelude
bundle; role-backed selection is entered only when a caller supplies an explicit
`:role_policy`, so generic forwarded `:role` or `:preludes` options do not
accidentally replace the embedded kernel prelude. Loading source from files,
HTTP, databases, or MCP is still outside runtime selection; hosts seed
candidates into `PreludeStore` before calling the kernel.

## Closeout Checklist

Work risk-first. Do not broaden into MCP refactors, store editor tools, live
model runs, or presentation-policy design.

### Phase A - Equivalence Harness

Status: implemented in `test/ptc_runner/kernel_test.exs`.

Add a helper in `test/ptc_runner/kernel_test.exs` or a focused
`kernel/role_prelude_selection_test.exs` that builds both paths from the same
committed source:

1. Embedded path: `Kernel.compile_prelude/1` with no `:role_policy`.
2. Store path: seed `agent.prompt`, `agent.feedback`, and current `agent.core`
   into `PreludeStore`; write `agent.core` with
   `requires_preludes: ["agent.prompt@1", "agent.feedback@1"]`; pass
   `origin: {:file, "priv/preludes/agent/<name>.lisp"}` for each seeded
   component when asserting full component equality. Run `Kernel.compile_prelude/1`
   with `prelude_store:`, `role_policy:`, and `role: "kernel_default"`.

Assert:

- `Prelude.trace_summary/1` top-level `source_hash` and `artifact_hash` match,
  and component ids, versions, checksums, source hashes, namespaces, and origins
  match between embedded and role-selected paths. If a test intentionally seeds
  store candidates with non-file origins, compare only ids, versions, checksums,
  source hashes, and namespaces, and separately assert the projected origins are
  bounded and source-free;
- the selected path's `role_prelude_selection` contains exactly `role`,
  `grant_fingerprint`, `prelude_store_access`, `selected_refs`, and
  `resolved_refs` (no renderer, source, form graph, prompt text, or raw
  metadata);
- `Kernel.run/2` returns the same mock value for both paths;
- a `TraceLog.MemorySink` around both runs shows the same D4 correlation shape:
  first success has `attempt: 1`, `turn: 1`, same program, same prelude
  components. `role` and `grant_fingerprint` keys exist in both TurnEvents;
  assert nil values for the embedded run and populated values for the
  role-selected run.

This is the proving test for "role-selected bundle behaves like embedded
bundle" and should fail before any D20 closeout claim if the seeded sources or
metadata drift.

### Phase B - Parser and Config-Space Closure

Status: implemented in `test/ptc_runner/prelude_role_policy_test.exs` and
`test/ptc_runner/kernel_test.exs`.

Extend `test/ptc_runner/prelude_role_policy_test.exs` with focused cases for:

- atom keys and string keys both parse without creating new atoms;
- invalid `default_role` and unknown requested role fail closed with stable
  reasons;
- empty roles plus requested role preserves the existing
  `:role_policy_required` behavior;
- invalid role names and invalid prelude ids fail closed;
- invalid `prelude_store_access` fails closed;
- `selected_refs/2` rejects non-list `preludes:` requests;
- requested refs can be checksum-pinned maps, and those pins are preserved in
  `selected_refs`;
- unknown keys at top level and inside grants remain rejected.

Extend kernel tests for:

- missing `:prelude_store` under role-backed mode;
- invalid `:prelude_store`;
- invalid `:role_policy` type;
- unknown role;
- role with `default_preludes: []` fails as `:missing_prelude_selection`;
- explicit `preludes:` request overrides `default_preludes` but is still
  checked against the allowlist;
- checksum mismatch from `PreludeStore.Selection` surfaces before any LLM call.

### Phase C - Store-Origin Boundary Check

Status: covered by `test/ptc_runner/kernel_test.exs` and existing
`test/ptc_runner/prelude_store_test.exs` origin validation coverage.

The per-write origin API already exists. Add only missing coverage if absent:

- origin appears in `resolved_refs` public metadata used by
  `role_prelude_selection`;
- invalid origin options cannot be smuggled through metadata;
- dependency-pinned candidates preserve their own public origins in the
  resolved closure.

Do not build filesystem/HTTP/database adapters in this phase.

### Phase D - Documentation and Registration

Status: in progress; keep this section current with the final verification
commands.

After Phases A-C pass:

- update this plan's status to "implemented";
- update `docs/plans/lisp-kernel/architecture.md` D20 from "Proposed" to
  "Resolved" with the exact test command;
- update `docs/plans/lisp-kernel/roadmap.md` Cross-Cut section to say role
  backed prelude selection is implemented for the kernel substrate, while MCP
  adapter unification and external loaders remain future work;
- add a short note that the kernel core role schema is intentionally not the
  full MCP grant schema: MCP owns tools, modes, credentials, upstream grants,
  and strict-transitive behavior.

### Phase E - Verification and Review Gate

Status: independent Codex review passed with no actionable findings; final
quality gate passed with `mix precommit`.

Run:

```sh
mix test test/ptc_runner/prelude_role_policy_test.exs \
  test/ptc_runner/kernel_test.exs \
  test/ptc_runner/kernel/prelude_split_test.exs \
  test/ptc_runner/prelude_store_test.exs \
  test/ptc_runner/sub_agent/prelude_deps_integration_test.exs \
  test/ptc_runner/trace_log/turn_log_integration_test.exs
```

Then run:

```sh
mix precommit
```

If any closeout change touches `mcp_server/`, also run:

```sh
mix test mcp_server/test/ptc_runner_mcp/sessions_lifecycle_test.exs \
  mcp_server/test/ptc_runner_mcp/http/router_admin_test.exs
```

Required repo-local gate ends at `mix precommit`. If the environment provides
the Codex review skill, also run an independent `codex review` pass over the
D20 closeout diff before committing.

## Historical Implementation Plan

The following phases describe the original implementation path. Most substrate
items in Phases 1-4 have already landed; use the Remaining Closeout Plan above
for the next autonomous session.

### Phase 1 - Research and Boundary Extraction

Read and record facts before editing:

- `lib/ptc_runner/kernel.ex`
- `lib/ptc_runner/prelude_store/selection.ex`
- `lib/ptc_runner/prelude_store.ex`
- `lib/ptc_runner/prelude_candidate.ex`
- `lib/ptc_runner/lisp/prelude/bundle.ex`
- `mcp_server/lib/ptc_runner_mcp/sessions/policy.ex`
- `mcp_server/lib/ptc_runner_mcp/sessions/policy/grant.ex`
- `docs/guides/mcp-prelude-roles.md`

Answer explicitly in the implementation notes:

- Which MCP role semantics are copied/factored into core?
- Which remain MCP-only?
- Which module owns JSON parsing, if any?
- What is the no-policy default?
- Which keys are rejected because the kernel cannot enforce them?

Expected answer: core owns a small role/grant resolver and bundle-selection
contract; MCP may keep transport-specific JSON/file/env parsing or later move
to the shared parser.

### Phase 2 - Core Role Resolver

Add a core module with a narrow API, for example:

```elixir
PtcRunner.PreludeRolePolicy.from_map(map)
PtcRunner.PreludeRolePolicy.resolve(policy, role)
PtcRunner.PreludeRuntime.resolve(store, grant, opts)
```

The exact names may change, but responsibilities must stay separated:

- parse/normalize role grants without creating atoms from untrusted strings;
- validate role names, prelude refs, default selections, and closed-set options;
- compute a stable grant fingerprint from normalized data;
- check that requested refs are allowed by the role, or select
  `default_preludes` when the run supplies no request;
- resolve selected refs through `PreludeStore.Selection`;
- return a compiled `%PtcRunner.Lisp.Prelude{}` plus bounded selection
  metadata.

Validation must fail closed with stable errors for:

- unknown top-level or grant keys;
- invalid role names;
- missing role when policy requires one;
- unknown role;
- invalid prelude refs;
- `default_preludes` not granted by the role's own `preludes` allowlist;
- requested `preludes:` not granted by the role's allowlist;
- missing `:prelude_store` when selected refs are supplied;
- checksum mismatch or missing selected candidate;
- any MCP-only or presentation key in the shared kernel role shape, unless the
  implementation adds a concrete enforcement point for that key.

### Phase 3 - Kernel Integration

Teach `PtcRunner.Kernel.compile_prelude/1` or a helper below it to choose one
of two paths:

1. **Role/store path** when `:prelude_store`, explicit `:role_policy`, and either
   requested `:preludes` or role `default_preludes` are supplied.
2. **Embedded default path** when no role/store is supplied.

The embedded default path should seed or build the same logical component
selection as today. It must remain deterministic and keep the current
`@external_resource` behavior for package/recompile safety.

`PtcRunner.Kernel.run/2` should record role metadata in the existing sanitized
prelude event/report path and in D4 kernel TurnEvents. D4 consuming code now
expects the compiled prelude metadata key
`prelude.metadata[:role_prelude_selection]` to have this bounded host-authored
shape:

- `:role` - accepted role or nil;
- `:grant_fingerprint` - stable normalized grant fingerprint or nil;
- `:selected_refs` - requested refs or role `default_preludes`;
- `:resolved_refs` - resolved dependency closure with public ids, versions,
  checksums, origins, namespaces, and required-by metadata;
- `:prelude_store_access` - the role grant's current store authority.

Do not include source text, prompt wording, raw mission context, raw memory, or
private tool closures in this metadata. Renderer choice remains run-level
presentation policy in this plan; do not add `symbol_inventory_renderer` to the
shared role grant. If kernel reports need presentation metadata, project it from
the run option into the report/Event field separately from authority metadata.

The role/store path must seed `agent.core` from the current source that passes
`"turn"` to both `llm-complete` and `eval-program`. `eval-program` treats
missing or non-integer `"turn"` as a fail-closed prelude contract error; do not
keep compatibility with stale stored `agent.core` variants.

### Phase 4 - Prelude Store Loading Boundary

Do not implement database/HTTP loading in this session. Instead, define and pin
the load-to-store boundary so future adapters can be added without changing
`Kernel.run/2`. This phase must extend `PreludeStore.write/5` with a
per-write origin option rather than demoting origin into untrusted metadata.
Origin is host-asserted provenance, projected through
`PreludeCandidate.public_origin/2`, and should not compete with
`max_metadata_bytes`.

Required API shape:

```elixir
PreludeStore.write(store, id, source, metadata, origin: {:file, path})
```

The option must validate fail-closed against the existing origin type:
`{:file, path}`, `{:memory, term}`, `{:upstream, term}`, or `nil`. Omitted
origin keeps today's store-level default.

Future loader adapters should normalize to this shape:

```elixir
%{
  id: "agent.prompt",
  source: "...",
  origin: {:file, "priv/preludes/agent/prompt.lisp"},
  metadata: %{"created_by" => "kernel_default_seed"}
}
```

Adapters may later produce that shape from:

- filesystem;
- HTTP admin import;
- database;
- upstream MCP resource/tool;
- generated source.

All adapters must write through `PreludeStore.write/5` so compilation,
dependency pinning, checksums, and public projections stay shared.

### Phase 5 - Deterministic Tests

Partially covered by current tests. The closeout plan above names the remaining
coverage required before marking D20 resolved.

Add focused tests before considering any live run:

- role policy parses the shared role vocabulary and rejects unknown keys;
- role policy rejects MCP-only keys until the kernel has enforcement points for
  them;
- role `preludes` behaves as an allowlist, not an implicit selection;
- `default_preludes` must be granted by the role allowlist;
- requested `Kernel.run(..., preludes: refs)` must be granted by the role
  allowlist;
- role selection resolves exact store refs into the same `agent.*` bundle as
  the embedded default when `agent.core` is seeded with
  `requires_preludes: ["agent.prompt@1", "agent.feedback@1"]`;
- dependency closure is recorded and dependency refs cannot silently drift;
- a role with no selected prelude permission fails closed;
- role-selected kernel run produces the same mock result as the embedded
  default for a simple mission;
- role-selected and embedded-default kernel runs produce equivalent D4
  TurnEvent correlation for a simple mission, including one-based `attempt`,
  committed `turn`, and matching `program`;
- sanitized run metadata includes role/fingerprint/selected refs but no source
  or prompt text;
- role-selected kernel TurnEvents include the expected source-free
  `role_prelude_selection` projection (`role`, `grant_fingerprint`,
  `selected_refs`, `resolved_refs`, and `prelude_store_access`);
- stale stored `agent.core` sources that omit `eval-program` `"turn"` fail
  closed instead of producing orphaned or misleading TurnEvents;
- renderer selection remains a run option and is not accepted inside the shared
  role grant;
- per-write `PreludeStore.write/5` origin is preserved in candidate provenance
  and defaults to the existing store-level origin when omitted;
- MCP policy behavior remains unchanged, or shared parser tests prove parity if
  code is factored.

Suggested initial command:

```sh
mix test test/ptc_runner/kernel_test.exs \
  test/ptc_runner/kernel/prelude_split_test.exs \
  test/ptc_runner/prelude_store_test.exs \
  test/ptc_runner/sub_agent/prelude_deps_integration_test.exs
```

If MCP code is touched:

```sh
mix test mcp_server/test/ptc_runner_mcp/sessions_lifecycle_test.exs \
  mcp_server/test/ptc_runner_mcp/http/router_admin_test.exs
```

Finish with:

```sh
mix precommit
```

## Design Checks

- **Authority boundary.** Role filtering and tool injection may remove
  capabilities; they must not grant tools or upstream operations that the host
  did not supply.
- **Projection path.** Symbol inventory and prelude provenance consume the
  resolved, grant-filtered prelude surface, not raw store candidates.
- **Value shape.** Role metadata and selection metadata are bounded,
  JSON-safe, and redacted.
- **Config space.** Unknown or misspelled config keys fail closed. Do not let
  `{checksumm: ...}` degrade into an unchecked `{id, version}` grant.
- **Schema ownership.** Shared role keys are only keys that both kernel and MCP
  can enforce. Surface-owned keys must be namespaced or rejected by other
  surfaces.
- **No source leakage.** Role-selected provenance can include ids, versions,
  checksums, namespaces, origins, and counts; never prelude source.
- **No path dependency.** Runtime config never needs a file path. File paths may
  appear only in loader origin metadata or the embedded default seed.
- **No MCP dependency.** Core modules must compile and test without depending on
  `ptc_runner_mcp`.

## Stop Conditions

- Stop and report if preserving MCP role-policy parity would require loosening
  MCP's fail-closed parsing or silently ignoring unknown keys.
- Stop and report if the seeded-store path cannot reproduce the embedded
  default bundle's component hashes after seeding `agent.core` with explicit
  `requires_preludes`.
- Stop and report if kernel role unification requires accepting a grant key
  that has no kernel enforcement point.
- Stop and report if per-write origin cannot be added to `PreludeStore.write/5`
  without weakening existing store bounds or provenance redaction.

## Launch Criteria

The plan is complete when:

- `Kernel.run/2` can run from a role-selected PreludeStore bundle;
- no-policy default behavior remains green and deterministic;
- role-selected provenance is visible in sanitized reports/events;
- tests prove role selection and embedded default compile equivalent `agent.*`
  runtime behavior and equivalent D4 TurnEvent correlation;
- `preludes` keeps MCP allowlist semantics and `default_preludes` supplies the
  non-interactive kernel default selection;
- per-write origin is preserved through `PreludeStore.write/5`;
- docs explain that roles, not profiles, are the unified selection/authority
  concept for kernel and MCP surfaces.

Only after those criteria are met should a later session consider replacing the
current feedback A/B file-override mechanism with role-selected stored
variants.
