# Server-Stamped Turn-Log Tags

**Status:** implemented in `ptc_runner_mcp` after the issue surfaced
2026-07-06 in the `autonomous-shakedown-1` Stage 2 gate fail in
`ptc-bench-comparison` (bench commit `6d747c2`, rerun governed by
`amendment-a-stage2-apparatus-rerun.md`, which filed this as its runner
follow-up). Related: the gate-evidence principle in
[`grant-projection-legibility.md`](grant-projection-legibility.md) — audit
surfaces must not depend on the audited party's cooperation.

## Problem

Turn-log rows carry `tags` so downstream gate audits can select exactly the
rows belonging to one run/stage. Before this change, the only source of those
tags was the session caller: `lisp_session_start` accepted a `tags` argument,
the session struct stored it, and `sessions/registry.ex` normalized it.
`TurnLogConfig` held only `turn_log_dir`, so the server had no way to stamp tags
itself.

That makes tag provenance model-cooperative: the audited party must volunteer
its own audit identity. The failure mode is not hypothetical. In
`autonomous-shakedown-1` the stage prompts dropped the "exactly these tags"
instruction that demo 3 carried; the model (reasonably) started its session
with only `mode` and `title`, every row landed with `tags: {}`, and the
post-stage gate — which filters rows by `{run, stage}` — went blind: three
checks failed on zero rows and a `tool_calls` budget counter silently passed
on an empty set, even though the raw log showed a fully compliant 22-turn
session. The failure was fail-closed (good), but the audit's evidence stream
should never have been contingent on prompt wording in the first place.

## Design

Let the boot own audit identity. The one-boot-per-stage protocol already
makes the boot the natural run/stage boundary (`start-stage-server.sh`
selects `--turn-log-dir <run>/turn-log/<stage>` per stage), so tags belong
next to the directory they scope:

- `--turn-log-tags '<json object>'` / `PTC_RUNNER_MCP_TURN_LOG_TAGS`,
  parsed at boot in `application.ex` alongside `--turn-log-dir`
  (`apply_turn_log_config/1`, `application.ex:1037`), stored as
  `default_tags` in `TurnLogConfig`. Boot tags are **string keys and
  non-empty string values only** — audit identity should be boring stable
  strings, and an empty value would satisfy row-presence checks while being
  useless to the gate filter. This is deliberately *stricter* than the
  caller side: `validate_tags_arg` (`sessions.ex:699`) accepts scalar JSON
  values (strings, numbers, booleans, null) and keeps doing so —
  tightening an existing surface would break compatible callers for zero
  audit benefit.
- Merge at session creation (the single site that already normalizes tags,
  `registry.ex:253`): effective tags =
  `Map.merge(caller_tags, default_tags)`, **server wins**. Session
  introspection then shows the effective tags, so the stamp is legible to
  the session itself, not just to the log reader. The merge order matters
  even though the conflict rejection below makes it look redundant: the
  rejection check lives on the `lisp_session_start` argument path only,
  while the registry merge covers every session creator (internal, test,
  future callers). For those paths a conflicting tag is silently stamped
  rather than rejected — the right behavior when there is no model on the
  other end to read a teaching error. Do not "simplify" the merge order.
- A caller-supplied tag whose key matches a boot default with a
  *different* value is rejected at `lisp_session_start` with a teaching
  error naming the key and the boot-stamped value with its type (so a
  numeric-vs-string mismatch like `{"stage": 2}` against `"stage2"` is
  self-diagnosing). Comparison runs on the *normalized* caller tags (the
  form `registry.ex:253` produces), like-for-like with the JSON-parsed
  boot tags, so representation differences cannot create false conflicts.
  A matching duplicate value is accepted — existing harness prompts that
  supply the exact tags keep working unchanged. Callers may still *add*
  keys the boot does not claim. Fail-closed and legible beats silent
  override: with an override, a misconfigured harness looks identical to a
  compliant one; with rejection, the mismatch surfaces at the first tool
  call, inside the stage, where the launcher's stderr captures it.
- Rows emitted for sessions when no `default_tags` are configured behave
  exactly as today — the feature is opt-in and existing evidence is
  unaffected. Replay is not implicated either way: the replay harness
  compares tool-boundary responses, not turn-log rows.

Shape considered and set aside: per-role tags in the `--session-roles`
config. Roles are stage-agnostic in the bench protocol (the `proposer` role
serves stage3 and stage3r; `reviewer` serves stage4 and stage4r), so role
config cannot carry the stage half of the identity. The boot can.

## Consumer Changes

- `start-stage-server.sh` in bench run scaffolds passes
  `--turn-log-tags "{\"run\":\"<run-tag>\",\"stage\":\"$STAGE\"}"` per boot.
- The prompt-side "exactly these tags" first-action instruction becomes
  redundant; prompts can drop it or keep it (matching tags are accepted).
- `gate_policy.py` can add a provenance check that the boot ledger records
  the tag stamp for the audited stage, closing the loop from the operator
  side.

## Validation

- A session started with no `tags` argument under a booted
  `--turn-log-tags {"run":"r","stage":"s"}` produces turn rows tagged
  `{"run":"r","stage":"s"}`.
- A session supplying the exact boot values as duplicates is accepted with
  identical effective tags (transition compatibility for prompts that
  instruct the tags explicitly).
- A session supplying an additional non-conflicting key produces rows with
  the merged map; a session supplying `{"stage":"other"}` — or a
  type-mismatched `{"stage": 2}` — is rejected at start with a teaching
  error naming `stage` and the boot-stamped value.
- Boot parse rejects non-string or empty-string keys/values in
  `--turn-log-tags` (refuse to boot, same posture as other malformed boot
  config).
- A session created off the MCP argument path with a conflicting tag is
  stamped by the registry merge (server value wins), not rejected.
- With no `--turn-log-tags`, behavior is byte-identical to today (existing
  session lifecycle tests unaffected).
- Bench-side: the `autonomous-shakedown` gate audit passes its
  `tagged_turn_log_rows_present` check on a stage run whose prompt carries
  no tags instruction at all.
