# GitHub Workflows Overview

This document describes the Claude-powered GitHub workflows for autonomous issue implementation.

## Design Principles

1. **Trust Claude to be smart** - Keep workflow YAML simple, let Claude figure out context
2. **Epic as source of truth** - All project state lives in the epic issue
3. **Serialized implementation, durable queue** - Main-mutating work runs one
   at a time via the `claude-impl` lock; requests are queued in labels so none
   are ever silently dropped. Read-only workflows run in their own per-event
   groups and never block implementation.
4. **Dependencies checked at runtime** - Claude reads "Blocked by:" and refuses if blockers open
5. **Never lose work silently** - Always leave a trail (status comments, branches, PRs)
6. **Fresh context breaks bias** - Second opinion reviews catch issues original implementer missed
7. **Protect specs from cheating** - Implementation matches spec, not vice versa

## Workflow Summary

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `claude-code-review.yml` | PR events, `claude-review` label | Review PR code, detect protected file changes |
| `claude-auto-triage.yml` | After code-review completes | Triage review findings |
| `claude-issue-review.yml` | `needs-review` label | Review issue, add `ready-for-implementation` |
| `claude-issue-enqueue.yml` | `@claude` + `ready-for-implementation` | Validate request, add `impl:queued` (durable queue entry) |
| `claude-issue.yml` | `impl:queued` label / schedule / dispatch | **Serialized runner**: drains the queue one issue at a time, implements with mandatory status |
| `claude-pr-fix.yml` | `@claude` on PR | Fix PR issues (max 3 attempts) |
| `claude-second-opinion.yml` | `needs-second-opinion` label | Fresh context review after failed fixes |
| `claude-epic-start.yml` | `status:active` on epic | Start epic by triggering first unblocked issue |
| `claude-epic-update.yml` | Issue closed with `epic:*` label | Update epic checkboxes |
| `claude-blocker-resolved.yml` | Issue closed | Add `needs-review` to unblocked issues |
| `claude-stale-check.yml` | Every 2 hours (scheduled) | Detect stuck implementations |
| `claude-batch-fix.yml` | Manual or 5+ `quick-fix` issues | Batch fix trivial issues |

## Workflow Interactions

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PR WORKFLOW                                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  PR Created ──► code-review.yml ──► auto-triage.yml                 │
│                      │                    │                          │
│                      │         ┌──────────┴──────────┐               │
│                      │         ▼                     ▼               │
│                      │    FIX_NOW               DEFER_ISSUE          │
│                      │   (posts @claude)       (creates issue)       │
│                      │         │                                     │
│                      │         ▼                                     │
│                      │   claude-pr-fix.yml                           │
│                      │         │                                     │
│                      │    ┌────┴────┐                                │
│                      │    ▼         ▼                                │
│                      │  Success   3 failures                         │
│                      │    │         │                                │
│                      │    │         ▼                                │
│                      │    │   second-opinion.yml                     │
│                      │    │         │                                │
│                      │    │    ┌────┴────┐                           │
│                      │    │    ▼         ▼                           │
│                      │    │  Fixed    Escalate                       │
│                      │    │    │    (needs-human-review)             │
│                      │    │    │                                     │
│                      │    ▼    ▼                                     │
│                      │   Auto-merge                                  │
│                      │                                               │
│    Protected files? ─┴──► spec-change-detected label                │
│                           (anti-cheating review)                     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                       ISSUE WORKFLOW                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Epic activated ──► epic-start.yml ──► Adds `needs-review`          │
│  (status:active)        │              to first unblocked issue      │
│                         │                       │                    │
│                         │                       ▼                    │
│                         │              issue-review.yml              │
│                         │                       │                    │
│                         │                       ▼                    │
│                         │           Adds `ready-for-implementation`  │
│                         │           + posts @claude trigger          │
│                         │                       │                    │
│                         │                       ▼                    │
│                         │               claude-issue.yml             │
│                         │                       │                    │
│                         │        ┌──────────────┼──────────────┐     │
│                         │        ▼              ▼              ▼     │
│                         │    SUCCESS       INCOMPLETE       BLOCKED  │
│                         │  (creates PR)  (posts status,  (removes    │
│                         │        │       needs-attention)  label)    │
│                         │        │              │                    │
│                         │        │              ▼                    │
│                         │        │      stale-check.yml              │
│                         │        │      (retries stale)              │
│                         │        │                                   │
│                         │        ▼                                   │
│                         │   PR merged                                │
│                         │        │                                   │
│                         │   ┌────┴────┐                              │
│                         │   ▼         ▼                              │
│                         │ epic-    blocker-resolved.yml              │
│                         │ update   (adds needs-review to             │
│                         │ .yml      next unblocked issue)            │
│                         │              │                             │
│                         └──────────────┘ (chains to next issue)      │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

## Robustness Features

### Timeout Handling

All Claude workflows have explicit timeouts to prevent runaway jobs:

| Workflow | Timeout |
|----------|---------|
| `claude-issue.yml` | 75 minutes |
| `claude-pr-fix.yml` | 30 minutes |
| `claude-second-opinion.yml` | 45 minutes |

If a workflow times out, the fallback status handler posts an INCOMPLETE status.

### Structured Automation State

State is stored in issue/PR body (not comments) using JSON metadata:

```markdown
## Automation State
<!-- automation-state: {"status":"INCOMPLETE","pr":123,"branch":"claude/45-feature","attempts":2} -->

| Field | Value |
|-------|-------|
| Status | `INCOMPLETE` |
| PR | #123 |
| Branch | `claude/45-feature` |
| Attempts | 2 |
```

**Why body instead of comments:**
- Comments can be deleted, breaking state tracking
- Body sections survive edits and are API-updatable
- Single source of truth per issue/PR

**PR fix tracking:**
```markdown
## Fix Automation State
<!-- fix-state: {"attempts":2} -->
Fix attempts: 2/3
```

If Claude doesn't update status, the workflow posts a fallback and adds `needs-attention`.

### Protected Files (Anti-Cheating)

Implementation PRs should rarely modify these files:

| Pattern | Purpose |
|---------|---------|
| `docs/specs/*.md` | Specifications (source of truth) |
| `docs/guidelines/*.md` | Process documentation |
| `.github/workflows/*.yml` | Automation workflows |
| `.credo.exs`, `.formatter.exs` | Linter/formatter configs |

When protected files change:
1. `spec-change-detected` label is added
2. Code review checks if changes are **LEGITIMATE** (real spec gap) or **AVOIDANCE** (cheating)
3. Signs of avoidance:
   - Spec weakens requirements to match buggy implementation
   - Spec adds exceptions for unhandled edge cases
   - Linter rules disabled instead of fixing code

### Scope Guards

Implementation stops for scope creep (principle-based, not hard thresholds):

**Signs of scope creep:**
- Changes spanning multiple unrelated modules or subsystems
- Discovering substantial prerequisite work not in the issue
- Implementation feels like 2-3 separate issues bundled together
- Non-mechanical changes touching areas unrelated to the issue's focus

**NOT scope creep (proceed normally):**
- Mechanical changes across many files (renames, import updates, type fixes)
- Related changes that naturally flow from the core implementation
- Test files matching the implementation scope

When stopping:
1. Posts INCOMPLETE status
2. Adds `needs-breakdown` and explains how to split
3. If discovered blocker: creates issue, updates "Blocked by:" section

### Fix Attempt Tracking

PR fixes track attempts via structured state in PR body (not comment counting):
- Attempt counter stored in `<!-- fix-state: {"attempts":N} -->`
- After 3 attempts → escalate to `needs-second-opinion`
- Second opinion uses fresh Claude context (no sunk cost bias)
- If second opinion also fails → escalate to `needs-human-review` (terminal state)

**Escalation chain:**
```
fix attempt 1 → fix attempt 2 → fix attempt 3 → second opinion → human review
```

### Duplicate PR Detection

Before creating a new PR, implementation checks for existing PRs:
```bash
gh pr list --head "claude/${issue_number}-" --state open
```

If a PR exists:
- Updates existing PR instead of creating duplicate
- Pushes to existing branch
- Posts comment noting continued work

### TODO/Skip Tag Protocol

All TODOs, FIXMEs, and skipped tests MUST reference a GitHub issue.

**Required format:**
```elixir
# TODO(#123): Explanation of what needs to be done
# FIXME(#123): Explanation of the bug

@tag :skip  # Skipped: #123 - reason why test is skipped

# credo:disable-for-next-line Credo.Check.Name - #123
```

**Before adding a TODO:**
1. Search for existing issues: `gh issue list --search "keyword" --state open`
2. If none exists, create one with `tech-debt` and `from-pr-review` labels
3. Reference the issue number in the code

**Code review enforcement:**
- PRs with unreferenced TODOs are flagged as "MUST FIX"
- Pattern checked: `TODO` without `(#\d+)`, `@tag :skip` without `#\d+`

**Why this matters:**
- Prevents untracked technical debt
- Enables prioritization via issue labels
- Avoids duplicate issues for same problem
- Creates audit trail of when/why debt was introduced

### Discovered Blocker Protocol

When implementation discovers prerequisite work:

```
1. STOP - don't try to fix it in the same PR
2. Create issue with `discovered-blocker` AND `needs-review` labels
3. Update current issue's "Blocked by:" section
4. Remove `ready-for-implementation` from current issue
5. Post BLOCKED status
6. Blocker gets reviewed and implemented (has needs-review)
7. blocker-resolved.yml adds needs-review to current issue when blocker closes
```

### Stale Detection & Self-Healing

`claude-stale-check.yml` runs every 2 hours with a hybrid bash + Claude approach:

**Detection (bash, always runs, no concurrency group):**
- Epic issues with no labels but all blockers resolved
- Issues with `needs-review` but no review activity after 2 hours
- Issues with `ready-for-implementation` but no PR/status after 2 hours
- Closed issues still carrying `impl:queued` or `impl:running`
- Stale open `impl:running` issues with a recorded workflow run claim
- Adds `needs-attention` label for visibility
- Cancels only a recorded stale run ID validated against GitHub run metadata;
  it never guesses from labels or trusts issue-body metadata alone

**Claude fix (only if issues detected):**
- Gets the list of stuck issues from detection
- Reads `docs/guidelines/github-workflows.md` to understand the system
- Figures out what's wrong and fixes it (add labels, fix issue bodies, re-trigger)
- Uses the `claude-impl` concurrency group (serialized with the issue runner)

**Orphan recovery (parallel, no Claude):**
- Detects `claude/*` branches without PRs → creates draft PRs
- Logs stuck PRs with `needs-human-review` for 24+ hours

This design ensures visibility (`needs-attention` label) even if Claude can't run.
The non-Claude detector may remove stale queue labels and cancel recorded
workflow runs, but it never pushes branches or creates implementation PRs.

## Epic-Driven Development

### Epic Issue Structure

The epic issue is the single source of truth for project progress:

```markdown
# [Epic Name] Implementation

## Specification Documents
- [Primary Spec](docs/specs/spec.md)

## Progress

### Phase 1: [Phase Name]
- [ ] #123 - Task description
- [ ] #124 - Another task
- [x] #125 - Completed task

### Phase 2: [Phase Name]
- [ ] #126 - Blocked by #123
...

## Discovered Issues
- #130 - Found during implementation of #124
```

**Required labels on epic:** `type:epic`, `status:active`

**Labels on issues in epic:** `epic:epic-name` (e.g., `epic:message-history`)

### Dependency Tracking

Issues track dependencies in their body:

```markdown
## Dependencies

- **Blocked by:** #123, #124
- **Blocks:** #125, #126
```

**Parsing rules:**
- Only `#number` references in the "Blocked by:" line/section are considered blockers
- The parser stops at "Blocks:" or other sections to avoid false positives
- Self-references are ignored (issue can't block itself)

**Common pitfalls to avoid:**
- Don't put issue numbers in "Blocks:" that match the current issue (typos cause self-blocking)
- Don't reference PRs or closed issues in prose near "Blocked by:" (may be parsed as blockers)
- Keep "Blocked by:" and "Blocks:" sections clearly separated

The implementation workflow:
1. Reads "Blocked by:" section (stops at "Blocks:" or next heading)
2. Skips self-references
3. Checks if each blocker is closed
4. If any blocker is open: posts BLOCKED status, removes label, stops
5. When blocker closes: `blocker-resolved.yml` re-enables dependent issues

## Labels Reference

### Label Priority (Conflict Resolution)

When multiple labels are present, this priority order applies:

| Priority | Label | Effect |
|----------|-------|--------|
| 1 (highest) | `needs-human-review` | **Stops all automation immediately** |
| 2 | `do-not-auto-merge` | Prevents merge but allows fixes |
| 3 | `needs-second-opinion` | Escalates to fresh context review |
| 4 | `needs-attention` | Flags for retry/investigation |
| 5 (lowest) | `ready-for-implementation` | Enables automation |

**Example:** If an issue has both `ready-for-implementation` and `needs-human-review`,
automation will NOT proceed because `needs-human-review` has higher priority.

### Trigger Labels
| Label | Purpose |
|-------|---------|
| `needs-review` | Triggers issue review workflow |
| `ready-for-implementation` | Security gate for implementation |
| `claude-review` | Triggers PR review |
| `claude-approved` | Security gate for PR fixes (non-maintainer) |

### Implementation Queue Labels
| Label | Purpose |
|-------|---------|
| `impl:queued` | Durable queue entry — issue is waiting for the serialized runner. Added by `claude-issue-enqueue.yml`. |
| `impl:running` | The runner has claimed this issue and is implementing it. Prevents double-processing; removed when the run finishes (even on failure). |

### Epic Labels
| Label | Purpose |
|-------|---------|
| `type:epic` | Issue is an epic |
| `status:active` | Currently active epic (only one at a time) |
| `epic:*` | Links issue to specific epic (e.g., `epic:message-history`) |

### Status Labels
| Label | Purpose |
|-------|---------|
| `needs-human-review` | Automation stopped, human must intervene |
| `needs-attention` | Stale or interrupted, needs retry |
| `needs-second-opinion` | Triggers fresh context review |
| `needs-clarification` | Issue needs more details |
| `needs-breakdown` | Issue too large, needs splitting |
| `do-not-auto-merge` | Prevents auto-merge |
| `ready-to-merge` | Triage approved, ready for merge |
| `merge-conflict` | PR has merge conflicts |
| `spec-change-detected` | PR modifies spec files (review carefully) |

### Issue Type Labels
| Label | Purpose |
|-------|---------|
| `from-pr-review` | Issue created from PR review |
| `discovered-blocker` | Found during implementation, blocks another issue |
| `quick-fix` | Trivial fix, batched by batch-fix workflow |
| `tech-debt` | Technical debt tracked via TODO/FIXME in code |

## Concurrency Control

> **Why not one shared group?** A single global `claude-automation` group was
> the original design, but it has a fatal flaw: by default, a GitHub concurrency
> group holds at most **one running + one pending** run. When several workflows
> fire at once, the newest waiting request **evicts and cancels** the older
> pending one. GitHub now supports larger concurrency queues with `queue: max`,
> but labels remain the durable source of implementation state. Read-only
> reviews competing in the same group could still starve implementation work,
> and a burst of `@claude` requests could silently drop work on older default
> queues. (This stranded issue #1039.) The current design replaces the single
> group with a durable queue plus purpose-scoped groups.

### Durable implementation queue

Issue implementation is split into an **enqueue** front door and a
**serialized runner**:

- `claude-issue-enqueue.yml` (per-issue group `claude-enqueue-<n>`, never
  blocked) validates the `@claude` request and adds the **`impl:queued`**
  label. The label *is* the queue entry — durable state that survives even if
  GitHub drops a pending run.
- `claude-issue.yml` is the runner. It holds the global `claude-impl` lock,
  picks the oldest `impl:queued` issue, flips it to `impl:running`, implements
  it, then releases the label and re-dispatches itself if the queue is
  non-empty. Triggers: the `labeled` event (fast path), a `*/10` schedule
  (backstop so the queue can never stall), and `workflow_dispatch`. When an
  issue is claimed, the runner records the workflow `run_id`, attempt, run URL,
  and claim time in the issue body so watchdog cleanup can target only that run.

This guarantees **both** invariants the single group could not:
- **Never parallel** — `claude-impl` (size 1) lets only one main-mutating run
  execute at a time.
- **Never dropped** — requests live in labels, not in GitHub's single pending
  slot, so a burst is drained in order rather than cancelled.

### Concurrency groups by purpose

| Group | Workflows | `cancel-in-progress` | Rationale |
|-------|-----------|----------------------|-----------|
| `claude-impl` | `claude-issue.yml` (runner), `claude-batch-fix.yml`, `claude-stale-check.yml` | `false` | All branch off `main` / open PRs → strictly serialized so they never produce conflicting changes. |
| `claude-enqueue-<issue>` | `claude-issue-enqueue.yml` | `false` | Cheap, idempotent; per-issue so it's never evicted and only collapses duplicate `@claude` comments on the same issue. |
| `claude-pr-<pr>` | `claude-pr-fix.yml`, `claude-second-opinion.yml` | `false` | Push to a PR's *own* branch, not `main`; serialized per-PR but parallel across different PRs. |
| `claude-review-pr-<pr>` | `claude-code-review.yml` | `true` | Read-only; a newer push supersedes an in-flight review. |
| `claude-review-triage-<runid>` | `claude-auto-triage.yml` | `false` | Read-only; keyed to the triggering review run. |
| `claude-review-issue-<issue>` | `claude-issue-review.yml` | `false` | Read-only; per-issue. |
| `claude-epic-<issue>` | `claude-epic-update.yml` | `false` | Edits the epic issue, not `main`; per-trigger. |

Read-only workflows are deliberately **outside** `claude-impl` so they can
never block or evict implementation work.

This ensures:
- Only one main-mutating Claude operation runs at a time (`claude-impl`)
- No race conditions on `main`; no conflicting branches/PRs
- Implementation requests queue durably in labels instead of being cancelled

## Security Gates

### For Public Repository Safety

1. **PRs**: Maintainer must add `claude-review` label
2. **PR fixes**: Requires `claude-approved` label (or be maintainer)
3. **Issue implementation**: Requires `ready-for-implementation` label

### Loop Prevention

- PR fixes max 3 attempts before escalating to second opinion
- Second opinion max 1 attempt before escalating to human (terminal state)
- `needs-human-review` label stops all automation
- Concurrency group prevents parallel execution
- Stale check runs on schedule, not on every event
- Structured state in body prevents counter manipulation via comment deletion

**Terminal states (require human intervention):**
- `needs-human-review` label present
- Second opinion already attempted (marked in PR body)

## Recovery Procedures

### Issue Stuck Without Status

```bash
# Check recent workflow runs
gh run list --workflow=claude-issue.yml --limit 5

# Manually trigger retry
gh issue comment ISSUE_NUMBER --body "@claude Please implement this issue."
```

### PR Stuck in Fix Loop

```bash
# Check attempt count
gh pr view PR_NUMBER --json comments \
  --jq '[.comments[] | select(.body | test("@claude.*fix"; "i"))] | length'

# Trigger second opinion manually
gh pr edit PR_NUMBER --add-label "needs-second-opinion"
```

### Orphan Branch Recovery

```bash
# List claude branches without PRs
for branch in $(git branch -r | grep 'origin/claude/'); do
  gh pr list --head "${branch#origin/}" --state open --json number | jq -e '.[0]' || echo "Orphan: $branch"
done

# Stale check will auto-create draft PRs, or manually:
gh pr create --head "claude/123-feature" --draft --title "[Draft] Recovered #123"
```

### Inspect / Drain the Implementation Queue

The implementation queue lives in labels, not in GitHub's pending-run slot:

```bash
# What's waiting and what's in flight
gh issue list --label "impl:queued"  --state open
gh issue list --label "impl:running" --state open

# Manually kick the runner (e.g. if the schedule backstop hasn't fired yet)
gh workflow run claude-issue.yml
```

If a run crashed and left an issue stuck as `impl:running` (the runner clears
this even on failure, so this is rare), free it manually:

```bash
gh issue edit ISSUE_NUMBER --remove-label "impl:running" --add-label "impl:queued"
gh workflow run claude-issue.yml
```

If jobs are stuck running:
```bash
# Prefer the recorded run ID in the issue's Automation Claim.
gh issue view ISSUE_NUMBER --json body --jq '.body'
gh run cancel RUN_ID
```

For closed issues, do not requeue. Remove stale queue labels after cancelling
any recorded active run:

```bash
gh issue edit ISSUE_NUMBER --remove-label "impl:running" --remove-label "impl:queued"
```

## Fork PR Handling

Fork PRs have limited automation:
1. **code-review.yml** - Works normally (read-only)
2. **auto-triage.yml** - Creates issues instead of `@claude` fix comments
3. **claude-pr-fix.yml** - Posts explanation and skips (cannot push to forks)

## Secrets Required

| Secret | Purpose |
|--------|---------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude API authentication |
| `PAT_WORKFLOW_TRIGGER` | Enable bot comments to trigger workflows |

Without `PAT_WORKFLOW_TRIGGER`, bot-created comments won't trigger other workflows.

## Quick Reference: Starting Work on an Epic

1. **Create epic issue** with `type:epic` label
2. **Create all issues** from roadmap with:
   - `epic:your-epic-name` label
   - "Blocked by: #X, #Y" section in body
   - Clear acceptance criteria
3. **Add `status:active`** label to the epic
4. **Automation takes over**:
   - `epic-start.yml` adds `needs-review` to first unblocked issue
   - Review → implement → PR → merge
   - `blocker-resolved.yml` adds `needs-review` to next unblocked issue
   - Chain continues until all issues complete

## Edge Case Handling

### Circular Dependencies

If A blocks B and B blocks A:
- Issue review should detect and add `needs-clarification`
- Requires human to break the cycle

### Reopened Blockers

If a blocker is reopened after dependent issue started:
- Next implementation check will detect and post BLOCKED status
- Dependent issue waits for blocker to close again

### Multiple Active Epics

Only one epic should have `status:active` at a time.
If multiple exist, epic-update may update the wrong one.

### Spec Changes During Implementation

If spec is edited after `ready-for-implementation` added:
- Implementation uses the new spec version
- For major changes, remove label and re-review
