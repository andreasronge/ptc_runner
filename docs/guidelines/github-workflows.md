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

## PM Workflow: Specification Document Registry

The PM workflow creates issues by reading from specification documents. It follows a phased approach:

### Phase Order (Strict Dependencies)

```
Phase 0: API Refactor (docs/api-refactor-plan.md)
    ↓ (must complete before any Lisp work)
Phase 1: Parser (docs/ptc-lisp-parser-plan.md)
    ↓
Phase 2: Analyzer (docs/ptc-lisp-analyze-plan.md)
    ↓
Phase 3: Eval (docs/ptc-lisp-eval-plan.md)
    ↓
Phase 4: Integration (docs/ptc-lisp-integration-spec.md)
    ↓
Phase 5: Polish & Cleanup (review deferred issues, final cleanup)
```

### Specification Documents

| Phase | Document | Issue Prefix |
|-------|----------|--------------|
| 0 | `docs/api-refactor-plan.md` | `[API Refactor]` |
| 1 | `docs/ptc-lisp-parser-plan.md` | `[Lisp Parser]` |
| 2 | `docs/ptc-lisp-analyze-plan.md` | `[Lisp Analyzer]` |
| 3 | `docs/ptc-lisp-eval-plan.md` | `[Lisp Eval]` |
| 4 | `docs/ptc-lisp-integration-spec.md` | `[Lisp Integration]` |
| 5 | (review deferred issues) | `[Polish]` |

### Reference Documents (Not for Issue Creation)

- `docs/ptc-lisp-specification.md` - Full language specification
- `docs/ptc-lisp-overview.md` - High-level rationale
- `docs/ptc-lisp-llm-guide.md` - LLM quick reference
- `docs/ptc-lisp-benchmark-report.md` - Phase 1 evaluation results

### How PM Creates Issues

1. **Determines current phase** by checking:
   - Code: Does `lib/ptc_runner/json/` exist? Does `lib/ptc_runner/lisp/parser.ex` exist?
   - Issues: What phase issues are open/closed?

2. **Reads the spec document** for the current phase

3. **Creates ONE issue** with:
   - Title: `[Phase Prefix] Description`
   - Labels: `enhancement`, `needs-review`, `phase:PHASE`, optionally `ptc-lisp`
   - Body following `issue-creation-guidelines.md` template

4. **Adds issue to GitHub Project** (#1) and sets Phase field

5. **Waits for review** via `claude-issue-review.yml`

6. **Triggers implementation** when issue has BOTH `ready-for-implementation` AND `claude-approved`
   - Updates project Status to "In Progress"

### GitHub Project Integration

**Project**: [PTC-Lisp Implementation](https://github.com/users/andreasronge/projects/1) (Number: 1)

| Field | Field ID | Purpose |
|-------|----------|---------|
| Status | `PVTSSF_lAHNGWjOASh0kM4OhOjl` | Track issue progress |
| Phase | `PVTSSF_lAHNGWjOASh0kM4OhOk_` | Track implementation phase |

**Phase Option IDs**:
| Phase | Option ID |
|-------|-----------|
| API Refactor | `a8c7193b` |
| Parser | `1c180ef6` |
| Analyzer | `9d857bc6` |
| Eval | `bbd1d60a` |
| Integration | `c5f6c3a5` |

**Status Option IDs**:
| Status | Option ID |
|--------|-----------|
| Todo | `f75ad846` |
| In Progress | `47fc9ee4` |
| Done | `98236657` |
| Not Planned | - | (use `gh issue close --reason "not planned"`)

**Required PAT Scopes**: The `PAT_WORKFLOW_TRIGGER` secret must have `project` and `read:project` scopes.

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

### Updating Project Status
When closing as "not planned", remove from project or leave as-is (closed issues are filtered by default):
```bash
# Optional: Remove from project entirely
gh project item-delete 1 --owner andreasronge --id ITEM_ID
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
