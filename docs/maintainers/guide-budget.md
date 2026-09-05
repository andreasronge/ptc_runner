# Guide budget

> **Audience:** people changing PtcRunner itself.

This gate runs over this repository's own documentation; it is not part of the
runtime an application uses.

`mix precommit` and CI run `scripts/guide_budget.sh check`. It measures every
page in `docs/guides/` and compares it with `.guide-budget-baseline.json`.

The gate is a ratchet: a guide at or under its baseline passes, a guide that
grew fails. Shrinking a guide also passes, and the check prints which budgets
became loose enough to tighten.

## Why it exists

[Documentation guidelines](documentation.md) already say what a guide is:

> **Guides** are short end-user workflows that accomplish one outcome. They
> show one useful path and link to reference pages for exhaustive detail.

That rule was never in dispute; it was simply unenforced. Between 2026-08-17 and
2026-08-23 the guide tier grew from 3,294 to 8,501 words. About half of that was
deliberate new pages. The rest arrived a paragraph at a time, from commits that
were fixing something else — a diagnostic clarification here, a limits
interaction there, each one correct in isolation and each one prose a hurried
reader now has to skip.

Added guide text is a cost every future reader pays. This gate makes that cost
visible at the moment it is added, when moving the paragraph is still cheap.

## What it measures

Four numbers per guide.

| Metric | Meaning | Why |
| --- | --- | --- |
| `words` | total words, code fences included | length is what a hurried reader sees first |
| `density` | inline `` `identifiers` `` per 100 words of prose, code fences excluded | a guide sits well below the reference tier; crossing it means the page became a reference wearing a guide's heading |
| `blockers` | paragraphs of 3+ sentences and 55+ words carrying no list, code, or table | these are what a reader cannot skim past |
| `tics` | intensifiers such as *deliberately*, the "X, not Y" contrast, and em-dashes per 100 words of prose | the marks of text added a paragraph at a time by a model; a rising count is the page losing its voice |

Density is the load-bearing one. When the baseline was recorded, `docs/guides/`
averaged 3.3 identifiers per 100 prose words and `docs/reference/` averaged 6.1.
A guide drifting toward 6 is the measurable form of "this belongs in the
reference".

Because every guide carries its own row, the budget cannot be satisfied by
moving prose from one guide into another.

A guide with no baseline row is held to `new_guide_caps` instead, so adding a
page cannot quietly set its own bar.

## When the gate fails

Prefer the first response. The gate only measures; the writing procedure is
the guide skill in `.claude/skills/write-guide/SKILL.md`.

### Move it to the reference page that owns the surface

This is almost always right. A bug fix that needs new prose has found a gap in a
*reference* page, not a guide. Put the explanation where the surface is already
documented and leave the guide a sentence and a link.

Worked example, from the change that introduced this gate: a fix for the
30-second run clock added twelve lines about `max_turns` versus
`run_duration_ms` and `workflow_timeout_ms` to
[Customize an agent](../guides/building-agents.md). Both clocks were already
documented in the [Kernel limits reference](../kernel-limits-reference.md). The
explanation moved there; the guide kept four lines and a link.

### Trade it against the same guide

If the guide genuinely needs the new path, cut an older one. A guide shows *one*
useful path — a second one is usually a sign the page is really two pages.

### Bless it, with a reason

Run `scripts/guide_budget.sh bless` and explain the increase in the commit body.
Legitimate cases: a genuinely new guide, a deliberate restructure, or a shape
the reference tier cannot carry. Blessing to get a red build green is how the
tier eroded the first time.

## Commands

```console
scripts/guide_budget.sh check    # gate; used by mix precommit and CI
scripts/guide_budget.sh report   # per-guide table, no exit status
scripts/guide_budget.sh bless    # record current measurements as the baseline
```

`report` is the one to run while editing. It prints every guide's three numbers
and flags the rows that are over budget.

## Related documentation

- [Documentation guidelines](documentation.md) define the guide and reference
  tiers this gate enforces.
- [Duplication gate](duplication-gate.md) is the same ratchet pattern applied to
  source.
