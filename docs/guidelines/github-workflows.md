# GitHub Workflows Overview

This document describes the Claude-powered GitHub workflows for autonomous issue implementation.

## Design Principles

1. **Trust Claude to be smart** - Keep workflow YAML simple, let Claude figure out context
2. **Epic as source of truth** - All project state lives in the epic issue
3. **Single concurrency group** - One Claude operation at a time, no race conditions
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
| `claude-issue.yml` | `@claude` + `ready-for-implementation` | Implement issues with mandatory status |
| `claude-pr-fix.yml` | `@claude` on PR | Fix PR issues (max 3 attempts) |
| `claude-second-opinion.yml` | `needs-second-opinion` label | Fresh context review after failed fixes |
| `claude-epic-update.yml` | Issue closed with `epic:*` label | Update epic checkboxes |
| `claude-blocker-resolved.yml` | Issue closed | Re-enable blocked issues |
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
│  Issue Created ──► Add `needs-review` ──► issue-review.yml          │
│                          label                  │                    │
│                                                 ▼                    │
│                                     Adds `ready-for-implementation`  │
│                                     + posts @claude trigger          │
│                                                 │                    │
│                                                 ▼                    │
│                                         claude-issue.yml             │
│                                                 │                    │
│                              ┌──────────────────┼──────────────────┐ │
│                              ▼                  ▼                  ▼ │
│                          SUCCESS           INCOMPLETE          BLOCKED│
│                        (creates PR)    (posts status,     (removes   │
│                              │          needs-attention)   label)    │
│                              │                  │                    │
│                              │                  ▼                    │
│                              │          stale-check.yml              │
│                              │          (retries stale)              │
│                              │                                       │
│                              ▼                                       │
│                         PR merged                                    │
│                              │                                       │
│                         ┌────┴────┐                                  │
│                         ▼         ▼                                  │
│                  epic-update.yml  blocker-resolved.yml               │
│                 (checks epic box) (re-enables dependents)            │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

## Robustness Features

### Mandatory Exit Status

Every implementation run MUST post a status comment, even on failure:

```markdown
<!-- claude-implementation-status -->
## Implementation Result: SUCCESS | INCOMPLETE | BLOCKED

**PR:** #123 | None created
**Branch:** `claude/45-feature-name` | None

### Work Completed
- [x] Read issue and spec
- [x] Checked dependencies
- [ ] Implementation complete
- [ ] Tests passing
- [ ] PR created

### Details
[What was done, what remains, blockers discovered]

### Suggested Next Steps
- [What needs to happen next]
```

If Claude doesn't post status, the workflow posts a fallback and adds `needs-attention`.

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

Implementation stops if:
- More than 10 files need changing (excluding tests)
- More than 500 lines would be added
- Discovered blocker not in "Blocked by:" section

When stopping:
1. Posts INCOMPLETE status
2. Adds `needs-breakdown` or creates blocker issue
3. Updates "Blocked by:" section if needed

### Fix Attempt Tracking

PR fixes track attempts via comment count:
- After 3 failed `@claude fix` attempts → escalate to `needs-second-opinion`
- Second opinion uses fresh Claude context (no sunk cost bias)
- Can try different approach or escalate to human

### Discovered Blocker Protocol

When implementation discovers prerequisite work:

```
1. STOP - don't try to fix it in the same PR
2. Create issue with `discovered-blocker` label
3. Update current issue's "Blocked by:" section
4. Remove `ready-for-implementation`
5. Post BLOCKED status
6. blocker-resolved.yml will re-enable when blocker closes
```

### Stale Detection

`claude-stale-check.yml` runs every 2 hours:
- Finds issues with `ready-for-implementation` but no PR/status after 2 hours
- Detects orphan `claude/*` branches without PRs (creates draft PR to capture work)
- Identifies stuck PRs with `needs-human-review` for 24+ hours

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

The implementation workflow:
1. Reads "Blocked by:" section
2. Checks if each blocker is closed
3. If any blocker is open: posts BLOCKED status, removes label, stops
4. When blocker closes: `blocker-resolved.yml` re-enables dependent issues

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

- PR fixes max 3 attempts before escalating to second opinion
- `needs-human-review` label stops all automation
- Concurrency group prevents parallel execution
- Stale check runs on schedule, not on every event

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

### Clear Concurrency Queue

If jobs are stuck:
```bash
# Cancel running workflows
gh run list --workflow=claude-issue.yml --status in_progress --json databaseId \
  | jq -r '.[].databaseId' | xargs -I {} gh run cancel {}
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

1. **Create epic issue** with `type:epic` and `status:active` labels
2. **Create all issues** from roadmap with:
   - `epic:your-epic-name` label
   - "Blocked by: #X, #Y" section in body
   - Clear acceptance criteria
3. **Add `needs-review`** to the first unblocked issue
4. **Automation takes over**: review → implement → PR → merge → next issue

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
