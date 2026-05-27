# Change float_precision to significant digits

## Context

Float values in planner prompts show excessive precision (e.g., `0.0076017543859649124`) wasting LLM tokens. The current `float_precision` option uses fixed decimal places (`Float.round(value, N)`), which breaks for small numbers: `Float.round(0.0076, 2)` → `0.01`, losing meaning. Changing to **significant digits** preserves meaning at any magnitude.

## Changes

### 1. Change `round_floats` to use significant digits
**File:** `lib/ptc_runner/lisp.ex` (`round_floats/2`)

Replace `Float.round(value, precision)` with a `round_significant/2` helper:
- `0.0` → `0.0` (special case)
- Compute `d = ceil(log10(abs(value)))`, then `decimal_places = sig_figs - trunc(d)`
- If `decimal_places >= 0`: use `Float.round(value, decimal_places)`
- If `decimal_places < 0`: use `Float.round(value / 10^(-decimal_places), 0) * 10^(-decimal_places)` (handles large numbers)

Examples with 4 significant digits:
- `0.0076017543859649124` → `0.007602`
- `3.3333333` → `3.333`
- `12345.678` → `12350.0`

### 2. Update SubAgent default from 2 to 4
**File:** `lib/ptc_runner/sub_agent/definition.ex`

Change `float_precision: 2` → `float_precision: 4`

### 3. Update Lisp.run docs
**File:** `lib/ptc_runner/lisp.ex`

Update the `@doc` to say "significant digits" instead of "decimal places". Update examples.

### 4. Update SubAgent docs
**File:** `lib/ptc_runner/sub_agent.ex`

Change doc from "Decimal places for floats" to "Significant digits for floats (default: 4)"

### 5. Update guide docs
- `docs/guides/subagent-concepts.md` — update `float_precision` table row

### 6. Update tests
**File:** `test/ptc_runner/lisp/lisp_options_test.exs`
- Update assertions to reflect significant digits behavior
- Add tests for small numbers (the motivating case)

**File:** `test/ptc_runner/sub_agent/run_test.exs`
- Update default assertion from 2 to 4
- Update expected values to match significant digits

**File:** `test/ptc_runner/sub_agent/loop/lisp_opts_test.exs`
- Update expectations for the default propagated through `PtcRunner.SubAgent.Loop.LispOpts`

### 7. Confirm all SubAgent execution paths use the new default
**Files:**
- `lib/ptc_runner/sub_agent.ex` (single-shot mode)
- `lib/ptc_runner/sub_agent/loop/lisp_opts.ex` (loop transports)
- `lib/ptc_runner/sub_agent/loop.ex`
- `lib/ptc_runner/sub_agent/loop/ptc_tool_call.ex`
- `lib/ptc_runner/sub_agent/loop/text_mode.ex`

The old `lib/ptc_runner/plan_runner.ex` direct-task path no longer exists. Current loop transports delegate through `PtcRunner.SubAgent.Loop.LispOpts`, which already passes `agent.float_precision` to `PtcRunner.Lisp.run/2`. Single-shot mode also passes `agent.float_precision` directly. After changing the default, verify these paths pick up `4` without adding duplicated option builders.

## Verification

```bash
mix test test/ptc_runner/lisp/lisp_options_test.exs
mix test test/ptc_runner/sub_agent/run_test.exs
mix precommit
```
