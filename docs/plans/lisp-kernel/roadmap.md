# Lisp Kernel — Exploration Notes

**Status:** exploratory discussion material for `exp/lisp-kernel`.

This is not a binding roadmap, an execution order, or a promotion checklist.
It keeps the current lines of inquiry visible while the kernel's useful shape
is still being discovered. Old milestone plans, spike registrations,
architecture records, and experiment protocols are preserved in
[`archive/`](archive/README.md).

## What we are exploring

PtcRunner currently has a substantial experimental kernel implementation. The
underlying idea is still simple:

> Can a small PTC-Lisp program act as the agent loop while the BEAM host keeps
> authority, limits, tools, and durable mission state under explicit control?

The branch has already explored nested evaluation, host-held memory,
capability preludes, role-backed prelude selection, model-visible symbol
inventories, tracing, evaluation harnesses, and typed return contracts. Those
implementations are evidence and design material, not commitments to retain
the resulting API or machinery.

## Current discussion threads

These are prompts for exploration, not an ordered backlog.

### How small can the kernel be?

- Which responsibilities truly belong in `PtcRunner.Kernel`?
- Which existing SubAgent or session mechanisms can be reused directly?
- Which experimental layers exist only to support evaluation or process
  governance rather than the runtime thesis?
- If we rebuilt the successful path today, what would we leave out?

### Where should policy live?

- Which behavior benefits from being expressed in swappable PTC-Lisp
  preludes?
- Which behavior is clearer and safer as host code?
- Does role-backed prelude selection help the experiment now, or is it a
  premature deployment concern?

### What state model is useful?

- Is per-run host-held memory enough to demonstrate useful multi-turn work?
- What memory semantics are understandable to a model and predictable to a
  caller?
- Which lifecycle and retained-size protections are essential invariants, and
  which are production hardening that can wait?

### What contracts help the model?

- Do return signatures materially improve correction and completion?
- How much symbol/type information belongs in the default prompt?
- Can contract feedback stay small and recoverable without growing a general
  type system?

### How should we evaluate ideas?

- During exploration, what is the cheapest run that could change our mind?
- Which deterministic cases expose a mechanism failure?
- When an idea looks promising, what broader comparison would justify keeping
  it?

## Lightweight working loop

For ordinary exploration:

1. Write the current question in a sentence.
2. Make the smallest change or run that can teach us something.
3. Record the observation, including surprises and failures.
4. Decide whether to keep, simplify, change, or delete the experiment.
5. Add rigor only when an idea is moving from exploration toward supported
   behavior.

A short note or commit message is normally enough. New R/S/M identifiers,
append-only registries, frozen hashes, independent review rounds, and formal
exit gates are not required.

Ad hoc live runs are welcome during exploration. Record the command, model,
and rough result when they matter, and label them as anecdotal. Do not turn a
small or selectively repeated run into a comparative claim.

## Rigor that always applies

Exploratory does not mean careless. Keep the repository's standing engineering
rules, especially:

- sandbox authority, timeout, and memory boundaries fail closed;
- owner-process state changes are atomic;
- prompts and agent configuration stay domain-blind;
- bug fixes get a reproducing test before the fix;
- focused tests cover the behavior being changed;
- `mix precommit` passes before committing.

Use additional lifecycle, soak, integration, or independent review checks when
the change creates the corresponding risk. They are tools selected for a
change, not ceremony every experiment must pass through.

## When preregistration is worthwhile

Preregistration is reserved for a conclusion-bearing comparison: for example,
when we intend to say one policy or architecture performs better than another.
At that point, freeze the relevant inputs, define the primary outcome and
stopping rules, choose a meaningful run count, and preserve the result whether
it passes or fails.

It is not required for exploratory implementation, debugging, prompt tuning,
mechanism checks, or deciding what question to ask next.

## Recording a decision

When a finding is worth retaining, use a compact entry here or in the relevant
code documentation:

```text
Date:
Question:
Observation:
Decision for now:
Revisit when:
```

“For now” is deliberate. This is a 0.x experiment, so decisions remain cheap
to reverse and obsolete code should be deleted rather than preserved through
compatibility layers.

## Possible next conversations

- Identify the smallest end-to-end kernel path worth preserving.
- Separate runtime mechanism from evaluation-harness infrastructure.
- Review the experimental public options and remove those that do not support
  the core thesis.
- Decide whether typed return contracts belong in the minimal path.
- List code that can be deleted if no near-term experiment depends on it.

These are intentionally unsequenced. Pick the question with the highest
learning value, not the one that happens to appear first.

## Historical material

The previous plan set remains available in [`archive/`](archive/README.md).
It contains valuable implementation facts, failed experiments, commands, and
design reasoning. Its gates, statuses, and instructions describe the process
used at the time; they no longer govern current kernel exploration.
