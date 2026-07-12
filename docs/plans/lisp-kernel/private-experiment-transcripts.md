# Private Experiment Transcripts

**Status:** superseded at the public Kernel cutover.

The evaluator-specific design below is retained only as historical rationale.
Only the transcript mechanism was superseded: the shipped path persists
canonical normal or explicitly private `.private.jsonl` events through
`Kernel.TraceLog`; private files are mode `0600`, require an explicit private
grant, and are omitted by normal directory queries and the viewer. The old
dataset runner, oracle/scoring, comparisons, feedback A/B tasks, and generated
reports were intentionally retired without replacement rather than becoming a
second product surface.

## Question

Can every kernel experiment produce a private, easy-to-browse transcript that
shows exactly what the model saw, what it produced, what the host executed, and
which effective configuration and preludes governed each turn?

The transcript is a debugging aid, not benchmark evidence. Sanitized reports
and traces remain the shareable experiment artifacts.

## What this actually is

This is primarily a **retention and presentation change**, not a new
instrumentation system. The evaluator already writes a temporary raw JSONL
trace for every run, reads it for requirement checks, produces a sanitized
persistent copy, and deletes the raw file
(`lib/ptc_runner/kernel/eval.ex`, `run_kernel_case/5` and
`run_incumbent_case/5`). When private capture is requested, preserve or
transform that existing raw trace instead of deleting it, and enrich it with
the events listed below. Prelude snapshot data likewise already flows through
the in-band event callback; the private variant keeps exact source where the
sanitizer strips it.

The majority of the genuinely new work is in `ptc_viewer`, which currently has
no kernel-eval awareness at all.

## Desired experience

Run one command:

```console
mix ptc.kernel_eval --suite tier2 --seed 17 \
  --case engineering_expenses --variant kernel \
  --live --model deepseek --allow-failures \
  --private-trace-dir tmp/kernel-transcripts/engineering-expenses
```

Then open it:

```console
mix ptc.viewer --trace-dir tmp/kernel-transcripts/engineering-expenses
```

The viewer should show an experiment header followed by one expandable entry
per turn, rendered as structured expandable sections — a readable
request/program/result transcript, not polished panels. Presentation can
improve later. Each turn exposes four sections:

1. **Model saw** — exact system prompt, message history, tool schema, and
   allowlisted effective model request options.
2. **Model produced** — exact response metadata and PTC-Lisp program. Provider
   reasoning is shown only when the provider returned it; the transcript must
   not imply access to hidden chain of thought.
3. **Host executed** — evaluation status, returned value or error, prints,
   bounded memory before/after information, and changed definitions.
4. **Prelude state** — role, effective outer and inner prelude bundles, source
   origins and hashes, plus any prelude catalog operations associated with the
   turn.

The first entry also shows the complete effective run configuration: case,
variant, model, seed, commit, limits, return contract, role and role grant,
tools, prelude overrides, and allowlisted LLM options.

## Safety boundary

Private transcripts can contain complete datasets, prompts, model output, tool
arguments/results, and future model-authored prelude source. Therefore:

- creation is explicit through `--private-trace-dir`;
- files are created with mode `0600`;
- the destination is **enforced fail-closed**: the task resolves the path and
  runs `git check-ignore --quiet <path>`; if the path is inside a Git worktree
  and not ignored, refuse to write with a stable error. No override flag —
  this data is explicitly unsafe and there is no exploratory need to write it
  into tracked locations. Outside a Git worktree, permit capture with a
  prominent warning and `0600` permissions;
- the command prints a prominent local-only warning;
- private traces are never embedded in normal Markdown/JSON reports;
- normal traces remain sanitized exactly as they are today;
- no credentials, authorization tokens, or process environment values are
  copied into either trace format.

### Request options are allowlisted, never dumped

Captured model request configuration is an explicit allowlist:

- resolved model ID;
- temperature;
- maximum output tokens;
- receive timeout;
- tool schema visible to the model;
- return contract;
- transport mode.

Never serialize adapter structs, HTTP options, headers, credentials, callback
closures, or arbitrary provider metadata. Authorization material is not
model-visible, so excluding it does not compromise the exact-model-boundary
goal.

### Kernel request capture must be enabled

For the kernel variant, LLM request logging is gated behind `unsafe_debug`
(`lib/ptc_runner/kernel.ex`). `--private-trace-dir` must imply
`unsafe_debug: true` for the kernel path, otherwise the private trace records
no requests for the variant this plan cares most about.

`--unsafe-debug-report` is replaced by this feature. It is consumed by **both**
`mix ptc.kernel_eval` and `mix ptc.kernel_feedback_ab` (through different
write paths); once the private trace covers the same information, delete the
flag and the Markdown renderer from both tasks. This is a 0.x exploratory
feature — delete the old path rather than maintain two formats.

## Trace shape

Use ordinary JSONL trace events that `ptc_viewer` can consume. Do not put an
Elixir term dump inside Markdown.

The schema is **canonical turn plus model-call and prelude lifecycle events**.
Three layers, no competing representations:

- `turn` — the authoritative execution record. The private trace retains the
  existing v2-flat envelope (`event: "turn"`, `schema_version: 2`,
  `lib/ptc_runner/trace_log/turn_event.ex`) shared by kernel, SubAgent, and
  session drivers, with its unsanitized data bag. Do not invent parallel
  per-turn event kinds; the in-band `action`, `eval`, and `memory` callbacks
  are *sources* that enrich the turn, not separate persistent events.
- `llm.start` / `llm.stop` — the model-call span, a vocabulary the viewer
  already recognizes (`ptc_viewer/priv/static/js/agent-view.js`). `llm.start`
  carries the exact safe model-visible request (messages, system prompt, tool
  schema, allowlisted options); `llm.stop` carries the exact returned provider
  response.
- `experiment.config`, `prelude.snapshot`, `prelude.operation` — genuinely new
  concepts, defined below.

Minimum event sequence:

```text
trace.start
experiment.config
prelude.snapshot

llm.start          exact safe model-visible request
llm.stop           exact returned provider response
turn               canonical unsanitized turn envelope

prelude.operation  only when applicable
prelude.snapshot   only when effective state changed
trace.stop
```

Each event carries `trace_id`, `seq`, timestamp, case, run, variant, and turn
where applicable.

## Flexible prelude history

Do not design a generic prelude editor yet. Preserve enough facts so one can be
added later without changing historical transcripts.

Represent preludes through two complementary event types:

### `prelude.snapshot`

Records the effective prelude state used to build a model request:

- slot (`outer` or `inner`);
- role and effective grant identity;
- ordered bundle components;
- component ID, version when present, namespaces, origin, checksum and source
  hash;
- exact source for private traces;
- bundle source/artifact hashes;
- prompt-visible exports or symbol inventory metadata when relevant.

Snapshots are authoritative for answering “what governed this turn?” Emit the
initial snapshots and emit another snapshot only when the effective bundle
changes.

### `prelude.operation`

Records a create, update, delete, select, or reject operation when the runtime
supports model-authored prelude changes:

- operation and target identity;
- actor (`host`, `model`, or named role);
- requested source/hash and resulting source/hash where applicable;
- authorization outcome and bounded reason;
- turn and causal action ID.

Operations explain how state changed; snapshots show the state actually used.
The initial implementation may emit no operation events. The viewer should
render unknown operation kinds as structured key/value data so adding future
operations does not require a schema redesign.

## Smallest implementation

1. Add `--private-trace-dir` to `mix ptc.kernel_eval`.
2. Require an ignored destination (fail-closed `git check-ignore`) and create
   files as `0600`.
3. Make private capture imply kernel `unsafe_debug: true`.
4. Preserve the canonical unsanitized `turn` events from the existing raw
   trace — one private JSONL file per case/run/variant.
5. Add allowlisted `experiment.config` and exact model-visible
   `llm.start`/`llm.stop` events.
6. Emit self-contained initial prelude snapshots.
7. Give `ptc_viewer` a basic kernel-eval transcript mode using expandable
   structured sections: configuration, full messages, program, result, memory,
   and prelude snapshot. No polished panel design in this slice.
8. Render `prelude.operation` generically if present; do not build creation,
   editing, diffing, or rollback UI.
9. Delete `--unsafe-debug-report` and its Markdown renderer from both
   `ptc.kernel_eval` and `ptc.kernel_feedback_ab` after parity is proven.
10. Correct the `ptc_viewer` README (`--plan-dir` does not exist) and use only
    `mix ptc.viewer --trace-dir …` in all documented commands.

Do not change the evaluator, oracle, prompt policy, or prelude management as
part of this work.

## Tests

### Focused automated tests

- CLI parsing accepts `--private-trace-dir` and leaves private capture disabled
  by default.
- A non-gitignored destination inside a Git worktree is refused with a stable
  error; a destination outside any worktree is permitted with a warning.
- Default reports and traces remain sanitized.
- Private files are `0600` and are not referenced by published reports.
- A mock two-turn case records the exact first request, first program,
  evaluation feedback, complete second request, second program, and result.
- Kernel and incumbent variants produce the same viewer-level transcript
  concepts even if their internal event sources differ.
- A prelude snapshot records exact source, component identity, ordering, role,
  and bundle hashes.
- A second snapshot is emitted after a simulated effective-prelude change.
- An unknown `prelude.operation` kind renders without breaking the viewer.
- Fake authorization headers/options injected at the adapter boundary do not
  appear anywhere in the private trace; captured request options contain only
  allowlisted keys.

Run:

```console
mix test test/ptc_runner/kernel/eval_test.exs
mix cmd --cd ptc_viewer mix test
```

Then run the repository quality gate before committing:

```console
mix precommit
```

### Manual mock acceptance run

This must require no API key and should be the first end-to-end check:

```console
rm -rf tmp/kernel-transcripts/mock-engineering

mix ptc.kernel_eval --suite tier2 --seed 17 \
  --case engineering_expenses --variant kernel --mock \
  --allow-failures \
  --private-trace-dir tmp/kernel-transcripts/mock-engineering

mix ptc.viewer --trace-dir tmp/kernel-transcripts/mock-engineering
```

In the browser verify:

- the header shows mock mode, kernel variant, seed 17, role, limits and return
  contract;
- turn 1 shows the complete prompt/messages and the exact definition of
  `engineering-ids`;
- the evaluation shows that the definition persisted without returning;
- turn 2 shows feedback in the exact message history and the exact program that
  reads `engineering-ids` and returns the total;
- the initial outer prelude snapshot lists `agent.prompt`, `agent.feedback`, and
  `agent.core`, including exact source and hashes;
- no duplicate snapshot appears when the effective prelude did not change.

### Optional live acceptance run

After the mock view is correct:

```console
rm -rf tmp/kernel-transcripts/live-engineering

mix ptc.kernel_eval --suite tier2 --seed 17 \
  --case engineering_expenses --variant kernel \
  --live --model deepseek --runs 1 --allow-failures \
  --private-trace-dir tmp/kernel-transcripts/live-engineering

mix ptc.viewer --trace-dir tmp/kernel-transcripts/live-engineering
```

Treat this result as an anecdotal debugging run. Check that every displayed
program and feedback message is available directly rather than reconstructed
from a hash.

## Done for this slice

The slice is complete when the mock acceptance run can be inspected entirely
in `ptc_viewer`, the exact per-turn model boundary is visible, effective
prelude snapshots are self-contained, and normal experiment artifacts remain
sanitized. Prelude mutation itself is explicitly out of scope.
