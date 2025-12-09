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
- [Primary Spec](https://github.com/OWNER/REPO/blob/main/docs/spec-name.md) - Main implementation guide
- [Related Doc](https://github.com/OWNER/REPO/blob/main/docs/related.md) - Supporting documentation

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
| `- [ ] Task description` | PM will create an issue when it's time to work on this |
| `- [ ] #123 - Task title` | Existing issue (only if already created) |
| `- [x] #123 - Task title` | Completed |

## Philosophy

**Keep it lightweight.** Don't create GitHub issues upfront - let the PM create them just-in-time as work progresses. The epic is a roadmap, not a detailed project plan.

- Write tasks as brief descriptions, not detailed specs
- Trust the PM to read the spec docs and create well-formed issues
- Only link existing issues if they already exist (e.g., `from-pr-review` tech debt)
- The PM will refine tasks into proper issues with test plans, edge cases, etc.

**Right-sizing tasks**: When you do specify tasks upfront, keep them at the right granularity:
- Each task should deliver user-visible value (testable via E2E test)
- Each task should fit in one PR (typically 100-500 lines)
- See [Issue Creation Guidelines - Sizing](issue-creation-guidelines.md#sizing-guidelines) for detailed sizing criteria

## Guidelines

- **Phase ordering**: PM completes phases sequentially (Phase 1 before Phase 2)
- **Spec references**: Link to specification documents - PM reads these when creating issues
- **One active epic**: Only one epic should have `status:active` at a time
- **Use full GitHub URLs**: Relative paths like `docs/spec.md` don't work in GitHub issues. Always use full URLs: `https://github.com/OWNER/REPO/blob/main/docs/spec.md`

## References

- [PM Workflow Instructions](../../.claude/commands/pm-workflow.md)
- [GitHub Workflows Overview](github-workflows.md)
- [Issue Creation Guidelines](issue-creation-guidelines.md)
