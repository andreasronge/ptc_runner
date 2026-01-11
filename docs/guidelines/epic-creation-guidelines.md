# Epic Creation Guidelines

An epic is a GitHub issue that serves as the source of truth for a feature. It links to specs, tracks progress via checkboxes, and coordinates related issues.

## Labels

| Label | Purpose |
|-------|---------|
| `type:epic` | Marks this issue as an epic |
| `status:active` | Current epic (only one at a time) |
| `epic:name` | Put on child issues (e.g., `epic:message-history`) |

## Structure

```markdown
# [Epic Name]

## Overview
Brief description of what this epic accomplishes.

## Specification Documents
- [Primary Spec](https://github.com/OWNER/REPO/blob/main/docs/specs/spec-name.md)

## Progress

### Phase 1: [Phase Name]
- [ ] Task description
- [ ] #123 - Existing issue (if already created)
- [x] #124 - Completed

### Phase 2: [Phase Name]
- [ ] Next phase tasks...

## Discovered Issues
- #130 - Found during implementation
```

## Guidelines

- **One active epic**: Remove `status:active` from old epic before adding to new
- **Full URLs**: Use `https://github.com/...` not relative paths (they don't work in issues)
- **Phases are sequential**: Complete Phase 1 before Phase 2
- **Just-in-time issues**: Don't create all issues upfront - create them as work progresses
- **Label child issues**: Add `epic:name` label to issues belonging to this epic
- **Deferred docs**: For phased refactorings with dual-write/backward-compat, defer doc updates to the final cleanup issue

## Task Sizing

Each task should:
- Deliver testable value (can write an E2E test)
- Fit in one PR (typically 100-500 lines)
- Have clear boundaries

See [Issue Creation Guidelines](issue-creation-guidelines.md) for more on sizing.

## References

- [GitHub Workflows](github-workflows.md) - How automation interacts with epics
- [Issue Creation Guidelines](issue-creation-guidelines.md) - Writing issues
