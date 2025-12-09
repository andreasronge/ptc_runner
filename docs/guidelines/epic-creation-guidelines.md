# Epic Creation Guidelines

An epic is a GitHub issue that serves as the source of truth for the PM workflow. It contains specification references, a task list with checkboxes, and progress tracking.

## When to Create an Epic

- Starting a new major feature or initiative
- Beginning a new phase of work
- Consolidating related work items into a tracked plan

## Required Labels

- `type:epic` - Identifies the issue as an epic
- `status:active` - Marks it as the current epic (only one at a time)

**Important**: Remove `status:active` from any existing epic before adding it to a new one.

## Epic Structure

```markdown
# [Epic Name]

## Overview
Brief description of what this epic accomplishes.

## Specification Documents
- [Primary Spec](docs/spec-name.md) - Main implementation guide
- [Related Doc](docs/related.md) - Supporting documentation

## Progress

### Phase 1: [Phase Name]
- [ ] Task description (PM will create issue)
- [ ] Another task

### Phase 2: [Phase Name]
- [ ] Next phase tasks...

## Notes
Special instructions, blockers, or decisions for PM.
```

## Task Format

| Format | Meaning |
|--------|---------|
| `- [ ] Task description` | PM should create an issue for this |
| `- [ ] #123 - Task title` | Existing issue, PM will track/trigger |
| `- [x] #123 - Task title` | Completed (auto-updated when issue closes) |

## Guidelines

- **Task granularity**: Each task should be PR-sized (completable in one PR)
- **Phase ordering**: PM completes phases sequentially (Phase 1 before Phase 2)
- **Spec references**: Always link to relevant specification documents
- **One active epic**: Only one epic should have `status:active` at a time

## References

- [PM Workflow Instructions](../../.claude/commands/pm-workflow.md)
- [GitHub Workflows Overview](github-workflows.md)
- [Issue Creation Guidelines](issue-creation-guidelines.md)
