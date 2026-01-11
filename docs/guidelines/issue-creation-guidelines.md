# Issue Creation Guidelines

Guidelines for writing GitHub issues that work well with the automation workflows.

## Key Principles

1. **Self-contained**: Include enough context to implement without external knowledge
2. **Right-sized**: One PR, testable via E2E test, clear boundaries
3. **Verified**: Based on actual codebase analysis, not assumptions
4. **Link, don't duplicate**: Reference specs instead of copying content

## Essential Sections

Issues should generally include:

- **Summary**: What and why (1-2 sentences)
- **Context**: Link to spec document if part of an epic (use full GitHub URL)
- **Acceptance criteria**: Specific, testable conditions for completion
- **Blocked by**: Dependencies in format `Blocked by: #123, #456` (automation parses this)

Beyond these essentials, use judgment. Some issues need implementation hints, edge cases, or test plans. Others are simple enough to not need them.

## For Epic Issues

When creating issues from a roadmap:

- **Add epic label**: e.g., `epic:message-history`
- **Link to spec**: Add Context section with URL to requirements/spec document
- **Real issue numbers only**: Don't add "Blocks: #7, #8" if those issues don't exist yet
- **Mark complete blockers**: If blocker is already closed, note it: `#603 - ✅ Complete`

## Sizing

**Right-sized:**
- Delivers user-visible value (can write E2E test)
- Fits in one PR (typically 100-500 lines)
- Clear scope boundaries

**Too large** (split it):
- More than 5 acceptance criteria
- Touches more than 5 files significantly
- Description says "and also..."

**Too small** (combine or skip):
- Pure mechanical change
- No E2E test possible
- Done in < 30 minutes

## Automation Labels

| Label | Trigger |
|-------|---------|
| `needs-review` | Issue review workflow evaluates and improves the issue |
| `ready-for-implementation` | Issue approved; implementation can start |

The review workflow adds `ready-for-implementation` when an issue passes review and triggers implementation automatically.

## Common Mistakes

1. **Assuming instead of verifying** - Check the codebase before describing current state
2. **Vague acceptance criteria** - "Good test coverage" vs specific test cases
3. **Missing dependencies** - If blocked, add `Blocked by: #X` section
4. **Referencing non-existent issues** - Don't add "Blocks: #7" if #7 doesn't exist
5. **Duplicating spec content** - Link to specs, don't copy requirements lists

## References

- [Planning Guidelines](planning-guidelines.md) - Review checklist
- [GitHub Workflows](github-workflows.md) - How automation works
- [Epic Creation Guidelines](epic-creation-guidelines.md) - Coordinating related issues
