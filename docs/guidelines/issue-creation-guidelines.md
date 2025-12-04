# Issue Creation Guidelines

Guidelines for creating well-specified GitHub issues.

## Overview

Issues must be created by maintainers (not automatically by workflows). Each issue should be:
- **Self-contained**: All information needed to implement is in the issue
- **Right-sized**: Large enough to be testable via E2E test, small enough for one PR
- **Verified**: Based on actual codebase analysis, not assumptions

## Key References

- **[Architecture](../architecture.md)** - Implementation phases and DSL specification
- **[Planning Guidelines](planning-guidelines.md)** - Issue review checklist
- **[Testing Guidelines](testing-guidelines.md)** - Test quality standards
- **[PR Review Guidelines](pr-review-guidelines.md)** - What reviewers expect

## Before Creating an Issue

### 1. Check Codebase Health First

Before creating a new feature issue, verify:

```bash
# Are there failing tests?
mix test

# Are there pending issues from PR reviews?
gh issue list --label "from-pr-review"

# Is there technical debt blocking progress?
gh issue list --label "tech-debt"
```

**Priority order:**
1. Fix failing tests
2. Address review-found issues (unless documented reason to defer)
3. Technical debt that blocks the feature
4. New features

### 2. Analyze What's Implemented

```bash
# Check recent commits
git log --oneline -20

# Search for existing implementations
grep -r "pattern" lib/

# Verify tests exist for the feature
grep -r "describe.*feature" test/
```

### 3. Verify Against Architecture

Reference `docs/architecture.md` to understand:
- Which phase does this belong to?
- What dependencies exist?
- Is this the logical next step?

### 4. Identify Documentation Impact

Before finalizing the issue, analyze which documentation might need updates:

```bash
# Check what docs reference related functionality
grep -r "keyword" docs/

# Review architecture.md for relevant sections
grep -r "feature_name" docs/architecture.md

# Check if there's API documentation that might be affected
grep -r "function_name" docs/
```

**Documentation to consider:**
- `docs/architecture.md` - If adding/changing DSL operations, phases, or system design
- `CLAUDE.md` - If adding new commands, conventions, or project structure (file must be brief !)
- `README.md` - If changing public API or installation steps
- Module `@moduledoc` and `@doc` - If changing function signatures or behavior
- Type specs (`@spec`, `@type`) - If changing data structures

## Issue Template

```markdown
## Summary

[1-2 sentences: What is being implemented and why it matters to library users]

## Context

**Architecture reference**: [Link to relevant section in docs/architecture.md]
**Dependencies**: [What must be implemented first, or "None"]
**Related issues**: [Links to related issues, or "None"]

## Current State

[Brief description of what exists now - based on actual codebase analysis]

## Acceptance Criteria

- [ ] [Specific, testable criterion]
- [ ] [Another criterion]
- [ ] E2E test demonstrates the feature works
- [ ] Existing tests pass
- [ ] Documentation updated (if public API changes)

## Implementation Hints

**Files to modify:**
- `lib/ptc_runner/module.ex` - [what changes]
- `test/ptc_runner/module_test.exs` - [what tests to add]

**Patterns to follow:**
- [Reference existing similar code]

**Edge cases to consider:**
- [Specific edge case]

## Test Plan

**Unit tests:**
- [Specific test case]

**E2E test:**
- [Describe the end-to-end scenario that proves the feature works]

## Out of Scope

[Explicitly list what this issue does NOT include]

## Documentation Updates

[List docs that need updating, or "None" if purely internal change]
- `docs/architecture.md` - [what section needs update]
- [Other affected docs]
```

## Sizing Guidelines

### Right-Sized Issue

An issue is correctly sized when:
- It delivers **user-visible value** (can write an E2E test for it)
- It fits in **one PR** (typically 100-500 lines changed)
- It has **clear boundaries** (easy to say what's in/out of scope)
- A competent developer could implement it from the description alone

### Too Large

Signs an issue is too large:
- Covers an entire architecture phase
- Has more than 5 acceptance criteria
- Touches more than 5 files significantly
- Description says "and also..."

**Solution**: Split into multiple issues with dependencies.

### Too Small

Signs an issue is too small:
- Pure mechanical change (rename, move file)
- No E2E test possible (just internal refactoring)
- Could be done in < 30 minutes

**Solution**: Combine with related work, or just do it as part of another issue.

### Splitting Example

**Too large**: "Implement Phase 3: Logic & Variables"

**Split into:**
1. "Add `let` variable bindings" - Core variable binding with scoping
2. "Add `if` conditional operation" - Conditional branching
3. "Add boolean logic operations (`and`, `or`, `not`)" - Composable conditions
4. "Add `merge` and `concat` combiners" - Data combination

Each is independently testable and delivers value.

## Quality Checklist

Before submitting an issue for review:

- [ ] Summary explains value to library users
- [ ] Context references architecture.md
- [ ] Current state based on actual codebase analysis (not assumptions)
- [ ] Acceptance criteria are specific and testable
- [ ] E2E test scenario is described
- [ ] Files to modify are identified and exist
- [ ] Patterns to follow reference actual existing code
- [ ] Edge cases are specific to this feature
- [ ] Out of scope is explicit
- [ ] Documentation impact analyzed (which docs need updates)
- [ ] Issue is right-sized (one PR, user-visible value)

## Common Mistakes

### 1. Assuming Instead of Verifying

**Wrong:**
> "The parser currently doesn't support nested operations"

**Right:**
> "Verified: `grep -r "nested" lib/ptc_runner/parser.ex` shows no handling for nested ops.
> Current parser handles only flat structures (see `parse_operation/1` at line 45)."

### 2. Vague Acceptance Criteria

**Wrong:**
- [ ] Parser handles edge cases
- [ ] Good test coverage

**Right:**
- [ ] Parser returns `{:error, {:parse_error, msg}}` for malformed JSON
- [ ] Parser returns `{:error, {:validation_error, msg}}` for unknown operations
- [ ] Tests cover: empty input, invalid JSON, missing required fields, unknown op

### 3. Missing E2E Test Description

**Wrong:**
> "Add appropriate tests"

**Right:**
> **E2E test**: Run a program that uses `let` to store a tool result, then references
> it twice in subsequent operations. Verify the stored value is correctly retrieved
> both times without re-calling the tool.

### 4. Forgetting Out of Scope

Without explicit scope, implementation may gold-plate:

**Add:**
> ## Out of Scope
> - Nested `let` bindings (future issue)
> - `let` with destructuring (not in spec)
> - Performance optimization for many variables

## Handling Review Feedback

When an issue is rejected by the review workflow:

### If Fixable
1. Read the review feedback carefully
2. Update the issue to address concerns
3. Add `needs-review` label again
4. Document what changed in a comment

### If Fundamental Problem
1. Close the issue with explanation
2. Create a new issue if the work is still needed
3. Reference the closed issue for context

## Enabling Automation

For Claude workflows to work on an issue:

1. **Add `claude-approved` label** - Required for PM workflow to trigger implementation
2. **Add `ready-for-implementation` label** - Issue must be reviewed and approved
3. PM workflow will only act on issues with BOTH labels

## Labels

### Workflow Labels
| Label | Meaning |
|-------|---------|
| `claude-approved` | Maintainer-approved for Claude automation (required for PM workflow) |
| `claude-review` | Triggers Claude automated PR review |
| `needs-review` | Issue ready for review workflow |
| `ready-for-implementation` | Approved, ready to implement |
| `from-pr-review` | Created by triage workflow during PR review |
| `blocked` | Cannot proceed due to dependency |
| `pm-stuck` | PM workflow has failed and needs manual intervention |
| `pm-failed-attempt` | Tracks consecutive PM failures (3 = stuck) |

### Issue Type Labels
| Label | Meaning | Priority |
|-------|---------|----------|
| `bug` | Bug fix needed | Highest |
| `tech-debt` | Refactoring, test improvements, code quality | High |
| `enhancement` | New feature from architecture phases | Normal |
| `documentation` | Documentation updates | Low |

## References

- [Planning Guidelines](planning-guidelines.md) - The 9-point review checklist
- [Testing Guidelines](testing-guidelines.md) - How to write good tests
- [PR Review Guidelines](pr-review-guidelines.md) - What PR reviewers look for
- [Architecture](../architecture.md) - System design and phases
