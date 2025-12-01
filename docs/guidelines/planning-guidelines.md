# Planning & Issue Review Guidelines

## Key References

- **[Architecture](../architecture.md)** - System design, DSL specification, implementation phases
- **[Testing Guidelines](testing-guidelines.md)** - Test patterns and quality standards
- **[Development Guidelines](development-guidelines.md)** - Elixir coding standards

## When to Use This Document

Read this document when:
- Entering plan mode for a feature
- Reviewing a GitHub issue
- Evaluating an implementation proposal

## Issue Review Checklist (9 Areas)

### 1. Should This Be Done?
- Is there a compelling reason NOT to implement this?
- Does this solve a real problem or is it speculative?
- Is the benefit worth the complexity and maintenance cost?
- Are there simpler alternatives, including doing nothing?
- Is this the right time, or are there blocking dependencies?

### 2. Simplifications
- Can the approach be simplified?
- Are there unnecessary abstractions?
- Is the solution over-engineered?

### 3. Codebase Research
- **Use Explore agents** to investigate relevant code
- Check existing patterns in the codebase
- Identify files that need modification
- Verify assumptions about how code works

### 4. Reuse Opportunities
- Are there existing patterns/functions to leverage?
- Check `docs/guidelines/` for established patterns
- Look for similar implementations in the codebase

### 5. Refactoring Needs
- Does code need refactoring first?
- Are there technical debt items blocking progress?
- Would refactoring simplify the implementation?

### 6. Edge Cases
- Are there unknown edge cases?
- Check for process boundary issues (important for Elixir)
- Consider error handling scenarios
- For PtcRunner specifically: security/sandbox escape scenarios

### 7. Issue Scope
- Is it too large? Should it be split?
- Can it be implemented incrementally?
- Are there clear acceptance criteria?

### 8. Test Plan
- Does it include verification strategy?
- Are unit tests, integration tests needed?
- Are there tests with low value that are expensive to run/maintain that should not be written?
- Reference `docs/guidelines/testing-guidelines.md`

### 9. Solution Outline
- Does the issue include a clear solution outline?
- Could a good junior developer implement this based on the description?
- Are the implementation steps concrete and actionable?
- Are key decisions already made (not left ambiguous)?

## Plan Quality Checklist

Before approving a plan:
- [ ] Implementation approach is clearly described
- [ ] Files to modify are identified
- [ ] No critical technical flaws
- [ ] Test strategy is appropriate
- [ ] Scope is reasonable for one PR

## Output Format for Issue Reviews

When reviewing an issue, structure your response as:

```
## Issue Review: [Title]

**Summary**: [1-2 sentences]

**Analysis**:
1. **Should This Be Done?**: [findings]
2. **Simplifications**: [findings]
3. **Codebase Research**: [findings from Explore agents]
4. **Reuse Opportunities**: [findings]
5. **Refactoring Needs**: [findings]
6. **Edge Cases**: [findings]
7. **Issue Scope**: [findings]
8. **Test Plan**: [findings]
9. **Solution Outline**: [findings]

**Technical Issues Found**:
- [List any technical flaws]

**Recommended Labels**:
- [e.g., needs-clarification, ready-for-implementation, needs-breakdown]

**Verdict**: [Ready / Needs revision / Should be split]
```
