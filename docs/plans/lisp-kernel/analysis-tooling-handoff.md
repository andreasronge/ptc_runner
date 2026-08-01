# Handoff: trace-analysis tooling

**Written:** 2026-08-01, branch `worktree-incident-evidence-compiler`,
18 commits ahead of `main` at `7d997a0a`. Working tree clean, pushed,
`mix precommit` green. **No PR opened.**

Covers one session of work that started as "dogfood the PTC log analysis
instead of using Python" and ended up touching turn correlation, private
inspection authorization, two plans, and the debugging documentation.

## Branch contents

Four independent workstreams are bundled here and would review better apart.

| Commits | What | State |
| --- | --- | --- |
| `039d9efc`, `6b320d1a`, `1d6bf22e` | incident-evidence compiler reference app | predates this session |
| `637958c1` | union-selection fix — **live bug on `main`** | ready, unlanded |
| `d478cf38` | capability events carry `evaluation_id` | shipped, tested |
| `ba983f95` | `--private-unattended` private destination | shipped, tested |
| `2285997a`, `1d00c606`, `2dbf7969` + 8 superseded | documentation and plans | current |

Nine of those doc commits are the private-analysis plan being rewritten five
times. The plan was ultimately deleted; the history is left as a record of why.

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

### 1. `memory_exceeded` on `inspection-analysis-v2` — blocks §3

`inspection-analysis-v2` returns `kind: :memory_exceeded` for **any** evaluation
under `mix run`, including `(+ 1 1)`, at any artifact size, through either the
CLI or `AnalysisSessionBuilder` + `AnalysisSession.evaluate/2` directly. The
same evaluation passes under `mix test`. `log-analysis-v2` works everywhere.

Reproduces at merge-base `3dddb84c` with every change from this session
reverted, so it is pre-existing and unrelated to `ba983f95` — but it means the
feature that commit ships **cannot be used end to end**.

Three hypotheses disproven, so do not re-spend on them:

- **Bundle growth from #1162** — the inspection prelude is 6,951 words, 0.6% of
  the 1,250,000-word evaluation heap.
- **Artifact size** — a 2.9 KB fixture fails identically to a 210 KB one.
- **CLI-specific** — the builder API fails the same way.

The unexplained part is `mix run` versus `mix test` with identical code and
data. Toolchain matches `mise.toml` exactly (Erlang 29.0.3, Elixir
1.20.2-otp-29). Worth looking at what is copied into the spawned evaluation
process, since `mission_tools/6` closures capture the environment.

Related and possibly the same cause: the test *"PTC-Lisp reaches exact evidence
while its analysis trace stays payload-free"* fails deterministically when its
file is run alone and passes in the full suite.

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

Unchanged and still tracked in `agent-developer-findings.md`: finding 1
(correction cannot name an undeclared key, issue #1161), finding 3
(`ValueContract.describe/1` is unreachable), and findings 7–9 (annotation
vocabulary, failure-kind fingerprinting, in-loop verification).

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
