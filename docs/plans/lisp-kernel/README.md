# Lisp Kernel Exploration

The Lisp kernel is an active experiment, not a committed product roadmap.

- [`roadmap.md`](roadmap.md) is the lightweight discussion guide and current
  set of questions.
- [`kernel-contract.md`](kernel-contract.md) is the proposed normative V1
  contract for the small programmable Kernel.
- [`kernel-migration.md`](kernel-migration.md) defines the implementation,
  cutover, testing, and deletion sequence.
- [`kernel-inventory.md`](kernel-inventory.md) is the temporary
  retain/migrate/delete checklist.
- [`tracelog-contract.md`](tracelog-contract.md) defines retained TraceLog
  storage, source grants, run discovery/metadata, bounded queries, and the
  swappable `log/` prelude.
- [`private-experiment-transcripts.md`](private-experiment-transcripts.md)
  describes the approved local transcript work and its `ptc_viewer` contract.
- [`archive/`](archive/README.md) preserves the former architecture, milestone,
  spike, autonomous-work, and experiment documents as historical reference.

Start with the discussion guide. Consult the archive when an old result or
design rationale is relevant; do not treat archived gates or task ordering as
current instructions.

## Parallel agent work

Keep this worktree on `exp/lisp-kernel` as the integration point. Give each
coding agent a sibling worktree, a unique branch, and a small non-overlapping
task:

```bash
base=$(git rev-parse exp/lisp-kernel)
git worktree add \
  -b agent/kernel-<topic> \
  ../ptc_runner-lisp-kernel-<topic> \
  "$base"
```

Tell the agent its goal, allowed files, files it must not touch, and focused
verification command. The agent should commit its result and return the commit
SHA, but should not push, rebase, merge, prune worktrees, or change shared Git
configuration. Review and cherry-pick accepted commits here, then run the
broader checks once after integration.

New worktrees do not contain ignored files. If an agent must test against a
real model, copy this worktree's `.env` into its worktree before starting it:

```bash
cp .env ../ptc_runner-lisp-kernel-<topic>/.env
```

The copied file contains credentials: use it only when needed and never commit
it. Keep each worktree's `_build`, `deps`, and Dialyzer PLT separate so
parallel Mix processes cannot corrupt shared build state.

After integrating or rejecting the work, remove the worktree and branch:

```bash
git worktree remove ../ptc_runner-lisp-kernel-<topic>
git branch -d agent/kernel-<topic>
```
