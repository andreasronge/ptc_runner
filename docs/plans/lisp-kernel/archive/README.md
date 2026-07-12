# Lisp Kernel Plan Archive

This directory preserves the detailed planning and evidence produced during
the first kernel implementation push. The files remain useful for historical
facts, failed experiments, commands, and design rationale, but they are no
longer the active development process.

In particular, archived language such as “must,” “gate,” “preregister,” and
“execution order” describes the process used at the time. It does not override
the current lightweight exploration approach in
[`../roadmap.md`](../roadmap.md) or the repository rules in `AGENTS.md`.

## Contents

- [`architecture.md`](architecture.md) — accumulated architecture facts and
  decisions.
- [`spikes.md`](spikes.md) — the former append-only spike registry.
- `autonomous-*.md` — detailed briefs written for autonomous implementation
  batches.
- [`experiments/`](experiments/) — frozen live-run protocols and recorded
  outcomes.
- [`m2-lifecycle-audit.md`](m2-lifecycle-audit.md) — lifecycle gate evidence.
- [`kernel-return-contract-spike.md`](kernel-return-contract-spike.md) — the
  typed return-contract exploration.
- Discussion documents covering evaluation domains and the agentic-systems
  briefing.

The archive is intentionally not reorganized into a new plan. Preserve it as
a record; extract only the facts needed for current exploration.
