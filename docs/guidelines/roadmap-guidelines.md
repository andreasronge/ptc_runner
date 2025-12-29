# Roadmap & Requirements Guidelines

## Purpose

This document defines how to create **implementation roadmaps** for large features that span multiple issues. Use this when a feature is too large to plan as a single issue.

**When to use:**
- Feature spans 5+ issues
- Multiple architectural layers involved
- Clear dependency ordering needed
- Detailed specs already exist (need sequencing, not design)

## Document Structure

Create `docs/<feature>/implementation_plan.md`:

```markdown
# <Feature> Implementation Plan

> **Status:** Planning | In Progress | Complete
> **Epic:** #NN (when created)
> **Spec documents:** [list of spec files]

## Overview

[1-2 sentences: what this plan covers and why layered approach]

## Stage 1: <Layer Name>

**Dependency:** None | Stage N

| REQ ID | Summary | Spec Reference | Target Files |
|--------|---------|----------------|--------------|
| XXX-01 | Brief description | spec.md#section | lib/path.ex |

## Stage 2: <Layer Name>

**Dependency:** Stage 1

| REQ ID | Summary | Spec Reference | Target Files |
|--------|---------|----------------|--------------|
| XXX-02 | Brief description | spec.md#section | lib/path.ex |

## Coverage Matrix

| Spec Document | Section | REQ ID | Notes |
|---------------|---------|--------|-------|
| spec.md | Function A | XXX-01 | |
| spec.md | Function B | XXX-02 | |
| spec.md | Error Handling | - | Deferred to phase 2 |
```

## Naming Conventions

**REQ IDs:** `<AREA>-<NN>`
- `CORE-01` - Core types/structs
- `LISP-01` - Lisp interpreter changes
- `AGENT-01` - SubAgent functionality
- `API-01` - Public API changes

**Stages:** Name by architectural layer, not effort:
- "Core Type System" not "Week 1"
- "Interpreter Changes" not "Easy Tasks"

## Key Principles

### 1. Cross-reference, don't duplicate

```markdown
<!-- GOOD: Reference -->
| CORE-01 | Define Step struct | [step.md](step.md) | lib/ptc_runner/step.ex |

<!-- BAD: Duplicate -->
| CORE-01 | Define Step struct with fields: return, fail, memory, memory_delta... |
```

### 2. One REQ = One Issue

Each REQ ID should map to exactly one GitHub issue. If a REQ needs splitting, create sub-IDs:
- `CORE-01a`, `CORE-01b` (split)
- Or renumber: `CORE-01`, `CORE-02` (preferred)

### 3. Stages = Dependency groups

A stage completes when all its REQs are implemented. Next stage can begin only when dependencies are met.

```
Stage 1: [CORE-01, CORE-02, CORE-03]  ← No dependencies, can parallelize
    ↓
Stage 2: [LISP-01, LISP-02]  ← Requires Stage 1 complete
    ↓
Stage 3: [AGENT-01, AGENT-02, AGENT-03]  ← Requires Stage 2 complete
```

### 4. Keep specs clean

Do NOT add REQ IDs back into spec documents. Reference direction is one-way:

```
Specs (design)
    ↑ references
Implementation Plan (sequencing)
    ↑ becomes
GitHub Issues (execution)
```

## Validating Coverage

The coverage matrix ensures no spec sections are missed. Validate before implementation starts.

### Manual validation

1. List every function, struct, and behavior in each spec document
2. Verify each has a corresponding REQ ID in the matrix
3. Mark intentionally deferred items with `-` and a note

### Agent-based validation

Use an Explore agent to check coverage:

```
Read all spec documents in docs/<feature>/*.md and list every
function, struct, and defined behavior. Then read the Coverage
Matrix in implementation_plan.md and report:
1. Spec items without a REQ ID
2. REQ IDs that don't map to any spec section
```

### Coverage rules

| Matrix Entry | Meaning |
|--------------|---------|
| REQ ID present | Covered in this plan |
| `-` with note | Intentionally deferred (document why) |
| Empty/missing | **Gap** - needs REQ or explicit deferral |

**Validate when:**
- Initial plan is complete
- Spec documents are updated
- Before starting a new stage

## Epic Integration

Implementation plans work with the PM workflow's epic issues:

```
Epic Issue (GitHub)
    │
    ├── Links to: implementation_plan.md
    │
    └── Child issues created from REQs
            │
            └── Each links back to epic
```

**In the epic issue**, add:
```markdown
## Implementation Plan
See [implementation_plan.md](docs/<feature>/implementation_plan.md) for staged breakdown.
```

**In the implementation plan header**, add:
```markdown
> **Epic:** #42
```

**Benefits:**
- Epic provides high-level tracking for PM workflow
- Implementation plan provides technical sequencing
- PM workflow decides when to create issues from REQs

## Converting to Issues

When the PM workflow is ready to implement a stage:

1. For each REQ in the stage, create a GitHub issue using [issue-creation-guidelines.md](issue-creation-guidelines.md)
2. Include in the issue:
   ```markdown
   ## Context
   **Epic:** #42
   **REQ ID:** CORE-01
   **Roadmap:** [implementation_plan.md](../implementation_plan.md)
   **Spec:** [step.md](../step.md)
   ```

## Tracking Progress

Update the plan as work progresses:

```markdown
## Stage 1: Core Type System ✓

| REQ ID | Summary | Status | Issue |
|--------|---------|--------|-------|
| CORE-01 | Define Step struct | ✓ Done | #123 |
| CORE-02 | Tool normalization | ✓ Done | #124 |

## Stage 2: Lisp Updates (In Progress)

| REQ ID | Summary | Status | Issue |
|--------|---------|--------|-------|
| LISP-01 | Return Step from run | 🔄 In Progress | #125 |
| LISP-02 | Memory delta tracking | ⏳ Pending | - |
```

## Example

See [ptc_agents/implementation_plan.md](../ptc_agents/implementation_plan.md) for a real example.

## References

- [issue-creation-guidelines.md](issue-creation-guidelines.md) - Individual issue format
- [planning-guidelines.md](planning-guidelines.md) - Issue review checklist
- [github-workflows.md](github-workflows.md) - PM workflow and epic management
