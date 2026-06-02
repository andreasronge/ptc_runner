# Parallel Conformance-Gap Plan (subagent setup)

> Working doc for a **future session** that will spin up parallel subagents to
> close open Clojure-conformance BUGs from issue #1030 / `docs/clojure-conformance-gaps.md`.
> Not a library spec — delete when the batch is merged.

## Goal

Close several open `docs/clojure-conformance-gaps.md` BUGs concurrently, one
gap per subagent, each in an isolated **git worktree**, then have the
orchestrator integrate them serially and run the regen + N/N coverage gate
once.

Source of truth for status: `docs/clojure-conformance-gaps.md`. Tracking issue:
**#1030** (102 open BUGs as of 2026-06-02).

---

## Why this needs the worktree + serial-integrate model

Each gap fix per the established workflow touches **two layers**:

### Parallelizable layer — the implementation
Runtime builtins are split by sub-area into separate modules, so gaps in
different areas edit different files and never collide on the implementation:

| Sub-area        | Primary module(s)                                  |
|-----------------|----------------------------------------------------|
| seq/collection  | `lib/ptc_runner/lisp/runtime/collection.ex` (+ `collection/select.ex`) |
| clojure.string  | `lib/ptc_runner/lisp/runtime/string.ex`            |
| number/math     | `lib/ptc_runner/lisp/runtime/math.ex`              |
| Java interop    | `lib/ptc_runner/lisp/runtime/interop.ex`           |
| map ops         | `lib/ptc_runner/lisp/runtime/map_ops.ex`, `flex_access.ex` |
| predicates/type | `lib/ptc_runner/lisp/runtime/predicates.ex`        |
| regex           | `lib/ptc_runner/lisp/runtime/regex.ex`             |

### Serial layer — shared files every gap writes
These are clobbered by parallel in-place edits, so worktree isolation is
mandatory and integration is serialized:

- `test/support/lisp_conformance_cases/manual.ex` (~8 070 lines — **all** cases)
- `docs/clojure-conformance-gaps.md` (status flip + DIV sections)
- `priv/function_audit.exs` and `priv/java_compat_audit.exs` (audit-note clauses)
- regenerated: `conformance_inventory.json`, `docs/conformance/*.md`
- the **N/N GAP/DIV coverage** check — a single `mix` run that must pass once at the end

Conflicts in `manual.ex` / the gaps doc are *additive* (each gap appends its own
case / section), so they resolve trivially during integration — but they must be
resolved by the orchestrator, not raced.

---

## The canonical per-gap fix workflow (each subagent runs this)

(From `feedback_conformance_fix_workflow` — inlined so the next session is self-contained.)

1. **Verify the gap doc's own claims against Babashka first.** The doc's
   "Clojure" / "PTC-Lisp current behavior" values are sometimes WRONG. Babashka
   is at `_build/tools/bb` (the conformance runner uses it, not system clojure).
   Caveat: bb (SCI) diverges from JVM Clojure on some **reader-level** cases —
   when codex cites JVM behavior that contradicts bb, cross-check system
   `clojure` (`/opt/homebrew/bin/clojure -M -e '(prn (read-string "..."))'`) and
   prefer JVM Clojure for reader/form-equality semantics; bb is ground-truth for
   runtime values.
2. **Implement** in the target runtime module. For shared helpers (flex_access,
   map_ops, callable dispatch, numeric/Math) expect codex to surface real edge
   cases — budget several rounds.
3. **Convert the conformance case** in `test/support/lisp_conformance_cases/manual.ex`:
   a fixed bug's `bug_case(... "GAP-X")` becomes
   `regression_case(id-without-bug, ..., ["GAP-X"], [tags])` (drop the `-bug`
   suffix). Reclassified-as-DIV → `div_case(..., "DIV-NN", ptc_expected, reason)`
   (wrap NaN/Inf/special-value expectations in `(str ...)`).
4. **Update the audit note** (`priv/function_audit.exs` or
   `priv/java_compat_audit.exs`): drop ONLY that gap's clause; keep others in the
   same note.
5. **Gaps doc** (`docs/clojure-conformance-gaps.md`): Status → `**fixed**` (or
   tombstone `### ~~GAP-X~~: Reclassified as DIV-NN` + add a `### DIV-NN:`
   section), update Source ids, replace the `;; PTC-Lisp current behavior` block
   with fixed outputs, Decision → Fix paragraph.
6. **Regen** (orchestrator does this ONCE after all merges, not per subagent):
   `mix ptc.gen_docs` **and** `mix ptc.conformance_report --write-inventory`
   (the plain coverage run does NOT write the inventory JSON). Must stay
   **N/N GAP/DIV coverage**.
7. **Verify** the converted case(s) via `LispConformanceRunner.run_case` with
   `--include clojure` (temp test, then delete) and `mix test test/ptc_runner/lisp`.
8. **Codex review (mandatory).** Use the **`codex` skill** (not a raw CLI call)
   at **high effort** to review the uncommitted change; commit on the first clean
   round. Gate = [P1]=FAIL; [P2]s advisory (fix real in-scope correctness gaps,
   DECLINE [P2]s that demand diverging from PTC's value model — document
   rationale in the gap doc/moduledoc instead). One gap = one commit.

Flaky in the full suite (ignore — environmental): MCP stdio fixture
`:epipe`/timeout, trace-collector write-error tests. Confirm with `--seed 0`.

---

## Recommended first batch (5 gaps, 5 distinct implementation files)

Chosen as high-value quick wins, each in a **different** primary module so
worktrees integrate without code conflicts. 3×P1 + 2×P2.

| Gap       | Pri | Eff | What | Target file (impl) |
|-----------|-----|-----|------|--------------------|
| **GAP-S22**  | P1 | S | `get-in` returns default for an explicitly-present `nil` value (should return the `nil`) | `runtime/flex_access.ex` |
| **GAP-S136** | P1 | S | `map-entry?` does not recognize seq map entries | `runtime/predicates.ex` |
| **GAP-S9**   | P1 | S | `find` uses predicate search instead of map lookup | `runtime/collection/select.ex` |
| **GAP-S74**  | P2 | S | `clojure.string/split` should accept plain-string delimiters | `runtime/string.ex` |
| **GAP-J14**  | P2 | S | `String.substring` rejects finite numeric indexes | `runtime/interop.ex` |

### Co-scheduling rules (do NOT run these together — same file)
- **`predicates.ex`**: GAP-S136 and GAP-S40 (`vec nil`) both live here → pick one
  per batch. Also S127, S129, S84, S70, S64, S78, S101 are predicate-area.
- **`flex_access.ex` / `map_ops.ex`**: GAP-S22, GAP-S19, GAP-S36, S24, S100, S17,
  S54 cluster here → at most one or two, and verify they touch different fns.
- **`string.ex`**: the whole clojure.string list (S15, S25, S26, S27, S50, S74,
  S80, S95, S124, S139) + several Java-interop string methods → one at a time.
- **`collection.ex`** is large and many seq gaps map to it → schedule one
  collection gap per batch (note S9 is in the separate `collection/select.ex`,
  so S9 + one `collection.ex` gap is fine).

Substitutes if you want a different/larger batch (still distinct files):
- regex: **GAP-S82** (`re-seq` no-match → nil) or **GAP-S66** → `runtime/regex.ex`
- math: **GAP-S138** (mod/quot/rem non-finite) → `runtime/math.ex`
- map_ops: **GAP-S100** (merge vector map-entry sources) → `runtime/map_ops.ex`

---

## Orchestration procedure (the next session)

1. **Pick the batch** (default: the 5 above). Confirm none share a primary file
   via the co-scheduling rules.
2. **Spawn one worktree subagent per gap** — `isolation: "worktree"`, ~3–4
   concurrent (codex rounds, ~5–6 for subagent code, are the bottleneck, not the
   edits). Each runs steps 1–5, 7, 8 of the workflow **inside its worktree** and
   commits one clean commit. **Skip step 6 (regen) in the worktree** — defer to
   integration.
3. **Integrate serially** on `main` (user commits directly to main — no PR
   branch): cherry-pick / apply each subagent's commit in turn. Resolve the
   additive `manual.ex` and gaps-doc edits (each gap owns a distinct
   case/section, so conflicts are append-vs-append).
4. **Run the regen + gate ONCE** on the integrated tree:
   - `mix ptc.gen_docs`
   - `mix ptc.conformance_report --write-inventory` → confirm **N/N coverage**
   - `mix precommit` (format, compile, credo, schema, spec, tests)
   - **Codex review of the combined diff** via the **`codex` skill at high
     effort** as the final gate ([P1]=FAIL). This is mandatory in addition to
     each subagent's per-gap review — the integrated diff is reviewed as a whole.
5. **Update issue #1030**: tick the closed gaps, decrement section + quick-win
   counts, bump the header tally (open ↓, fixed ↑), add a dated changelog note.
   (See the 2026-06-02 update for the exact format.)

## Per-subagent prompt template

```
You are fixing ONE Clojure-conformance gap: <GAP-ID> — <one-line description>.
Target module: <file>. You are in an isolated git worktree; commit exactly one
clean commit here, do NOT run `mix ptc.gen_docs` or the inventory regen
(the orchestrator does that once at integration).

Follow docs/parallel-conformance-plan.md steps 1–5, 7, 8:
1. Verify the gap doc's claims against Babashka (_build/tools/bb) BEFORE coding;
   cross-check system `clojure` for reader-level semantics if codex disputes bb.
2. Implement in <file>.
3. Convert the conformance case in test/support/lisp_conformance_cases/manual.ex
   (bug_case → regression_case, drop the -bug suffix; or div_case if reclassified).
4. Drop only this gap's clause from priv/function_audit.exs or java_compat_audit.exs.
5. Flip Status to **fixed** in docs/clojure-conformance-gaps.md (+ DIV section if reclassified).
7. Verify with LispConformanceRunner.run_case --include clojure (temp test, delete it)
   and `mix test test/ptc_runner/lisp`.
8. Review via the `codex` skill at HIGH effort (not a raw CLI call); iterate to
   a clean [P1] round; then commit (Conventional Commit subject, e.g.
   `fix(lisp): <subject> (<GAP-ID>)`).

Report: final commit SHA, the manual.ex case id you added/changed, and any
[P2]s you DECLINED with rationale.
```

## Risks / notes
- **N/N coverage is the real gate** and is global — it can only be validated
  after integration, so a green subagent does not guarantee a green merge.
- If two gaps in a batch turn out to touch the same helper (e.g. a shared
  `flex_fetch`), integrate them adjacent and re-run the gate between them.
- bb-vs-JVM reader divergence (see GAP-S147) is a known trap — instruct subagents
  to prefer JVM Clojure for reader/form-equality, bb for runtime values.
- Commit directly to `main`; do not open feature-branch PRs.
