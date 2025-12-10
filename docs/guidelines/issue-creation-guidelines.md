# Issue Creation Guidelines

## Purpose

This document defines **how to write well-specified GitHub issues** - the template, sizing guidelines, and quality checklist.

**Audience**: Anyone creating issues (maintainers, PM workflow, auto-triage).

**Relationship to other docs**:
- After creation, issues are reviewed using `planning-guidelines.md` (9-point checklist)
- The PM workflow (`pm-workflow.md`) orchestrates when to create issues

**Used by**: `claude-pm.yml` workflow when creating new issues.

## Overview

Issues can be created by:
- **Maintainers**: Direct creation for any work item
- **PM Workflow**: Automated creation from specification documents (see `github-workflows.md`)
- **Auto-Triage**: Created during PR review for deferred items (labeled `from-pr-review`)

Each issue should be:
- **Self-contained**: All information needed to implement is in the issue
- **Right-sized**: Large enough to be testable via E2E test, small enough for one PR
- **Verified**: Based on actual codebase analysis, not assumptions

## Issue Template

```markdown
## Summary

[1-2 sentences: What is being implemented and why it matters to library users]

## Context

**Architecture reference**: [Link to relevant section in docs/guide.md or DSL specifications]
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
- `docs/guide.md` - [what section needs update]
- `docs/ptc-json-specification.md` - [if JSON DSL changes]
- `docs/ptc-lisp-specification.md` - [if PTC-Lisp changes]
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

**Too large**: "Add logic and variable operations"

**Split into:**
1. "Add `let` variable bindings" - Core variable binding with scoping
2. "Add `if` conditional operation" - Conditional branching
3. "Add boolean logic operations (`and`, `or`, `not`)" - Composable conditions
4. "Add `merge` and `concat` combiners" - Data combination

Each is independently testable and delivers value.

## Quality Checklist

Before submitting an issue for review:

- [ ] Summary explains value to library users
- [ ] Context references relevant docs (README.md, specifications)
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

1. **Add `needs-review` label** - Triggers issue review workflow
2. **Issue review adds both labels** - When approved, review adds `ready-for-implementation` AND `claude-approved`
3. **PM triggers implementation** - Posts `@claude` comment, which requires `claude-approved` to execute

The review gate is the single approval point. Once an issue passes review, automation handles the rest.

## Labels

See [GitHub Workflows](github-workflows.md#labels-reference) for the complete labels reference.

**Key labels for issues**:
- `needs-review` - Triggers issue review workflow
- `ready-for-implementation` - Issue approved and ready for PM
- `claude-approved` - Allows `@claude` comments to trigger implementation (added by review workflow)

## References

- [Planning Guidelines](planning-guidelines.md) - The 9-point review checklist
- [Testing Guidelines](testing-guidelines.md) - How to write good tests
- [PR Review Guidelines](pr-review-guidelines.md) - What PR reviewers look for
- [Guide](../guide.md) - System design and API reference
- [PTC-JSON Specification](../ptc-json-specification.md) - JSON DSL reference
- [PTC-Lisp Specification](../ptc-lisp-specification.md) - PTC-Lisp reference
