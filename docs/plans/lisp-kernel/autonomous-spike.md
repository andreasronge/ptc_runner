# Lisp Kernel — Autonomous Spike Brief

**Status:** draft goal brief for an autonomous Codex session on
`exp/lisp-kernel`.

Use this when starting a long-running goal. The `/goal` prompt should stay
short and point here; this document carries the detailed contract.

## Short Goal Prompt

```text
Run the autonomous Lisp-kernel vertical-slice spike described in
docs/plans/lisp-kernel/autonomous-spike.md.

Implement the smallest working native-tool-call kernel path, prove it with
mock tests, try one live DeepSeek/OpenRouter smoke if OPENROUTER_API_KEY is
available, and update the lisp-kernel docs with evidence and corrections.

Stop on evidence-backed blockers rather than widening scope.
```

## Objective

Build the smallest useful vertical slice that discovers whether the planned
kernel/prelude architecture works in practice:

- native tool-call-only model action protocol;
- `run_ptc_lisp` argument validation;
- protocol-error retry path;
- strict inner `Lisp.run` evaluation;
- private kernel capabilities;
- bounded eval projection;
- trace/report artifacts useful for future prelude iteration;
- one live DeepSeek smoke when credentials are present.

This is an ambitious spike, not the full M1 implementation. Favor evidence over
polish.

## Scope

Read first:

- `AGENTS.md`
- `docs/plans/lisp-kernel/architecture.md`
- `docs/plans/lisp-kernel/roadmap.md`
- `docs/plans/lisp-kernel/spikes.md`

Allowed:

- add experimental modules, mix tasks, tests, or spike files under clearly
  named kernel/spike paths;
- update the plan docs with verified facts, corrections, and spike results;
- make narrow supporting changes when needed to run the spike.

Avoid:

- deleting the measured incumbent SubAgent path;
- building sessions, compaction, MCP, self-improvement, compiled agents, or the
  full M2/M3 evaluation harness;
- preserving compatibility with old text-code behavior;
- broad refactors not needed for the vertical slice.

## Build Tasks

1. **Native action normalization**

   Add the smallest layer that normalizes LLM responses into the V1 action
   envelope.

   Accepted model action:

   ```json
   {
     "name": "run_ptc_lisp",
     "arguments": {
       "program": "(return ...)"
     }
   }
   ```

   Reject deterministically:

   - free-text code;
   - assistant text plus a tool call;
   - missing tool call;
   - multiple tool calls;
   - wrong tool name;
   - invalid JSON arguments;
   - decoded non-map arguments;
   - missing, empty, non-string, or oversized `program`;
   - extra arguments, including attempted `commentary`;
   - terminal free-text final answers unless architecture D14 is explicitly
     revised.

   Preserve tokens/model/provider metadata where available. Do not drop token
   usage.

2. **Minimal kernel or spike runner**

   Create the smallest runner that can execute:

   - an outer trusted loop/prelude;
   - private `llm-complete`, `eval-program`, and `log` capabilities;
   - an inner strict `PtcRunner.Lisp.run/2` for model programs;
   - a bounded `eval-program` projection, not a raw `Step`.

   Keep kernel capabilities tiny. Avoid closures over large mission state when
   a handle or small slice is enough.

3. **Minimal loop prelude**

   Implement an S4-style compiled prelude or equivalent minimal loop that:

   - builds model messages;
   - calls `llm-complete`;
   - handles `protocol_error` with retry feedback;
   - accepts exactly one valid `run_ptc_lisp` action;
   - calls `eval-program`;
   - returns when the model program produces `(return ...)`;
   - records enough messages/actions for assertions.

4. **Deterministic tests**

   Add focused tests before relying on live LLM behavior:

   - happy path: mock LLM -> `run_ptc_lisp` -> inner eval -> return;
   - malformed response cases fail closed;
   - protocol-error retry path;
   - model program `(fail ...)` path;
   - strict inner timeout/heap behavior where feasible;
   - private capability access denial;
   - bounded projection shape;
   - trace/report artifact shape where feasible;
   - prompt hygiene: rendered prompt mentions `run_ptc_lisp` and does not
     mention `lisp_eval`, code fences, direct prose final answers, or demo-domain
     hints.

5. **Live DeepSeek smoke**

   Add one blessed live smoke path.

   Requirements:

   - use `PTC_TEST_MODEL` or `--model deepseek`;
   - resolve model aliases through the existing registry convention;
   - require `OPENROUTER_API_KEY` for the live run;
   - if the key is absent, record live as blocked and finish deterministic work;
   - default artifacts are redacted/sanitized;
   - raw provider prompt/response data is allowed only behind an explicit unsafe
     debug flag.

## DeepSeek Probes

Run only as far as the spike runner supports. Record exact provider behavior.

- Can DeepSeek/OpenRouter produce exactly one `run_ptc_lisp` tool call with
  `{"program": "..."}`?
- Does it emit assistant text alongside a valid tool call?
- Does it support forced `tool_choice` for this model?
- Can provider fallback be disabled, and is the actual backend reported?
- What token, model, provider, reasoning, and routing metadata is returned?
- What shape appears for malformed tool arguments?
- Can it recover after protocol feedback: "call `run_ptc_lisp` with a valid
  `program` string"?
- Can it write valid PTC-Lisp for:
  - simple count;
  - simple filter;
  - aggregation;
  - one tool-result feedback retry?
- Does a timeout/cancel leave Req/Finch/OpenRouter client state healthy enough
  for a second call?

## Credentials

For the live portion, use OpenRouter through the existing repo convention.

Local `.env` example:

```bash
OPENROUTER_API_KEY=sk-or-...
PTC_TEST_MODEL=deepseek
```

Or for one command:

```bash
OPENROUTER_API_KEY=sk-or-... PTC_TEST_MODEL=deepseek mix test --include e2e
```

Rules:

- `.env` is gitignored; never commit it.
- Prefer `PTC_TEST_MODEL=deepseek` for this experiment unless a spike is
  explicitly testing another model id.
- Do not echo the key or include it in reports/traces.
- If the key is absent, deterministic tests still run and the live section is
  recorded as blocked.
- If a worktree has no `.env`, either export the variables in that shell or
  create a local `.env` in the worktree.

## Verification

Run, in order:

1. targeted tests for new code;
2. `mix format`;
3. `mix precommit` if the change affects normal repo code.

If `mix precommit` is too slow or fails due unrelated incumbent issues, record
the exact command and failure, then run the narrowest meaningful checks for the
spike.

Run the live DeepSeek smoke only when `OPENROUTER_API_KEY` is present.

## Deliverables

- Working code/tests for the vertical slice, or an evidence-backed blocker.
- `docs/plans/lisp-kernel/spikes.md` updated with relevant S3/S4/S6 findings.
- `docs/plans/lisp-kernel/architecture.md` updated with verified facts or
  corrected decisions.
- `docs/plans/lisp-kernel/roadmap.md` updated if milestones/research items
  change.
- A final report covering:
  - what worked;
  - what broke;
  - exact commands run;
  - deterministic test results;
  - live DeepSeek results or why live was blocked;
  - whether the next step is M1 implementation, another spike, or architecture
    revision.

## Stop Conditions

Stop and document evidence if:

- DeepSeek/OpenRouter native tool calling is unsupported or cannot be normalized
  cleanly;
- nested `Lisp.run` is unreliable enough to require host proxying;
- private capability authorization cannot enforce the intended boundary;
- the prelude cannot express the loop cleanly;
- copy/setup pressure makes the minimal path untenable;
- live provider behavior contradicts the V1 protocol assumptions.

## Future Self-Improvement Note

Do not build the self-improving prelude loop in this spike. Build the substrate
it will need later:

- sanitized action envelopes;
- replayable eval projections;
- prelude bundle/source hashes;
- trace/report paths;
- stable failure categories;
- enough prompt/action history for a future maintainer or agent to propose a
  prelude diff.
