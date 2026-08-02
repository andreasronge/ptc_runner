# Handoff: trace-analysis tooling

**Written:** 2026-08-01, revised 2026-08-02. Branch
`worktree-incident-evidence-compiler`, 28 commits ahead of `origin/main` at
`7d997a0a`. Everything through the last commit is **pushed**; `mix precommit`,
`mix prepush`, and the warnings-as-errors doc build were green as of the last
code commit.

The working tree is **not** clean: it carries the uncommitted flaky-test work
described under [Known flaky tests](#known-flaky-tests) — one product fix to
`NetworkPolicy.resolve/3` plus test changes across six files.
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

Findings 7 and 8 (annotation vocabulary, failure-kind fingerprinting) are also
fixed on this branch, by `d963ffc1` and its three review follow-ups: a
namespace declares both closed vocabularies in its `(ns ...)` metadata, so a
refusal names itself and carries its counts into a normal trace. Also unlanded.

Still open and tracked in `agent-developer-findings.md`: finding 9, in-loop
verification.

## Known flaky tests

Investigated and **fixed** 2026-08-02. The working tree now carries the fixes;
the numbers below are measured, and each cites its method.

### Method, because the last two records here were both wrong

Two harnesses, and they disagree — which is the whole lesson:

- **Full suite, default settings** (10-core machine, `max_cases: 10`, ~70 s a
  run). This is ground truth and the *only* harness that reproduced anything
  on the first pass.
- **One file, `--repeat-until-failure N`, under 20 CPU burners** (3×
  oversubscription). Fast, but it both misses real flakes and manufactures
  failures a real run never sees. Use it to *confirm* a mechanism and to
  verify a fix, never to rule a test clean.

The previous record concluded `network_policy_test` was not reproducible from
200/200 passes and 0/600 in a replay harness. It reproduced in a plain
full-suite run with exactly the originally predicted signature. The replay was
unfaithful: it had no CPU contention, so it never created the starvation the
bug needs. **A passing isolated loop is not evidence a test is clean.**

### Measured

Pre-fix, full suite × 10: **2 failures**. Post-fix, full suite × 12: 11 clean,
one *new* test surfaced (below). Isolated + 20 burners × 100: `dispatcher_effect`,
`owner_status_privacy`, `collection_ops` and `store_memory` were all clean — so
four of the six originally listed have **no reproduction evidence at all**.

| Test | Mechanism | Evidence | Fix |
| --- | --- | --- | --- |
| `mcp_oauth/network_policy_test.exs:141` | 20 ms window from computing the deadline to `resolve/3`'s guard, surfacing as `:egress_denied` | **full suite 1/10** | product fix below — now correct by construction |
| `mcp_oauth/network_policy_test.exs:147` | separate 500 ms overshoot bound on `Task.shutdown` | **burners only, iter 82/100** (644 ms) | **left at 500 ms** — see below; 200/200 clean unloaded |
| `owner_status_privacy_test.exs:129` | TOCTOU: `if Process.alive?(pid), do: GenServer.stop(pid, :normal)` | **full suite 1/10** | drop the guard, catch `{:noproc, _}` only |
| `bounded_worker_test.exs:134` | ExUnit's 100 ms `assert_receive` default, for a 1 ms timer plus several process hops | **full suite 1/12, burners iter 116** | explicit 5 s liveness timeout; **400/400 clean after** |
| `kernel/dispatcher_effect_test.exs:122,159` | 100 ms default spanning a `RunState` spawn and a whole `MissionEnvironment` build | none — 100/100 clean | hardened anyway; the budget is indefensible |
| `analysis_session_test.exs` (8 sites + helper) | 1000 ms hard-coded against the file's own `@lifecycle_timeout_ms 30_000` | none — not reproduced | use the constant, as its siblings do |
| `lisp/runtime/collection_ops_test.exs` | `Lisp.run/1`'s 1000 ms default for a sandboxed spawn | none — 100/100 clean | explicit `timeout: 5_000` in both eval helpers |
| `mcp_oauth/store_memory_test.exs:416` | 100 ms freshness spanning `flow/1`'s key generation | none — 100/100 clean | anchor freshness last |
| `IncidentCompiler.CompilerTest` | `setup_all` dies with `:mcp_timeout` | never reproduced | none; timeouts are already 30 s/60 s and it is `async: false` |

Note the correction to the earlier framing: **not every one is a wall-clock
budget.** `owner_status_privacy` is a teardown race, and no timeout change would
have fixed it. The sink, run-state and MCP owners each monitor the process that
started them and self-stop when it dies (the Viewer store only does so once
attached, which that test never does); `on_exit` runs after the test process
exits, so those owners are always dying exactly when teardown probes them.

### What the independent review changed

A Codex review of the diff confirmed the egress argument formally: if the old
guard rejected deadline `d` at `t0` then `d <= t0`, and `safe_resolve/3` reads
`t1 >= t0`, so the remaining budget can never become positive. It then found
four problems in the *test* changes, three of which were accepted:

- **Widening `:147` from 500 ms to 2 s was wrong** and has been reverted. It was
  justified by burner-harness evidence — exactly the harness this document says
  manufactures failures a real run never sees. It has never failed unloaded
  (200/200) and the bound is a real assertion, not headroom.
- **A 30 s eval timeout removed real coverage** in `collection_ops`: a 20-second
  evaluator regression would have passed. Reduced to 5 s — ample against
  starvation for programs this trivial, still failing on a gross regression.
- **Catching every `:exit` hid genuine teardown failures** in
  `owner_status_privacy`. Narrowed to `{:noproc, _}`, the only reason the race
  can produce. Verified that shape empirically before narrowing.
- Its fourth point — that raising the `analysis_session` budgets weakens
  orphan-prevention coverage — was **not** taken. 30 s is that file's own
  `@lifecycle_timeout_ms`, already used by 14 sibling assertions including one
  in the same test on a related `:DOWN`; the three 1000 ms values were the
  anomaly. The asserted property (the process does die) is unchanged.

It also caught a factually wrong code comment: not all three `BoundedWorker`
waits depend on the 1 ms timer — only the cleanup wait does, which is precisely
the one that was measured failing. The comment now says that.

### Still open: `bounded_worker_test.exs:137`

Seen **once**, in a full-suite run: the `{:DOWN, ...}` arrived with reason
`:noproc` instead of `:killed`, meaning the worker was already dead when
`Process.monitor/1` ran. This is *not* the budget mode and the timeout fix does
not address it — widening a budget cannot change which reason arrives. It did
not recur in 400 contended iterations, so it is rarer than that.

The mechanism is not established. Reading says the worker should still be alive:
the cleanup hook blocks *before* `terminate_linked`, and the caller is parked
inside it. Do not "fix" this by relaxing the assertion to accept `:noproc` —
that reason is precisely what the test exists to rule out.

### The product defect underneath — **fixed**

`NetworkPolicy.resolve/3` folded an expired deadline into
`{:error, :egress_denied}`, reporting a timeout as a policy verdict about the
host. The module disagreed with itself: `safe_resolve/3`'s own expiry branch
returns `:resolution_failed`, and so does `mcp_source.ex:1544`, which left the
correct branch effectively unreachable.

Fixed by dropping the expiry from the guard, keeping `is_integer/1`, and letting
`safe_resolve/3` classify it. This cannot widen egress: `safe_resolve/3` is
always on the path to `{:ok, target}` and returns before invoking the resolver
when no budget remains, while a disallowed origin fails `origin_allowed?/2`
first. Both properties are now pinned by tests, the second asserting the
resolver is never invoked. The classification is recorded in the moduledoc.

This also makes `network_policy_test:141` deterministic rather than merely
widening its budget — every path now returns `:resolution_failed`.

Consequence was confined to diagnostics throughout: `mcp_source.ex:1514` maps
both errors to `:mcp_transport_error`.

### Unapplied option: raise the global `assert_receive` default

`test/test_helper.exs` sets no `:assert_receive_timeout`, so all **477**
`assert_receive` sites run on ExUnit's 100 ms default; three separate tests were
caught by it. Raising only `assert_receive_timeout` (leaving
`refute_receive_timeout` at 100 ms, since the **128** `refute_receive` sites pay
their full budget on *success*) would cover the untriaged tail at no cost to a
passing run. Left unapplied — it is a suite-wide policy call, not a bug fix.

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
