# PR Review Guidelines

Guidelines for the Claude Code Review workflow to produce actionable, clear reviews.

## Overview

The PR review workflow runs when a maintainer adds the `claude-review` label to a pull request. Once triggered, it produces a review comment that is then processed by the [Auto-Triage workflow](auto-triage-spec.md), which decides whether to fix issues immediately, defer them to GitHub issues, or ignore them.

**Note**: For public repositories, the `claude-review` label prevents untrusted PRs from automatically triggering expensive Claude API calls.

**Key insight**: The review's language directly affects triage decisions. Clear, explicit severity signals help the auto-triage make correct choices.

## Review Structure

Use this consistent structure for all reviews:

```markdown
## PR Review: [PR title]

### Summary
[1-2 sentence overview of what the PR does and overall assessment]

### What's Good
[Positive aspects - establishes context and shows understanding]

### Issues (Must Fix)
[Problems that MUST be addressed before merge]

### Suggestions (Optional)
[Nice-to-have improvements that could be deferred]

### Security
[Security assessment - even if just "No concerns"]

### Documentation
[Assessment of whether relevant docs are updated - or "No updates needed"]

### Verdict
[Approve/Request Changes/Comment - with brief rationale]
```

## Severity Classification

### Issues (Must Fix)

Use for problems that **should block merge** or need FIX_NOW:

| Category | Examples |
|----------|----------|
| **Bugs** | Logic errors, missing null checks, race conditions |
| **Security** | SQL injection, XSS, credential exposure |
| **Incomplete work** | PR establishes pattern but doesn't apply it consistently |
| **Breaking changes** | API changes without migration, removed functionality |
| **Test failures** | Tests that would fail or test pollution |
| **Missing docs** | Public API changes without doc updates, outdated architecture docs |

**Language to use:**
- "MUST FIX: ..."
- "This will cause [specific problem]"
- "There are still N instances of X that need the same fix"
- "This is incomplete - the PR fixes X in 4 places but not in these 6 others"

**Language to AVOID:**
- "Consider..." (sounds optional)
- "Lower risk..." (implies can be skipped)
- "Could potentially..." (ambiguous)

### Suggestions (Optional)

Use for improvements that **could be deferred** to future work:

| Category | Examples |
|----------|----------|
| **Refactoring** | Extract helper, rename for clarity |
| **Performance** | Caching, query optimization (unless critical) |
| **Style** | Code organization, documentation |
| **Future-proofing** | Extensibility, configurability |

**Language to use:**
- "OPTIONAL: Consider..."
- "Nice-to-have: ..."
- "For future consideration: ..."
- "Out of scope for this PR, but worth a GitHub issue: ..."

## Critical Rule: In-Scope Completeness

When a PR establishes a pattern or fix, check if it's **consistently applied**.

### Example: PR #48 (DateTime.utc_now fix)

**What the PR did**: Fixed `DateTime.utc_now()` timing issues by using `fixed_time` variable.

**What the review found**: 6 remaining `DateTime.utc_now()` calls that weren't updated.

**WRONG review language:**
> "While these tests may not be affected... they're lower risk"

This sounds optional, so triage will IGNORE.

**CORRECT review language:**
> "MUST FIX: The PR fixes `DateTime.utc_now()` timing in some places but not others.
> For consistency and to prevent future flaky tests, these 6 remaining instances
> should also use `fixed_time`:
> - Line 261: `DateTime.utc_now()` → use `fixed_time`
> - Line 284: `DateTime.utc_now()` → use `fixed_time`
> - [etc.]
>
> This is a mechanical change following the same pattern the PR establishes."

This is clearly actionable, so triage will FIX_NOW.

## Investigation Requirements

Before flagging an issue, the reviewer MUST:

### 1. Verify the Problem Exists
```bash
# Search codebase to confirm the pattern/issue
grep -r "pattern" lib/
# Check if similar code elsewhere handles it differently
```

### 2. Check Existing Patterns
```bash
# See how similar cases are handled in the codebase
grep -r "similar_pattern" lib/
# Read CLAUDE.md for project conventions
```

### 3. Assess Complexity
Ask:
- Is this a mechanical change (find-replace, add guard clause)?
- Or does it require design decisions (new abstraction, architecture change)?

### 4. Search for Existing Issues
```bash
# Before suggesting a deferral, check if issue exists
gh issue list --search "keyword" --state all
```

### 5. Check Documentation Impact
```bash
# Check if PR changes public API
grep -l "def " --include="*.ex" <changed_files>

# Search for docs that reference changed functionality
grep -r "function_name\|module_name" docs/

# Verify architecture.md is current with changes
grep -r "relevant_feature" docs/architecture.md
```

Ask:
- Does this PR change public API? If yes, are `@doc` and `@moduledoc` updated?
- Does this add/change DSL operations? If yes, is `docs/architecture.md` updated?
- Does this change project structure or conventions? If yes, is `CLAUDE.md` updated?

## Output Format for Triage

Structure findings so the auto-triage can easily parse them:

### For Issues (expect FIX_NOW)
```markdown
### Issues (Must Fix)

1. **Incomplete fix** - `file.ex:123`
   - **Problem**: PR uses `fixed_time` in setup but test still uses `DateTime.utc_now()`
   - **Impact**: Test can still be flaky near midnight UTC
   - **Fix**: Replace `DateTime.utc_now()` with `fixed_time` from setup context
   - **Complexity**: Mechanical (same pattern as rest of PR)
```

### For Suggestions (expect DEFER_ISSUE or IGNORE)
```markdown
### Suggestions (Optional)

1. **Test helper extraction** - Nice-to-have
   - **Suggestion**: Extract repeated `fixed_time` setup to a helper
   - **Benefit**: Reduces boilerplate across test files
   - **Complexity**: Moderate (needs design decisions on API)
   - **Recommendation**: Create GitHub issue for future work
```

## What NOT to Review

Don't waste time on:
- Formatting (handled by `mix format`)
- Issues outside the PR's changed files
- Hypothetical future problems
- Personal style preferences without objective benefit
- Things already covered by CI (compilation, tests)

## Reference Documentation

- [Testing Guidelines](testing-guidelines.md) - Test patterns and quality standards
- [Development Guidelines](development-guidelines.md) - Code conventions
- [Auto-Triage Spec](auto-triage-spec.md) - How triage decisions are made

## Checklist

Before submitting a review:

- [ ] Summary accurately describes the PR's purpose
- [ ] Issues are clearly marked as "Must Fix" with specific locations
- [ ] Suggestions are clearly marked as "Optional"
- [ ] Each issue includes: location, problem, impact, suggested fix
- [ ] Complexity assessment provided for each item
- [ ] In-scope incomplete work is flagged (not just mentioned as "consider")
- [ ] Existing GitHub issues checked before suggesting deferrals
- [ ] Documentation impact assessed (public API → docs updated?)
- [ ] Verdict is clear: Approve, Request Changes, or Comment
