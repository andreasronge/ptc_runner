# GitHub Workflows Overview

This document describes the Claude-powered GitHub workflows and their security gates.

## Workflow Summary

| Workflow | Trigger | Gate | Purpose |
|----------|---------|------|---------|
| `claude-code-review.yml` | PR labeled/synchronized | `claude-review` label | Automated PR review |
| `claude-auto-triage.yml` | After code-review completes | Inherits from code-review | Triage review findings |
| `claude.yml` | `@claude` mention | Actor or `claude-approved` label | Execute requested work |
| `claude-issue-review.yml` | Issue labeled | `needs-review` label | Review issue specifications |
| `claude-pm.yml` | PR merged, issue labeled, manual | Both labels required | Orchestrate implementation |

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
