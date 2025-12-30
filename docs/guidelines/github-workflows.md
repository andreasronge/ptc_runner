# GitHub Workflows Overview

This document describes the Claude-powered GitHub workflows and their security gates.

## Workflow Summary

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `claude-code-review.yml` | PR by `claude[bot]`, `claude/*` branch, or `claude-review` label | Automated PR review |
| `claude-auto-triage.yml` | After code-review completes | Triage review findings |
| `claude-issue.yml` | `@claude` in issue + `ready-for-implementation` label | Implement issues |
| `claude-pr-fix.yml` | `@claude` in PR + `claude-approved` label | Fix PRs |
| `claude-issue-review.yml` | `needs-review` label | Review issue, trigger implementation |
| `claude-implementation-feedback.yml` | Feedback labels | Handle implementation feedback |
| `claude-pm.yml` | Schedule (6h), PR merged, issue events | Keep project moving |

## Workflow Interactions

```
┌─────────────────────────────────────────────────────────────────┐
│                        PR WORKFLOW                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  PR Created ──► Maintainer adds ──► code-review.yml             │
│                 `claude-review`          │                      │
│                                          ▼                      │
│                                    auto-triage.yml              │
│                                          │                      │
│                              ┌───────────┴───────────┐          │
│                              ▼                       ▼          │
│                         FIX_NOW               DEFER_ISSUE       │
│                     (posts @claude)        (creates issue)      │
│                              │                                  │
│                              ▼                                  │
│                     claude-pr-fix.yml ──► pushes fix            │
│                              │                                  │
│                              ▼                                  │
│                    (loop max 3 cycles)                          │
│                              │                                  │
│                              ▼                                  │
│                        Auto-merge                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                       ISSUE WORKFLOW                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Issue Created ──► Maintainer adds ──► issue-review.yml         │
│       or              `needs-review`         │                  │
│  PM queues it                                ▼                  │
│                                   Adds `ready-for-implementation`
│                                   + posts @claude trigger       │
│                                              │                  │
│                                              ▼                  │
│                                      claude-issue.yml           │
│                                              │                  │
│                              ┌───────────────┴───────────────┐  │
│                              ▼                               ▼  │
│                         SUCCESS                          FEEDBACK│
│                       (creates PR)                    (too big, │
│                                                      edge case, │
│                                                       blocked)  │
│                                                          │      │
│                                                          ▼      │
│                                         implementation-feedback.yml
│                                                          │      │
│                              ┌───────────────────────────┴──┐   │
│                              ▼                              ▼   │
│                       needs-breakdown              edge-case or │
│                      (creates sub-issues)           blocked     │
│                              │                     (updates issue)
│                              ▼                              │   │
│                      Sub-issues get                         ▼   │
│                      `needs-review`              Back to review │
│                                                  or maintainer  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## PM Workflow

The PM workflow (`claude-pm.yml`) keeps the project moving by handling tech debt, stuck reviews, and epic progress.

**Triggers**: Schedule (every 6h), PR merged, issue closed, labels (`from-pr-review`, `needs-clarification`, `needs-breakdown`, `ready-for-implementation`)

**Priorities**: Tech debt (`from-pr-review`) → stuck reviews → next epic task

**Details**: See `.claude/commands/pm-workflow.md`

### Epic Issue Pattern

The PM workflow reads from a human-created "epic issue" to understand what work needs to be done:

```markdown
# [Epic Name] Implementation

## Specification Documents
- [Primary Spec](docs/spec.md) - Main implementation guide

## Progress

### Phase 1: [Phase Name]
- [ ] #123 - [Linked issue title]
- [ ] Create parser module (PM will create issue)
- [x] #124 - [Completed] (closed via #PR-456)

### Phase 2: [Phase Name]
- [ ] Next phase tasks...

## Notes
[Special instructions for PM, blockers]
```

**Epic identification**: Labels `type:epic` + `status:active` (only one epic should be active at a time)

### Key Behaviors

- **Epic as source of truth**: PM reads epic body to find spec docs, tasks, and progress
- **Creates ONE issue at a time**: From unchecked text items in the epic
- **Queues issues for review**: Adds `needs-review` label to linked issues without `ready-for-implementation`
- **Updates epic on progress**: Links new issues, marks checkboxes when closed
- **Monitors tech debt**: Handles `from-pr-review` issues regardless of epic
- **Skips if PR open**: Prevents concurrent work

**Note**: PM no longer triggers implementation. The review workflow posts `@claude` directly after approval.

**GitHub Project**: [PTC-Lisp Implementation](https://github.com/users/andreasronge/projects/1)

## Implementation Feedback Workflow

The implementation workflow (`claude-issue.yml`) includes a **feedback protocol** for handling issues that are too large or have unexpected complications.

### Feedback Types

| Label | Meaning | Feedback Workflow Action |
|-------|---------|--------------------------|
| `needs-breakdown` | Issue scope too large (>30 test changes, >5 files) | Creates sub-issues, marks parent as tracking issue |
| `implementation-blocked` | Missing info, unclear requirements, blocking dependency | Updates issue with blocker details, adds `needs-maintainer-input` |
| `edge-case-found` | Discovered scenarios not in acceptance criteria | Updates issue with edge cases, may re-trigger implementation |

### How It Works

1. **Scope Assessment**: Before implementing, Claude assesses scope and complexity
2. **Feedback Decision**: If thresholds exceeded or blockers found, uses feedback protocol instead of implementing
3. **Label Update**: Removes `ready-for-implementation`, adds appropriate feedback label
4. **Structured Comment**: Posts detailed feedback comment with analysis
5. **Feedback Workflow**: `claude-implementation-feedback.yml` triggers and handles the feedback:
   - **needs-breakdown**: Creates sub-issues from suggested breakdown, updates parent
   - **implementation-blocked**: Documents blocker, requests maintainer input
   - **edge-case-found**: Documents edge cases, may auto-resolve and re-trigger

### Thresholds

The implementation workflow uses these thresholds to trigger feedback:
- More than ~30 test assertion changes
- More than ~5 files need modification
- Missing dependencies or unclear requirements
- Edge cases not addressed in acceptance criteria

### Recovery

After feedback is handled:
- **Sub-issues**: Each gets `needs-review` label, goes through normal review process
- **Blocked issues**: Wait for maintainer to provide info, then manually add `needs-review`
- **Edge cases resolved**: Workflow may automatically re-trigger implementation

## Closing Issues

### Completed (Done)
When an issue is implemented via PR merge, it's automatically closed as "completed":
```bash
# Usually automatic, but manual if needed:
gh issue close ISSUE_NUMBER
```

### Not Planned (Declined)
When deciding not to implement an issue:
```bash
# Close with "not planned" reason (shows gray icon in GitHub)
gh issue close ISSUE_NUMBER --reason "not planned"

# Add a label documenting why
gh issue edit ISSUE_NUMBER --add-label "wontfix"  # or duplicate, out-of-scope, deferred, superseded

# Add explanatory comment
gh issue comment ISSUE_NUMBER --body "Closing: [explanation of why this won't be done]"
```

## Security Gates

### For Public Repository Safety

Most workflows require explicit maintainer approval before Claude can act:

1. **PRs**: Maintainer must add `claude-review` label
2. **PR fixes with @claude**: Requires `claude-approved` label (or be the maintainer)
3. **Issue implementation**: Requires `ready-for-implementation` label (added by review workflow)

### Loop Prevention

- **Label gates**: `ready-for-implementation` for issues, `claude-approved` for PRs (prevents unauthorized automation)
- **Cycle limit**: auto-triage.yml tracks cycles with labels, stops after 3 cycles
- **Human intervention**: Adds `needs-human-review` label when max cycles reached

### Stuck State & Recovery

**When a PR gets stuck (max triage cycles):**
1. Triage adds `needs-human-review` label and posts explanation comment
2. Subsequent triage runs skip immediately (label check)
3. PM workflow detects open PR and skips creating new work
4. System is effectively **paused** until human intervenes

**When PM workflow gets stuck:**
1. PM adds `needs-human-review` label after 3 failed attempts
2. Remove label manually to resume

**Recovery**: Remove `needs-human-review` label to re-enable automation, or manually fix/close the issue/PR.

### Concurrency Control

All Claude workflows share one concurrency group: `claude-automation` (queue, no cancel).

This ensures only one Claude workflow runs at a time, preventing parallel Claude Code installations and race conditions.

## Labels Reference

### Trigger Labels
- `claude-review` - Triggers PR review
- `needs-review` - Triggers issue review
- `ready-for-implementation` - Security gate for issue implementation (added by review)
- `claude-approved` - Security gate for PR fixes (for non-maintainer triggers)

### Epic Labels
- `type:epic` - Issue is an epic (contains task list for PM to follow)
- `status:active` - Currently active epic (only one at a time)

### Phase Labels (Optional)
Phase labels can be used to categorize issues, but are not required for the PM workflow (which uses the epic for tracking):
- `phase:api-refactor` - API namespace refactoring
- `phase:parser` - PTC-Lisp parser implementation
- `phase:analyzer` - PTC-Lisp analyzer implementation
- `phase:eval` - PTC-Lisp interpreter implementation
- `phase:integration` - End-to-end integration
- `phase:polish` - Polish & cleanup
- `ptc-lisp` - General PTC-Lisp language work

### Status Labels
- `merge-conflict` - PR has merge conflicts (auto-removed when resolved)
- `auto-triage-pending` - Triage in progress
- `auto-triage-complete` - Triage finished
- `auto-triage-cycle-N` - Tracks triage iterations (1-3)
- `needs-human-review` - Max cycles reached, human must intervene
- `do-not-auto-merge` - Prevents auto-merge
- `ready-to-merge` - Triage approved, ready for auto-merge

### Implementation Feedback Labels
- `needs-breakdown` - Issue too large, needs to be split into sub-issues
- `implementation-blocked` - Blocker found during implementation attempt
- `edge-case-found` - Edge cases discovered not in acceptance criteria
- `needs-maintainer-input` - Waiting for maintainer decision/info
- `tracking-issue` - Parent issue with linked sub-issues

### Classification Labels
- `from-pr-review` - Issue created from PR review findings
- `pm-stuck` - PM workflow encountered unrecoverable error
- `pm-failed-attempt` - PM attempt failed

### Declined Issue Labels
When closing an issue as "not planned", add one of these labels to document why:
- `wontfix` - Decision not to address (low value, against project direction)
- `duplicate` - Duplicate of another issue (reference the original in comment)
- `out-of-scope` - Outside current project goals
- `deferred` - Postponed indefinitely (may revisit later)
- `superseded` - Replaced by a different approach (reference new issue/PR)

## Fork PR Handling

Fork PRs have limited automation:

1. **code-review.yml** - Works normally (read-only)
2. **auto-triage.yml** - Creates issues instead of @claude fix comments
3. **claude-pr-fix.yml** - Posts explanation and skips (cannot push to forks)

Contributors must apply fixes manually based on created issues.

## Secrets Required

- `CLAUDE_CODE_OAUTH_TOKEN` - Claude API authentication
- `PAT_WORKFLOW_TRIGGER` - Personal Access Token to trigger workflows from bot actions

Without `PAT_WORKFLOW_TRIGGER`, bot-created comments won't trigger other workflows.
