# GitHub Workflows Overview

This document describes the Claude-powered GitHub workflows and their security gates.

## Workflow Summary

| Workflow | Trigger | Gate | Purpose |
|----------|---------|------|---------|
| `claude-code-review.yml` | PR labeled/synchronized | `claude-review` label | Automated PR review |
| `claude-auto-triage.yml` | After code-review completes | Inherits from code-review | Triage review findings |
| `claude.yml` | `@claude` mention | Actor or `claude-approved` label | Execute requested work |
| `claude-issue-review.yml` | Issue labeled | `needs-review` label | Review issue specifications |
| `claude-pm.yml` | PR merged, issue labeled, manual | Both labels required | Create issues from specs, orchestrate implementation |

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
│                                              │                  │
│                                              ▼                  │
│                              Maintainer adds `claude-approved`  │
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

The PM workflow (`claude-pm.yml`) orchestrates issue creation and implementation. It runs the `/pm-workflow` Claude command.

**Full details**: See `.claude/commands/pm-workflow.md` for:
- Phase structure and specification documents
- Decision framework and safety rules

**Key behaviors**:
- Creates ONE issue at a time from specification documents
- Issues are auto-added to GitHub Project when labeled (`enhancement`, `bug`, `tech-debt`)
- Phase tracking uses labels (`phase:*`), not project fields
- Triggers implementation only when issue has BOTH `ready-for-implementation` AND `claude-approved`

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

All workflows require explicit maintainer approval before Claude can act:

1. **PRs**: Maintainer must add `claude-review` label
2. **Issues/PRs with @claude**: Requires `claude-approved` label (or be the maintainer)
3. **Implementation**: Requires BOTH `ready-for-implementation` AND `claude-approved`

### Loop Prevention

- **Bot check**: claude.yml ignores bot-authored comments/reviews to prevent self-triggering
- **Cycle limit**: auto-triage.yml tracks cycles with labels, stops after 3 cycles
- **Human intervention**: Adds `needs-human-review` label when max cycles reached

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

### Phase Labels (PTC-Lisp Implementation)
- `phase:api-refactor` - API namespace refactoring (Phase 0)
- `phase:parser` - PTC-Lisp parser implementation (Phase 1)
- `phase:analyzer` - PTC-Lisp analyzer implementation (Phase 2)
- `phase:eval` - PTC-Lisp interpreter implementation (Phase 3)
- `phase:integration` - End-to-end integration (Phase 4)
- `phase:polish` - Polish & cleanup, deferred issue review (Phase 5)
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
