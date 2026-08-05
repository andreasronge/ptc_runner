# Coding agent review workflow

Use this workflow when a change requires an independent Codex review. Its goal
is to find substantive defects without repeatedly paying for cold reviews of
the same code. Review complements design, tests, Dialyzer, and repository
gates; it does not replace them.

## Define a reviewable slice

A slice changes one observable boundary and cuts over at least one production
caller. Delete the transitional path that caller no longer needs in the same
slice. Do not combine unrelated state machines merely to preserve a numbered
plan item or a one-commit label.

Before coding, write down:

- the observable change and explicit non-goals;
- the production caller that moves to the new boundary;
- each resource's creator, fixed owner, authorized user, and closer;
- behavior on success, ordinary error, caller death, worker death, owner death,
  deadline expiry, and an ambiguous call timeout;
- the absolute deadline used by each phase;
- which private values may enter process state, logs, diagnostics, and results;
  and
- the old entrypoint or lifecycle path deleted by the slice.

For concurrency-sensitive work, turn those cases into a fault matrix and write
the failing integration tests before implementation. Use monitors, controlled
suspension, and explicit acknowledgements. Do not use sleeps, tight timing as
synchronization, selective receives that can conceal message order, or a mock
wrapper when the real work executes in another owner.

Use a bounded `consult` or `challenge` before coding only when the slice creates
a new ownership or state-machine boundary. Ask a focused design question and
request concrete counterexamples; do not use an open-ended repository review
as a substitute for choosing the design.

## Stabilize the tree before review

Do not ask the independent reviewer to find formatter, generated-artifact,
Credo, or obvious type failures. Before the fresh review:

1. Format the changed files and compile with warnings as errors.
2. Run the focused tests, including the failure-path matrix.
3. Regenerate the semantic projection when identity-bearing source changes.
4. Run Credo and the relevant Dialyzer check when types or process boundaries
   change.
5. Run the documentation warning gate when user-facing or maintainer
   documentation changes.
6. Check `git diff --check`, the diff size, and untracked files.

Keep generators explicit. Do not make commit hooks mutate files; concurrent
worktrees and automations may be staging other changes.

If the implementation needs another owner, registry, ledger, or parallel
representation to close a review finding, reconsider the design before adding
it. After two successive systemic ownership or deadline findings, stop
patching clauses and shrink or redesign the slice from its fault matrix.

## Run one incremental review cycle

Run one fresh review when the complete draft is ready:

```bash
~/.codex/skills/codex-review/scripts/codex-independent-review review
```

Sanity-check the findings against the code. Batch related repairs and resume
the same session:

```bash
~/.codex/skills/codex-review/scripts/codex-independent-review followup \
  --session REVIEW_SESSION_ID
```

Repeat focused follow-ups only while that session has actionable findings. A
clean follow-up approves the incremental slice when:

- the fresh pass covered its complete original delta;
- later edits only addressed that session's findings;
- the base, scope, and reviewed bytes did not otherwise change; and
- relevant focused tests pass.

Commit and push that exact tree. Creating a commit object, amending only its
message, staging the already reviewed bytes, or pushing those bytes does not
justify another review. Do not run a separate working-tree, staged-tree,
exact-commit, and post-commit review for identical content.

Start a fresh review only when a rebase, unrelated edit, changed base, expanded
scope, or materially new design invalidates the previous pass. Run rebases
before starting a slice or at its checkpoint boundary, not midway through a
review cycle when avoidable.

## Verify and deliver

After the incremental review is clean, run the repository gates on the exact
reviewed tree:

```bash
mix precommit
MIX_ENV=dev mix docs --warnings-as-errors  # when documentation changed
```

If a gate requires a source or generated-artifact repair, make the repair and
return it to the same review session when it remains within that session's
scope. Start a fresh review only if the repair materially expands the slice.
An invocation error, such as allocating a TTY for a test that verifies detached
terminal behavior, is not a product defect; rerun the authoritative command in
the repository's expected environment.

Before declaring a branch or pull request ready, fetch and guard the target
base while running one cumulative review:

```bash
~/.codex/skills/codex-review/scripts/codex-independent-review review \
  --base origin/main --fetch-base
```

Batch cumulative findings and use that review session for focused follow-up.
Run another fresh cumulative review only if the base advances or the repair
materially expands the reviewed scope.

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
