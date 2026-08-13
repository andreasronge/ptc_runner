# Coding agent review workflow

**Audience: people changing PtcRunner itself.** It describes how this
repository reviews its own changes.

Use this workflow when a change requires independent Codex review. Review
complements design, tests, Dialyzer, and repository gates; it does not replace
them.

## Define a reviewable slice

A reviewable slice changes one observable boundary, moves at least one
production caller, and deletes the transitional path that caller no longer
needs. Keep unrelated state machines in separate slices.

Before coding, write down:

- the observable change and explicit non-goals;
- the production caller that moves to the new boundary;
- each resource's creator, fixed owner, authorized user, and closer;
- behavior on success, ordinary error, caller death, worker death, owner death,
  deadline expiry, and an ambiguous call timeout;
- the absolute deadline used by each phase;
- which private values may enter process state, logs, diagnostics, and results;
- the old entrypoint or lifecycle path deleted by the slice.

For concurrency-sensitive work, turn the cases into a fault matrix and write
failing integration tests first. Use monitors, controlled suspension, and
explicit acknowledgements. Do not use sleeps or tight timing as
synchronization. Test work in its real owner rather than a wrapper mock.

For a new ownership or state-machine boundary, a bounded `consult` or
`challenge` may test the design before coding. Ask one focused question and
request concrete counterexamples.

## Stabilize the tree before review

Before the fresh review:

1. Format changed files and compile with warnings as errors.
2. Run the focused tests, including the failure-path matrix.
3. Regenerate ordinary generated artifacts when their checks report staleness.
   Never regenerate `priv/semantic_build_projection.json` on a feature branch;
   that projection is refreshed on main for a release.
4. Run Credo and relevant Dialyzer checks when types or process boundaries
   change.
5. Run the documentation warning gate when documentation changes.
6. Check `git diff --check`, the diff size, and untracked files.

Keep generators explicit. Hooks must not mutate files because concurrent
worktrees or automation may be staging other changes.

If a finding appears to require another owner, registry, ledger, or parallel
representation, reconsider the design before adding it. Repeated systemic
ownership or deadline findings usually mean the slice should shrink or be
redesigned from its fault matrix.

## Run one incremental review cycle

Run one fresh review for the complete draft:

```bash
~/.codex/skills/codex-review/scripts/codex-independent-review review
```

Validate findings against the code, batch related repairs, and resume the same
session:

```bash
~/.codex/skills/codex-review/scripts/codex-independent-review followup \
  --session REVIEW_SESSION_ID
```

Use focused follow-ups only while the session has actionable findings. A clean
follow-up covers the slice when:

- the fresh pass covered its complete original delta;
- later edits only addressed that session's findings;
- the base, scope, and reviewed bytes did not otherwise change; and
- relevant focused tests pass.

Commit and push that exact tree. Staging reviewed bytes, creating a commit,
changing only its message, or pushing it does not justify another cold review.

Start a fresh review after a rebase, unrelated edit, changed base, expanded
scope, or material redesign. Prefer rebasing before review or at a checkpoint.

## Verify and deliver

After the incremental review is clean, run gates on the reviewed tree:

```bash
mix precommit
MIX_ENV=dev mix docs --warnings-as-errors  # when documentation changed
```

Return source or generated-artifact repairs to the same session when they stay
within its scope. Start fresh only if a repair materially expands the slice.
Correct tool-invocation mistakes and rerun the authoritative command in the
repository's expected environment.

Before declaring a branch or pull request ready, run one cumulative,
base-guarded review:

```bash
~/.codex/skills/codex-review/scripts/codex-independent-review review \
  --base origin/main --fetch-base
```

Use that session for cumulative follow-up. Run another fresh cumulative review
only if the base advances or repairs materially expand scope.

## Review checklist

- [ ] One observable boundary and one production cutover.
- [ ] Replaced transitional path deleted.
- [ ] Ownership, deadline, privacy, and fault cases written down.
- [ ] Failure-path tests use deterministic synchronization.
- [ ] Formatting, generated artifacts, Credo, and relevant Dialyzer checks are
  clean before review.
- [ ] One fresh incremental review, followed only through its explicit session
      ID.
- [ ] No cold re-review of byte-identical content.
- [ ] Full repository gates pass on the reviewed tree.
- [ ] One cumulative base-guarded review at the checkpoint or PR boundary.
