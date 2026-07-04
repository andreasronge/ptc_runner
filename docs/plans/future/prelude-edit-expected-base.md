# Prelude Edit Expected-Base Guard

**Status:** future direction, not committed work. This records a gap found by
the composable-prelude demo preflight against `ptc_runner` `5055deac`.

## Problem

`prelude/edit` currently means "edit the current candidate for this id."

That is safe for the internal read/splice/write operation, because
`PreludeStore.edit/4` reads the latest candidate, derives that candidate's
checksum and version, and passes those values into `write/4` as
`parent_checksum` and `parent_version`.

It does not support a stronger cross-turn protocol:

1. a model or orchestrator inspects prelude version N;
2. it prepares form-keyed edits for version N;
3. another writer bumps the prelude to N+1;
4. the original edit is submitted and should fail closed as stale.

At `5055deac`, caller-supplied expected-base fields are not part of
`prelude/edit`'s public contract. Supplying `parent_checksum` or
`parent_version` in request metadata does not guard the edit, because
`PreludeStore.edit/4` overwrites them with the current candidate's values before
calling `write/4`.

`prelude/write` already has the desired parent guard. The missing piece is
exposing an equivalent expected-base contract on `prelude/edit`.

## Proposed Direction

Add optional expected-base fields to `prelude/edit`:

```clojure
(prelude/edit
  {:id "paged"
   :base_version 2
   :parent_checksum "..."
   :edits [{:op "replace_form" :name "check" :source "..."}]})
```

Naming can vary, but the public contract should be explicit:

- if no expected base is supplied, keep today's "edit current" behavior;
- if `base_version` and/or `parent_checksum` are supplied, read the current
  candidate and reject before splicing unless it matches;
- include both fields in success results, as today, so callers can chain guarded
  edits;
- preserve the existing internal append-time parent recheck to catch races after
  the initial expected-base check.

Prefer top-level request fields over hiding this in `:metadata`. These fields
are protocol controls, not user-authored metadata.

## Semantics

Expected behavior:

- matching `base_version` and `parent_checksum`: apply the edit to that current
  candidate and write the next version.
- mismatched `base_version`: return `:stale_base`.
- mismatched `parent_checksum`: return `:stale_base`.
- only `base_version` supplied: reject if the current version differs.
- only `parent_checksum` supplied: reject if the current checksum differs, with
  the same ambiguity concerns as `write/4` when pin-only rewrites reuse source
  checksums.
- stale rejection must not splice, compile, or append a new candidate.

The append path should still pass the actual base version/checksum into
`write/4`, so concurrent writes between the expected-base check and append keep
failing closed.

## Tests

Add coverage at three layers:

1. `PreludeStore.edit/4` unit tests:
   - accepts matching expected base;
   - rejects stale version;
   - rejects stale checksum;
   - rejects without appending;
   - still rejects a race during append.
2. `prelude/edit` Lisp wrapper tests:
   - top-level expected-base fields reach the store;
   - fields are not persisted as user metadata unless intentionally echoed.
3. MCP session smoke:
   - write version N;
   - prepare an edit request for N;
   - bump to N+1;
   - submit the old request through `lisp_session_eval`;
   - observe `stale_base` and unchanged latest version.

## Why It Matters

The form-keyed edit design removes whole-source rewriting and position-blind
anchor substitutions, but without an expected-base guard it cannot express
"apply these deltas only to the exact form graph I inspected." That matters for
human-gated multi-process runs, reviewer/editor separation, and any future
workflow where an edit request is prepared in one turn and executed later.

This is not required for simple "edit latest" use. It is required for claiming
prepared-edit stale-base safety through the MCP session path.
