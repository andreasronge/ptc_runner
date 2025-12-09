# GitHub Workflows Overview

This document describes the Claude-powered GitHub workflows and their security gates.

## Workflow Summary

| Workflow | Trigger | Gate | Purpose |
|----------|---------|------|---------|
| `claude-code-review.yml` | PR opened/labeled/synchronized | `claude/*` branch or `claude-review` label | Automated PR review |
| `claude-auto-triage.yml` | After code-review completes | Inherits from code-review | Triage review findings |
| `claude.yml` | `@claude` mention | Actor or `claude-approved` label | Execute requested work |
| `claude-issue-review.yml` | Issue labeled | `needs-review` label | Review issue specifications |
| `claude-pm.yml` | PR merged, issue labeled, manual | `ready-for-implementation` label | Create issues from epic, orchestrate implementation |

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
│                         claude.yml ──► pushes fix                │
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
│                    `needs-review`            │                  │
│                                              ▼                  │
│                                   Adds `ready-for-implementation`
│                                   + `claude-approved` (both)    │
│                                              │                  │
│                                              ▼                  │
│                                         pm.yml                  │
│                                     (posts @claude)             │
│                                              │                  │
│                                              ▼                  │
│                                        claude.yml               │
│                                      (creates PR)               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## PM Workflow

The PM workflow (`claude-pm.yml`) orchestrates issue creation and implementation using an **Epic Issue** as the source of truth.

**Full details**: See `.claude/commands/pm-workflow.md` for:
- Epic-based workflow instructions
- Decision framework and safety rules

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
- **Updates epic on progress**: Links new issues, marks checkboxes when closed
- **Monitors tech debt**: Handles `from-pr-review` issues regardless of epic
- **Triggers implementation**: When issue has `ready-for-implementation` label
- **Skips if PR open**: Prevents concurrent work

**GitHub Project**: [PTC-Lisp Implementation](https://github.com/users/andreasronge/projects/1)

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
2. **Issues/PRs with @claude**: Requires `claude-approved` label (or be the maintainer)
3. **Implementation**: Issue review adds both `ready-for-implementation` AND `claude-approved` when approving

### Loop Prevention

- **Bot check**: claude.yml ignores bot-authored comments/reviews to prevent self-triggering
- **Cycle limit**: auto-triage.yml tracks cycles with labels, stops after 3 cycles
- **Human intervention**: Adds `needs-human-review` label when max cycles reached

### Stuck State & Recovery

**When a PR gets stuck (max triage cycles):**
1. Triage adds `needs-human-review` label and posts explanation comment
2. Subsequent triage runs skip immediately (label check)
3. PM workflow detects open PR and skips creating new work
4. System is effectively **paused** until human intervenes

**When PM workflow gets stuck:**
1. PM adds `pm-stuck` label to the issue
2. Subsequent PM runs detect stuck state and fail fast
3. Use `reset-stuck` action to clear and resume

**Recovery options:**

| Situation | Resolution |
|-----------|------------|
| PR stuck at cycle 3 | Remove `needs-human-review` label (re-enables automation), OR manually fix and merge, OR close PR |
| PM stuck | Run PM workflow manually with `reset-stuck` action, OR remove `pm-stuck`/`pm-failed-attempt` labels manually |

**Manual workflow dispatch:**
```bash
# Check PM status without taking action
gh workflow run claude-pm.yml -f action=status-only

# Reset stuck state and resume
gh workflow run claude-pm.yml -f action=reset-stuck
```

### Concurrency Control

| Workflow | Concurrency Group | Cancel In-Progress |
|----------|-------------------|-------------------|
| code-review | `claude-pr-{number}` | Yes |
| claude | `claude-pr-{number}` | No |
| auto-triage | `claude-triage-{branch}` | Yes |
| issue-review | `claude-issue-review-{number}` | Yes |
| pm | `claude-pm` | No |

## Labels Reference

### Trigger Labels
- `claude-review` - Triggers PR review
- `needs-review` - Triggers issue review
- `ready-for-implementation` - Marks issue as ready for PM
- `claude-approved` - Maintainer approval for Claude automation

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
3. **claude.yml** - Posts explanation and skips (cannot push to forks)

Contributors must apply fixes manually based on created issues.

## Secrets Required

- `CLAUDE_CODE_OAUTH_TOKEN` - Claude API authentication
- `PAT_WORKFLOW_TRIGGER` - Personal Access Token to trigger workflows from bot actions

Without `PAT_WORKFLOW_TRIGGER`, bot-created comments won't trigger other workflows.
