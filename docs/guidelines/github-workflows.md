# GitHub Workflows Overview

This document describes the Claude-powered GitHub workflows for autonomous issue implementation.

## Design Principles

1. **Trust Claude to be smart** - Keep workflow YAML simple, let Claude figure out context
2. **Epic as source of truth** - All project state lives in the epic issue
3. **Single concurrency group** - One Claude operation at a time, no race conditions
4. **Dependencies checked at runtime** - Claude reads "Blocked by:" and refuses if blockers open

## Workflow Summary

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `claude-code-review.yml` | PR events, `claude-review` label | Review PR code |
| `claude-auto-triage.yml` | After code-review completes | Triage review findings |
| `claude-issue-review.yml` | `needs-review` label | Review issue, add `ready-for-implementation` |
| `claude-issue.yml` | `@claude` + `ready-for-implementation` | Implement issues |
| `claude-pr-fix.yml` | `@claude` on PR | Fix PR issues |
| `claude-epic-update.yml` | Issue closed with `epic:*` label | Update epic checkboxes |
| `claude-batch-fix.yml` | Manual or 5+ `quick-fix` issues | Batch fix trivial issues |

## Workflow Interactions

```
┌─────────────────────────────────────────────────────────────────┐
│                        PR WORKFLOW                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  PR Created ──► code-review.yml ──► auto-triage.yml             │
│                                          │                      │
│                              ┌───────────┴───────────┐          │
│                              ▼                       ▼          │
│                         FIX_NOW               DEFER_ISSUE       │
│                     (posts @claude)        (creates issue)      │
│                              │                                  │
│                              ▼                                  │
│                     claude-pr-fix.yml                           │
│                              │                                  │
│                              ▼                                  │
│                        Auto-merge                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                       ISSUE WORKFLOW                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Issue Created ──► Add `needs-review` ──► issue-review.yml      │
│                          label                  │               │
│                                                 ▼               │
│                                     Adds `ready-for-implementation`
│                                     + posts @claude trigger     │
│                                                 │               │
│                                                 ▼               │
│                                         claude-issue.yml        │
│                                                 │               │
│                                    ┌────────────┴────────┐      │
│                                    ▼                     ▼      │
│                               SUCCESS               BLOCKED     │
│                             (creates PR)      (removes label,   │
│                                    │           posts comment)   │
│                                    ▼                            │
│                              PR merged                          │
│                                    │                            │
│                                    ▼                            │
│                          epic-update.yml                        │
│                        (checks epic box)                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

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
## Blocked by
- #123 - Must complete first
- #124 - Provides required API
```

The implementation workflow checks these at runtime:
1. Reads "Blocked by:" section
2. Checks if each blocker is closed
3. If any blocker is open: removes `ready-for-implementation`, posts comment, stops

### Workflow Behaviors

**Issue Review (`claude-issue-review.yml`):**
- Reads epic for context (if `epic:*` label present)
- Ensures "Blocked by:" section exists if dependencies mentioned
- Adds `ready-for-implementation` and posts `@claude` trigger

**Issue Implementation (`claude-issue.yml`):**
- Checks dependencies before implementing
- Reads epic for broader context
- Creates PR or reports blockers

**Epic Update (`claude-epic-update.yml`):**
- Triggers when issue with `epic:*` label closes
- Finds active epic and checks off the completed issue

## Labels Reference

### Trigger Labels
| Label | Purpose |
|-------|---------|
| `needs-review` | Triggers issue review workflow |
| `ready-for-implementation` | Security gate for implementation |
| `claude-review` | Triggers PR review |
| `claude-approved` | Security gate for PR fixes (non-maintainer) |

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
| `do-not-auto-merge` | Prevents auto-merge |
| `ready-to-merge` | Triage approved, ready for merge |
| `merge-conflict` | PR has merge conflicts |

### Issue Type Labels
| Label | Purpose |
|-------|---------|
| `from-pr-review` | Issue created from PR review |
| `quick-fix` | Trivial fix, batched by batch-fix workflow |
| `needs-clarification` | Issue needs more details |
| `needs-breakdown` | Issue too large, needs splitting |

## Concurrency Control

All Claude workflows share one concurrency group:

```yaml
concurrency:
  group: claude-automation
  cancel-in-progress: false
```

This ensures:
- Only one Claude operation runs at a time
- No race conditions on issues/PRs
- Jobs queue instead of being cancelled

## Security Gates

### For Public Repository Safety

1. **PRs**: Maintainer must add `claude-review` label
2. **PR fixes**: Requires `claude-approved` label (or be maintainer)
3. **Issue implementation**: Requires `ready-for-implementation` label

### Loop Prevention

- Auto-triage batches max 3 FIX_NOW items per run
- `needs-human-review` label stops all automation
- Concurrency group prevents parallel execution

### Recovery from Stuck States

**PR stuck:**
1. Check for `needs-human-review` label
2. Fix manually or remove label to retry

**Issue stuck:**
1. Check if blocked by open issues
2. Verify `ready-for-implementation` label is present
3. Manually post `@claude Please implement this issue.`

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

1. **Create epic issue** with `type:epic` and `status:active` labels
2. **Create all issues** from roadmap with:
   - `epic:your-epic-name` label
   - "Blocked by: #X, #Y" section in body
   - Clear acceptance criteria
3. **Add `needs-review`** to the first unblocked issue
4. **Automation takes over**: review → implement → PR → merge → next issue
