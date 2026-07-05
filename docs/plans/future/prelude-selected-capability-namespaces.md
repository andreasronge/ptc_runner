# Prelude-Selected Capability Namespaces

**Status:** future direction, not scheduled implementation. This is a cleanup
direction for the session capability model after store-backed prelude
dependencies and composition settle. It proposes replacing the `mode` /
`role` grant model implemented in
[`composable-prelude-library-demo.md`](../composable-prelude-library-demo.md)
Slice C — read that slice first for the baseline this doc is simplifying, not
as a still-open design.

## Problem

ptc_runner currently enables optional Lisp namespaces through several adjacent
mechanisms:

- regular capability preludes are attached with `:prelude` / `runtime_prelude`;
- `log/` is a host-shipped prelude plus host-granted `log_*` tools;
- `prelude/` store authoring is a host-shipped prelude plus private
  `prelude_store_*` tools, gated by MCP server config and
  `mode: "write_capable"`;
- `tool/` is populated directly from the granted host tool map;
- core discovery exposes a small fixed set of built-in namespaces.

The model is defensible, but the MCP session surface is more special-cased than
it needs to be. In particular, `mode: "write_capable"` is a separate switch
whose real effect is "attach the `prelude/` authoring capability and grant its
private backing tools."

The composable-prelude demo adds an auditability reason to pursue this
direction. Process-level CLI allow/deny flags can hide the surface a model
actually saw from the run's own turn log. Session-selected capability
namespaces would make that surface part of `lisp_session_start`, so a gated run
can prove which read, write, discovery, and authoring capabilities were visible
to each stage.

## Direction

Make selected preludes the main namespace enable/disable surface for MCP
sessions:

```json
{
  "preludes": ["paged@2", "log/read", "prelude/read"]
}
```

or, if variants remain attached to one logical prelude id:

```json
{
  "preludes": [
    {"id": "prelude", "config": "read"},
    {"id": "paged", "version": 2}
  ]
}
```

The important split remains:

- **namespace availability:** which public namespaces and exports are attached;
- **authority backing:** which host/private tools those exports are allowed to
  call.

Loading a capability prelude should never implicitly widen authority. Instead,
each capability prelude declares its `tool:<name>` requirements in the normal
export metadata. Session start resolves the selected preludes, grants only the
backing tools allowed by host policy, attaches the bundle, and fails closed when
any selected export requires unavailable authority.

## Dependent Surface Variant

The `composable-demo-2-20260705` gated loop produced and accepted a concrete
variant of this direction for dependency-heavy read-only sessions:
`scoped_base_surface`.

When a session attaches dependent prelude `P` with base dependency `B`, and
`scoped_base_surface` is explicitly enabled, the catalog/discovery surface
contributed by `B` is narrowed to the `B` exports that `P` actually references.
Execution still resolves the full dependency closure; only the presented
surface changes. The option is default-off, recommended for read-only
inspection sessions, and must not change authoring or direct-base attach
behavior.

Required shape from the accepted review:

- **Opt-in, default off.** With the option disabled, dependent attach behavior is
  byte-for-byte unchanged.
- **Full-surface escape hatches.** Direct attach of `B` always presents all of
  `B`'s exports, and dependent attach provides an explicit `reveal_full_base`
  discovery path.
- **Deterministic derivation.** The narrowed set is derived from pinned
  dependency metadata: the union of `dep_calls.transitive` references from
  `P`'s forms into the pinned `(id, version, checksum)` for `B`.
- **Fail closed on stale pins.** If the pinned checksum no longer matches the
  live base, do not silently re-derive. Present the full base surface and flag
  the split for re-review.
- **Measured promotion.** Acceptance requires a `catalog_ops` before/after on
  the motivating split with no task-output regression. If the measurement shows
  no reduction, the request demotes to no-change.

The demo split that produced this request had `paged_audit` depend on
`paged_base`; recomputing cross-layer references over all audit forms yielded
`{paged_base/sample}`, so the scoped catalog would present one base export
instead of six. The request is provenance-tracked as specified and reviewed by
the `ptc-bench-comparison` gated loop, not as an implementation commitment.

## Store Capability Shape

Prefer capability-split store preludes over one dynamically configured
`prelude/` namespace:

- `prelude/read` exposes read-only inspection: `list`, `history`, `read`,
  `source`, `forms`, `form-deps`, `deps`, `form`.
- `prelude/write` exposes mutation: `write`, `edit`, `set-default`, and depends
  on or composes with the read capability as needed.

This lets the prompt inventory, discovery surface, and authority requirements
match what the session actually selected. It also avoids a source/runtime
mismatch where a single prelude advertises functions that are disabled by
configuration and then fail later at call time.

An implementation could choose either separate namespaces:

```text
prelude_read/list
prelude_write/write
```

or one user-facing namespace assembled from selected components:

```text
prelude/list
prelude/write
```

The latter is nicer for users but requires careful duplicate-export and prompt
inventory handling.

## MCP Session Sketch

Target session start behavior:

1. Parse `preludes` as the complete requested capability namespace set.
2. Resolve store refs and host-shipped capability refs through one selection
   mechanism.
3. Expand declared prelude dependencies and order the bundle.
4. Build the allowed backing-tool map from server policy.
5. Attach the selected prelude bundle with `requires` validation against that
   backing-tool map and the upstream runtime.
6. Reject the session if a selected capability requires authority the server did
   not grant.

Under this model, the current special case:

```json
{"mode": "write_capable"}
```

becomes something closer to:

```json
{"preludes": ["prelude/write"]}
```

with server policy still deciding whether `prelude/write` is allowed.

## Non-Goals

- Do not make all built-in language namespaces preloadable packages. Core Lisp
  namespaces can remain curated and always available.
- Do not collapse `tool/` into prelude selection; the granted tool map remains
  the authority boundary.
- Do not let selected preludes bypass existing `requires` validation or private
  tool authorization.
- Do not implement this before the prelude dependency model can express and
  attach capability components predictably.

## Open Questions

- Should capability variants be separate ids (`prelude-read`, `prelude-write`)
  or one id with configs (`prelude` + `read`/`write`)?
- If two selected components contribute the same namespace, should this be
  allowed only for host-shipped capability fragments, or should duplicate
  namespaces keep failing closed everywhere?
- How should `mix ptc.repl` expose the same model: `--prelude-store-seed` plus
  `--prelude prelude/read`, or a separate authoring-mode flag for local testing?
- How should prompt inventory distinguish host-shipped capabilities from
  store-authored capability libraries?
