# Handoff: trace-analysis tooling

**Written:** 2026-08-01, revised 2026-08-02. Branch
`worktree-incident-evidence-compiler`, 28 commits ahead of `origin/main` at
`7d997a0a`. Working tree clean and **fully pushed**; `mix precommit`,
`mix prepush`, and the warnings-as-errors doc build green as of the last
code commit — the two most recent commits are documentation only.
**No PR opened.**

Count against `origin/main`, not the local `main` ref — in this worktree the
local `main` is stale at `612621d2` and reports five extra commits.

Nothing on this branch is in `main` — `637958c1`, `d478cf38`, and `ba983f95`
are all still unlanded, verified with `git merge-base --is-ancestor`.

Covers one session of work that started as "dogfood the PTC log analysis
instead of using Python" and ended up touching turn correlation, private
inspection authorization, two plans, and the debugging documentation.

## Branch contents

Six independent workstreams are bundled here and would review better apart.

| Commits | What | State |
| --- | --- | --- |
| `039d9efc`, `6b320d1a`, `1d6bf22e` | incident-evidence compiler reference app | predates this session |
| `637958c1` | union-selection fix — **live bug on `main`** | ready, unlanded |
| `d478cf38` | capability events carry `evaluation_id` | shipped, tested |
| `ba983f95` | `--private-unattended` private destination | shipped, tested |
| `f8d7cea9`, `40308883` | sandbox tool-grant fix and memory guards | shipped, tested |
| `bb2be8cf`, `9e497012` | issue #1161 — actionable corrections, `describe/1` | rebased in, tested |
| `2285997a`, `1d00c606`, `2dbf7969`, `ba3dcbe1` + 8 superseded | documentation and plans | current |

Nine of those doc commits are the private-analysis plan being rewritten five
times. The plan was ultimately deleted; the history is left as a record of why.

The last two code commits were `agent/expose-result-contract-description`,
rebased onto this branch on 2026-08-02 because both branches edit the same tool
builders and resolving that twice was avoidable. Their originals are
`c55f0481` and `ecdf9c52`; that branch is now superseded and can be deleted
once this lands. The rebase's only conflicts were in
`agent-developer-findings.md`, where the incoming copy still cited `c236b981`
for the union fix — a pre-rebase SHA that is not in this history. The live SHA
is `637958c1`, which is what the table above and the findings doc now carry.
**Issue #1161 is still open with no PR linking this work to it.**

## Problems found and what was done

### 1. A turn's capability calls were unattributable

`log/turns {"evaluation_id" => id}` returned only the evaluation's own
start/stop pair. `turn_matches?` filters on the event's `evaluation_id`, but
capability events carried only `capability_id`, `environment`, and `name`.
Answering "what happened in this turn" meant reading every event in the run and
reconstructing evaluation windows from `sequence` order by hand.

**Fixed in `d478cf38`.** Capability-started/stopped events and the private
capability-input/output records now carry the `evaluation_id` of the evaluation
whose program invoked them, attributed to the innermost open evaluation. On the
private plane this joins a capability record to the `evaluation-source` record,
so one turn reads as a unit: model exchange including prose, the exact program,
and every call with arguments and results.

Threaded from each evaluation rather than inferred at query time from sequence
order — a dropped `evaluation-stopped` would silently misattribute everything
after it. Cost: existing traces do not gain the field.

Also collapsed `Dispatcher.dispatch/6,7,8` into one context-taking arity rather
than adding a ninth positional parameter.

### 2. The analysis REPL was undiscoverable, and one guide misled

Nothing documented how to debug a run through the shipped tooling, so the reflex
was `jq` or Python over raw JSONL. Worse, `kernel-repl.md`'s section titled
*"JSON Lines for coding agents"* steered agents to `--format jsonl`, whose
per-evaluation usage envelope then has to be parsed — while the default Clojure
format prints one readable value per form and works fine headless.

**Fixed in `1d00c606`.** One pointer bullet in `AGENTS.md`; the substance in
`running-and-debugging.md` (aggregate traversals, turn filter keys, scoping by
`evaluation_id`); the misleading section retitled *"JSON Lines for structured
output"* with corrected guidance.

### 3. Private inspection was interactive-only (finding 6)

`inspection-analysis-v2` could only be driven by a human at an attached
terminal, so an agent could not query private records even though it can query
canonical traces through `log-analysis-v2`.

**Fixed in `ba983f95`** by `--private-unattended`, a second authorized private
destination. Exactly one of terminal or unattended; both is
`private_destination_conflict`. Under it the profile admits
`-e`/`--load`/script/stdin and `jsonl`. The check lives in
`AnalysisSessionBuilder`, so an embedding host gets the same option.

**This took five plan drafts and four adversarial reviews, and the premise was
false twice.** Both errors are recorded in `agent-developer-findings.md` so the
argument is not remade:

- The gate was never containing the access. The Viewer already served the same
  private records non-interactively and fully validated —
  `ViewerAdapter.pin_inspection/2` runs `InspectionArtifact.load/1` and
  `validate_correlations/2`.
- The terminal check is not access control and cannot be. `isatty/1` cannot
  distinguish a human's terminal from a pseudo-terminal; verified that an
  agent's non-interactive shell under `script -q /dev/null` reports both streams
  as terminals and opens the private profile. A same-UID caller can also read
  the artifact directly.

What it *is* — an accident guard, keeping private values out of a log or
transcript by mistake — is now documented in `AnalysisSessionBuilder`'s
moduledoc.

### 4. Documentation and implementation disagreed in four places

Found while verifying claims rather than asserting them:

- `trace-log-contract.md` said turn filters include "capability name"; the
  accepted key is `capability`. Guessing `capability_name` returns
  `invalid trace query` with no list of accepted keys. **Corrected.**
- `PrivateDirectory` does not reject symlinked parents — `resolve_components/4`
  *follows* symlinks that pass an ownership check. A plan claimed the opposite.
- `AnalysisSession.error_message/2` already redacts to the constant
  `"private evaluation failed"` for private profiles, so stderr was already safe
  where a plan proposed designing that safety.
- `session-closed` is emitted only on `{:ok, info}`; a close failure produces
  `command_error` instead.

### 5. Local tooling was broken in three ways

Outside the repo, in `~/.claude/skills/codex/`:

- **`codex exec` blocks on stdin** when it is not a TTY, which a backgrounded
  harness call always is. It printed `Reading additional input from stdin...`
  and sat for 57 minutes using 0.08s of CPU while appearing to be a slow review.
  Fixed with `< /dev/null` on all seven invocations, plus a documented
  `ps -o etime,time` diagnostic — near-zero CPU against long elapsed time means
  blocked, not working.
- **`codex exec resume` rejects `-C` and `-s`**, which the documented follow-up
  command passed. Fixed to `cd` first and use `-c sandbox_mode="read-only"`.
  The same bug likely exists in `~/.codex/skills/codex-review`'s wrapper.
- **The gstack skill routed to twelve uninstalled skills** and offered to commit
  those routing rules into project `CLAUDE.md` files. Reduced to a standalone
  521-line skill with no gstack dependencies; backup at
  `~/.claude/skills/gstack.backup-20260801-141553`.

## Things to look into

Ranked by what blocks what.

### ~~1. `memory_exceeded` on `inspection-analysis-v2`~~ — **fixed**

Cause: every mission capability callback closed over the whole environment, and
the spawn copy into the sandbox does not preserve sharing. With ten
capabilities plus two runtime routes, the environment — dominated by its
16,214-word frozen bundle — was copied **twelve times** into the evaluation
process. Measured on the CLI: `tools` 231,328 words flat against 16,255 with
sharing, a pre-eval baseline of 552,708 words (4.4 MB), and 7,645 ProcBins.

That baseline is what killed the evaluation. `max_heap` is additive headroom
above the measured baseline, but BEAM heaps grow multiplicatively: with a
4.4 MB baseline the young heap steps in ~4 MB increments and the promoted old
heap holds another copy, so `baseline + 1,250,000` words was crossed after two
or three generation steps regardless of what the program did. Hence the
`mix run` versus `mix test` split — it was never environmental, only marginal.

Fixed by `Environment.capability_view/1,2`: dispatch resolves one name, so a
callback carries one capability; only the discovery routes carry the whole map.
Applied to all three tool builders (`Evaluation.mission_tools/6`,
`Runner.workflow_tools/3`, `ReplSession.tools/2`) — the two workflow builders
had the same defect, and captured the whole `config`/`session` besides. After:
`tools` 10,264 words flat, baseline 29,507 words (0.24 MB) — 19× smaller than
the 552,708 that was killing the evaluation — and 181 ProcBins.

Review caught a second, larger instance of the same defect: carrying the whole
capability map per callback is `O(capabilities²)`. Unreached by the shipped
profiles at ten capabilities, but a mission environment holding 30 MCP tools
with ordinary described-property schemas blew the 40 MB **setup** ceiling on
`(+ 1 1)` — 60 tools cost 80 MB of hand-over. Now linear: 3.9 MB at 60.

Regression tests in `test/ptc_runner/kernel/environment_copy_test.exs` cover
the two duplications separately; each fails only against its own defect. The
flaky test *"PTC-Lisp reaches exact evidence while its analysis trace stays
payload-free"* was the first cause and now passes standalone.

Residual, not pursued: the two discovery routes still copy the whole map, so
hand-over stays linear but with a ~3× constant. Precomputing
`Environment.metadata/1` once would shrink it.

### 2. `637958c1` is unlanded and `main` has the bug

The union-selection fix — `ValueContract.classify/2` selected error units by
list position, so every violation in a tagged-union contract reported an
arbitrary branch's fault. Written, tested, and rebased; still only on this
branch. It is the oldest ready thing here.

### 3. `authorize_frontend/2` is CLI-only

`AnalysisProfileRegistry.authorize_frontend/2` enforces input modes, output
formats, and continuation — and the Viewer ignores it entirely.
`ViewerReplSessionWorker.run/3` calls `AnalysisSessionBuilder.start/3` with no
options. So the `frontend/0` contract claims to describe how a profile may be
driven while one of the two frontends does not consult it. Larger than any
change here; probably its own plan.

### 4. Unexplained policy: `continue_on_error: :forbidden`

The private profile forbids it while `log-analysis` allows
`:repeated_eval_only`. No rationale is recorded anywhere. It was deliberately
left alone rather than relaxed on a guess, but it means one malformed `-e` ends
an agent's session and costs a full re-capture. Someone should establish and
document the reason, then decide.

### 5. The Viewer is dev-only and its inspection endpoint is unauthenticated

`mix.exs` has `{:ptc_viewer, path: "ptc_viewer", only: [:test, :dev]}` and the
Hex `files:` list excludes it. So library consumers have **no private inspection
path at all** — the Viewer answers a contributor's need, not a user's.

Separately, `GET /api/inspection/runs/:run_id` has no authorization check while
the REPL routes use nonces. The server is loopback-only, but loopback means any
local user, not just same-UID — broader than the stated trust boundary.

### 6. Open findings from the earlier session

Findings 1 and 3 are now **fixed on this branch** by the rebased
`bb2be8cf`/`9e497012`: corrections emit the declared key set at the violating
path with descending counters, and `kernel/result-contract-description` reaches
the compiled shape. Both remain unlanded, and issue #1161 does not yet
reference them.

Still open and tracked in `agent-developer-findings.md`: findings 7–9
(annotation vocabulary, failure-kind fingerprinting, in-loop verification).

## Known flaky tests

Investigated 2026-08-02. **Nothing below is fixed** — the section records
diagnosis and proposed changes only; the working tree carries none of them.

Every one has the same shape: a fixed wall-clock budget asserted from a
preemptible process, where an exhausted budget is indistinguishable from the
failure the test is looking for. None is an assertion mismatch indicating a
product defect. `test/test_helper.exs` already names this class — it halves
`max_cases` precisely because a sandbox's 1 s cap flakes under contention.

| Test | Budget that expires | Proposed change |
| --- | --- | --- |
| `mcp_oauth/store_memory_test.exs:416` | 100 ms binding freshness, spanning `flow/1`'s key generation and a store round-trip | anchor freshness last, so the window covers only `begin_flow` |
| `lisp/runtime/collection_ops_test.exs:64` | `Lisp.run/1`'s 1000 ms product default, for a sandboxed spawn | pass an explicit generous `timeout:` in the file's two eval helpers — they assert semantics, never timing |
| `analysis_session_test.exs:1149` | 1000 ms, hard-coded at 8 sites against the file's own `@lifecycle_timeout_ms 30_000` | use the constant, as its 15 sibling assertions already do |
| `kernel/dispatcher_effect_test.exs:103` | ExUnit's 100 ms `assert_receive` default, for `Task.async` plus a full mission dispatch | give the two callback-liveness waits an explicit timeout |
| `mcp_oauth/network_policy_test.exs:130` | 20 ms, from computing the deadline to `resolve/3` checking it | none — but see the real defect below |
| `IncidentCompiler.CompilerTest` | `setup_all` dies with `:mcp_timeout`, invalidating all 13 | none — not reproduced, and its timeouts are already 30 s/60 s |

### The reproduction record, corrected

The rate previously claimed here for `network_policy_test.exs:130` — "fails ~1
run in 10 **in isolation** — a race between the egress check and the deadline
path" — does not hold, and the mechanism named was wrong. Measured:

- 200/200 passes under `--repeat-until-failure`, and 40/40 isolated file runs.
- A faithful in-BEAM replay of the original guard (fresh process per iteration,
  4× CPU oversubscription) produced `:egress_denied` **0 times in 600
  attempts**. The gap the race needs stays under 5 ms against a 20 ms budget.
- `store_memory:416` and `collection_ops:64` likewise pass 200/200.
- Three consecutive full-suite runs: two clean, one failure — and that failure
  was `dispatcher_effect_test.exs:103`, which was **not** on the original list.

So the list was both overstated (no isolated failure is reproducible) and
incomplete. Treat any rate here as unmeasured unless it cites a method.

Use `--repeat-until-failure N` for this, not a shell loop over `mix test`: the
whole cost is BEAM startup, and looping externally makes a microsecond-scale
window take minutes to sample.

### A real defect found underneath, also unfixed

Unrelated to timing: `NetworkPolicy.resolve/3` folds an expired deadline into
`{:error, :egress_denied}`, reporting a timeout as a policy verdict about the
host. A deadline only 1 ms away already returns it. The module disagrees with
itself — `safe_resolve/3`'s own expiry branch returns `:resolution_failed`, and
so does `mcp_source.ex:1544` — which leaves the correct branch effectively
unreachable.

The fix is to drop the expiry from the guard, keeping `is_integer/1`, and let
`safe_resolve/3` classify it. That cannot widen egress: with no budget left the
resolver is never invoked and `{:ok, target}` is unreachable, while a
disallowed origin still fails the origin check first. Worth two tests — one
pinning an expired deadline to `:resolution_failed`, one pinning that a
disallowed origin still outranks it.

Consequence today is confined to diagnostics: `mcp_source.ex:1514` maps both
errors to `:mcp_transport_error`.

**There is no `pre-push` hook installed in this clone.** `git push` runs no
gates; run `mix precommit` and `mix prepush` yourself, or install the hooks with
`./scripts/install-hooks.sh` from the main checkout.

## Process notes

Recorded because the failure mode repeated and cost most of the session.

Five drafts of one plan each failed review the same way: a resolution that was a
plausible sentence the code contradicted. "Route `error.message` to the sink"
(already redacted). "Buffer records and write them as the session runs"
(buffering and streaming are different designs). "Matches `InspectionArtifact`"
(it holds no append target open). "`session-closed` carries the state" (not
emitted on failure). And the premise itself.

Two adversarial reviews caught four of them. The fifth — that the Viewer already
provided the access — was caught by the maintainer asking why the plan was
complex when the Viewer already worked. The reframing that collapsed the design
from ~380 lines to one CLI option came from the same direction.

The cheap lesson: check the seam before writing the sentence. The expensive one:
an adversarial reviewer inherits the framing of the question, so it will not
challenge a premise the question assumes.
