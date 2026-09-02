# Coding agent review workflow

> **Audience:** people and coding agents changing PtcRunner itself.

Use this workflow when a change requires independent Codex review. Review
complements design, tests, Dialyzer, and repository gates; it does not replace
them. The review cycle itself — one fresh `review`, `followup` by session ID,
when a clean follow-up approves a tree, when to start over — is defined once in
the `codex-review` skill. This page adds what is specific to this repository:
what a reviewable slice is, what must be true before review, and how the
change is delivered.

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

## Review and deliver

Run one fresh review of the complete draft and follow it through its session:

```bash
~/.codex/skills/codex-review/scripts/codex-independent-review review
~/.codex/skills/codex-review/scripts/codex-independent-review followup \
  --session REVIEW_SESSION_ID
```

Then run the gates on the reviewed tree: `mix precommit`, plus
`MIX_ENV=dev mix docs --warnings-as-errors` when documentation changed. The
suite, Dialyzer, ExDoc HTML, Viewer, launcher, and release run on `git push`;
do not follow `mix precommit` with `git push --no-verify`. Return in-scope
source or generated-artifact repairs to the same session.

Before declaring the branch ready, rebase onto `origin/main`, rerun the gates,
and run one cumulative, base-guarded review:

```bash
~/.codex/skills/codex-review/scripts/codex-independent-review review \
  --base origin/main --fetch-base
```

Start a fresh review only after a rebase, unrelated edit, changed base,
expanded scope, or material redesign. Staging, committing, amending a message,
or pushing reviewed bytes never justifies another cold review of the same
tree.

When a PtcManager task states a review count, it counts these cold sessions:
`1` is the cumulative review alone, `2` adds the incremental review of the
draft, and `3` adds a `challenge` of the finished change.

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
- [ ] Full repository gates pass on the rebased, reviewed tree.
- [ ] One cumulative base-guarded review at the checkpoint or PR boundary.
