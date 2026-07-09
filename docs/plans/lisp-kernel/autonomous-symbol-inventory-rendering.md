# Lisp Kernel - Autonomous Symbol Inventory Rendering Plan

**Status:** goal brief for a future autonomous Codex session on
`exp/lisp-kernel`. Written 2026-07-08 after the S19 feedback shakedown and
the C prompt-policy probe.

Use this after the immediate prompt fix that teaches value symbols versus
function calls. This plan is not an A/B run. It builds the substrate that makes
`data/`, tools, user memory summaries, and prelude exports visible through one
bounded, swappable renderer. Turn-aware reminder policy is Phase 2 and must not
expand the Phase 1 implementation unless explicitly requested.

## 2026-07-09 Amendment - Kernel Prompt Parity With SubAgent

The first symbol-inventory implementation proved the useful substrate, but the
current kernel prompt shape is still more verbose and more redundant than the
tested `SubAgent` prompt shape. In particular, the mini eval cases currently
carry task prose such as:

```text
Use context key numbers, available as data/numbers. Return the sum of all
numbers.
```

That wording is test-harness scaffolding, not an API contract. Users should be
able to write the mission naturally:

```text
Return the sum of all numbers.
```

and the runtime should separately render the Lisp-visible symbols:

```text
;; === data/ ===
data/numbers ; value list[3], sample: [2 4 6], use: data/numbers

<mission>
Return the sum of all numbers.
</mission>
```

The next implementation step is therefore **prompt parity**, not another live
A/B: make the kernel prompt composition closer to `SubAgent` while preserving
the kernel's prelude-configurable prompt policy.

Design boundary:

- host/Elixir owns the sanitized projection of facts and all authority filters;
- `agent.prompt` owns compact model-visible rendering and message placement;
- eval case task text must not duplicate symbol availability hints that the
  inventory already renders;
- raw `Context JSON` should be removed from the default kernel prompt unless a
  debug or explicit renderer policy opts into it;
- retry feedback may later include a compact symbol reminder, but that remains
  Phase 2 unless explicitly requested.

Implementation direction:

1. Pass sanitized `symbol_facts` into `cfg` in addition to the rendered
   fallback inventory and metadata.
2. Add a compact `agent.prompt/render-symbols` helper in the prompt prelude.
   The helper renders already-sanitized facts; it must not receive raw tools,
   raw memory, private prelude env, or raw host context.
3. Change `agent.prompt/task-message` to render symbols plus
   `<mission>...</mission>`, matching the tested `SubAgent` mental model.
4. Keep renderer choice prelude/config driven: a cell can swap prompt wording
   by swapping `agent.prompt`, while the host still validates renderer inputs
   and caps.
5. Update `PtcRunner.Kernel.Eval.mini_cases/0` so context cases use natural
   task text and rely on rendered inventory for `data/*` visibility.
6. Add golden unsafe-debug/mock tests for first-turn and retry-turn request
   shape, proving:
   - mission text has no duplicated `available as data/x` wording;
   - `data/x` appears in the symbol inventory as a value with `use: data/x`;
   - default prompt does not include raw `Context JSON`;
   - the system prompt stays domain-blind;
   - retry history remains valid provider message history.

Validation before any live model run:

```sh
mix test test/ptc_runner/kernel_test.exs \
  test/ptc_runner/kernel/eval_test.exs \
  test/ptc_runner/kernel/feedback_ab_test.exs \
  test/ptc_runner/symbol_inventory_test.exs
```

Only after deterministic prompt-shape tests pass should a new live smoke be
run. That smoke is descriptive and diagnostic only; it supersedes neither the
S19 feedback-only A/B nor any future preregistered M3 comparison.

## Short Goal Prompt

```text
Run the autonomous Symbol Inventory Rendering plan described in
docs/plans/lisp-kernel/autonomous-symbol-inventory-rendering.md.

Goal: introduce a shared, sanitized symbol-inventory projection for data,
mission/public tools, memory summaries, and prelude prompt exports, then render
it through a swappable policy component. The projection must distinguish
per-symbol kind (value vs function) from type, bounded sample/doc, and usage
shape. Keep runtime authority fixed: rendering may not grant capabilities,
expose hidden exports, expose kernel private tools, expose prelude source, or
read raw host memory.

Work risk-first: first prove prelude constants and data entries render as
values, not callable forms; then integrate the projection into the kernel
prompt path through an explicit `cfg["symbol_inventory"]` contract. Do not add
turn-aware renderer hooks in Phase 1. Update docs, tests, and prompt inventory
contracts.
```

## Objective

The C prompt-policy probe showed a concrete failure mode: the model sometimes
read `data/numbers` as callable syntax and tried `(data/numbers)`, then drifted
into invented APIs such as `get-context` and `tool/get-context`. The immediate
prompt fix is useful, but the durable fix is a better model-visible contract:
every visible symbol should say whether it is a value or a function and how it
is used.

This plan introduces a shared inventory layer. Bounded data samples are
intentionally model-visible mission context; they are not raw memory or
authority-bearing values. Secret-like samples must be suppressible before this
is launch-ready.

```elixir
%{
  ref: "data/numbers",
  kind: :value,
  type: "list[integer]",
  sample: "[2, 4, 6]",
  usage: "data/numbers",
  source: :data
}

%{
  ref: "crm/get-user",
  kind: :function,
  params: ["id"],
  doc: "Return a CRM user by id.",
  usage: "(crm/get-user id)",
  source: :prelude
}
```

The projection is fixed and trusted. Rendering is policy and may be swapped.
Later policies may render differently on turn 0, after an error, or after
compaction, but that is Phase 2.

## Scope

Read first:

- `AGENTS.md`
- `docs/plans/lisp-kernel/architecture.md` (Boundary, Prelude Layering, D5,
  D6, D17, D19)
- `docs/plans/lisp-kernel/roadmap.md` (standing gates, seam-and-value-shape
  checklist)
- `docs/plans/future/capability-kernel-runtime.md` (`RunEnv` option
  classification: context/prelude/tools/memory are eval inputs; rendering is
  sibling policy)
- `docs/plans/chunked-tool-results-and-data-prelude.md` (future `data/`
  helper namespace; do not consume the reserved namespace by accident)
- `lib/ptc_runner/lisp/prelude/prompt_inventory.ex`
- `lib/ptc_runner/lisp/prelude/export.ex`
- `lib/ptc_runner/sub_agent/namespace.ex`
- `lib/ptc_runner/sub_agent/namespace/data.ex`
- `lib/ptc_runner/sub_agent/namespace/user.ex`
- `priv/preludes/agent/prompt.lisp`

Substrate facts already present:

- `PtcRunner.Lisp.Prelude.Export` already carries `kind:
  :function | :constant`.
- `PtcRunner.Lisp.Prelude.PromptInventory` already renders prelude prompt
  exports from the same `%Export{}` records used by evaluator/discovery.
- `PtcRunner.SubAgent.Namespace.Data` already renders `data/*` with type and
  bounded sample.
- `PtcRunner.SubAgent.Namespace.User` already distinguishes closures from
  values and renders type/sample for values.
- `data/` is a host-owned reserved namespace. It should be presented like an
  inventory of symbols, but not implemented as a compiled prelude or granted
  new authority.
- `PtcRunner.Lisp.Prelude.PromptInventory` currently advertises `(source
  'ns/name)`. This plan's no-source-leak claim is only about renderer output
  unless D17 is resolved in the same session.

Allowed:

- add a new internal inventory projection module under `lib/ptc_runner/` or
  `lib/ptc_runner/kernel/`;
- extend or refactor `Prelude.PromptInventory` so constants render as values;
- reuse `SubAgent.Namespace.TypeVocabulary`, `SampleFormatter`, and signature
  rendering instead of inventing a parallel type vocabulary;
- add a swappable renderer option for the kernel prompt path;
- add a default renderer that preserves current behavior except for clearer
  value/function rendering;
- add focused deterministic tests and docs.

Avoid:

- changing runtime authority, capability grants, prelude visibility, or
  evaluator semantics;
- making `(data/x)` callable as an ergonomic fallback;
- replacing `data/x` with `(get data "x")` in the runtime contract;
- exposing raw prelude source in renderer output, private prelude env, hidden
  exports, kernel private tools, tool closures, raw host memory, or full
  memory values to the renderer;
- D4 canonical TurnEvent integration;
- D6 `*1`/`*2`/`*3` inner-eval history changes;
- D17 source-discovery masking beyond a documented follow-up;
- turn-aware reminder policy beyond the minimal future-shape note in Phase 2;
- implementing the paginated `data/` prelude helpers from
  `chunked-tool-results-and-data-prelude.md`.

## Design Contract

Separate two layers:

1. **Inventory projection** - trusted, fixed, sanitized, bounded facts.
2. **Inventory renderer** - swappable policy that turns facts into model text.

The renderer must not receive raw authority-bearing values. It receives only
the projected facts. A renderer bug may make the model less effective; it must
not grant a tool, expose hidden exports, leak raw source, or alter what Lisp
programs can evaluate.

### Safety Contract

- **Data samples:** bounded samples from mission context are allowed because the
  model already sees mission context. They must be capped, deterministic, and
  suppressible. Secret-like keys (`*_token`, `*_secret`, `password`, `api_key`,
  etc.) must render type/usage without sample by default, with tests.
- **Memory:** prompt rendering may consume only the existing
  `memory_summary.entries` projection (`name`, `kind`, preview/truncation
  metadata). It must never read the host memory Agent map, closure envs, or
  function bodies.
- **Prelude source:** Phase 1 guarantees only that renderer output does not
  include prelude source. Existing discovery forms such as `(source 'ns/name)`
  remain governed by D17. Do not claim source is unreachable until D17 is
  resolved and tested.
- **Tools:** inventory may include only mission-visible/public tools. It must
  exclude kernel private tools (`llm-complete`, `eval-program`, `log`) and any
  `%PtcRunner.Tool{visibility: :private}` entries.
- **Prelude exports:** inventory may include prompt-visible exports only.
  `:discoverable` exports remain discoverable through existing discovery paths
  but are not rendered in the prompt inventory unless an explicit future policy
  says otherwise.

Per-symbol fields:

- `ref` - Lisp-facing symbol, e.g. `"data/numbers"` or `"crm/get-user"`.
- `kind` - `:value` or `:function`. This is separate from type. Normalize
  source vocabularies here: prelude export `:constant` becomes inventory
  `:value`; prelude export `:function` remains inventory `:function`;
  memory-summary `"value"`/`"function"` strings become atoms.
- `source` - bounded atom such as `:data`, `:tool`, `:prelude`, `:memory`.
- `type` - optional human type label for values, reusing existing type
  vocabulary/signature rendering where possible.
- `params` - optional display arg names for functions.
- `doc` - optional bounded docstring/description.
- `sample` - optional bounded sample for safe values.
- `usage` - renderer-independent usage hint derived from `kind`, e.g.
  `"data/numbers"` or `"(crm/get-user id)"`.
- `visibility`/`effect`/`origin` - only if already sanitized and bounded.

Rendering rule:

```text
Use value symbols directly, e.g. data/items. Call only function symbols, e.g.
(crm/get-user data/id).
```

This is a per-symbol rule, not a namespace rule. A namespace may mix values and
functions.

## Build Tasks

### Phase 1 - Launch-Ready Substrate

1. **Prompt fix baseline**

   Confirm the default kernel system prompt contains the agreed minimal rules:

   ```text
   PTC-Lisp is Clojure-like and runs as an interactive REPL: each program is
   evaluated, errors are reported, and definitions made with def or defn remain
   available to later programs in the same task. Reuse persisted definitions
   instead of recomputing prior work.

   Use value symbols directly, e.g. data/items. Call only function symbols,
   e.g. (tool/name args). Context key x is available as data/x.
   ```

   Add or update a golden prompt test so this wording is pinned and remains
   domain-blind.

2. **Prelude constants render as values**

   Inspect `Prelude.PromptInventory.export_line/1` and
   `Prelude.Export.signature/1`. Add a failing test for a prelude:

   ```clojure
   (ns cfg "Config." {:visibility :prompt})
   (def default-limit "Default page limit." 25)
   (defn cap [n] (min n default-limit))
   ```

   Required rendering:

   - `cfg/default-limit` is shown as a value, not `(default-limit)`.
   - `cfg/cap` is shown as a function/callable form.
   - the docstring remains bounded.
   - discovery/report sanitized provenance is unchanged.
   - evaluator behavior for constants is not changed; this task changes prompt
     rendering only.

3. **Inventory projection module**

   Add a module that builds a list of symbol facts from:

   - context data (`data/*`) as `kind: :value`;
   - prelude prompt-visible exports using `%Prelude.Export{}` and
     `Export.kind`, normalized through the inventory kind vocabulary;
   - mission/public tools as `kind: :function`;
   - memory summary entries, when present, as `kind` from the summary.

   This module must not inspect private prelude env or full memory values. For
   data samples, reuse the existing bounded sample formatter. For types, reuse
   `TypeVocabulary` and signature-rendering helpers. If a helper currently
   lives under `SubAgent`, either reuse it directly with a note that teardown
   must preserve/promote it, or extract the minimal shared module in the same
   commit.

   Required exclusions:

   - kernel private tools: `llm-complete`, `eval-program`, `log`;
   - any private mission tool;
   - prelude private helpers and `:discoverable` exports in prompt rendering;
   - raw memory values, closure envs, and function bodies.

4. **Default renderer**

   Implement a default renderer over projected facts. It should be compact,
   deterministic, sorted, and bounded. Suggested shape:

   ```text
   ;; === available symbols ===
   data/numbers              ; value list[integer], sample: [2, 4, 6], use: data/numbers
   crm/get-user [id]         ; function, use: (crm/get-user id) - Return a CRM user by id.
   cfg/default-limit         ; value integer, use: cfg/default-limit
   ```

   Preserve the existing per-namespace cap behavior or replace it only with an
   equivalent bounded cap that reports omitted counts honestly.

5. **Kernel prompt integration**

   Thread the rendered inventory into the kernel prompt path without changing
   runtime capabilities. Phase 1 contract:

   - host builds the sanitized inventory facts from mission context,
     mission/public tools, optional memory-summary projection, and compiled
     prelude prompt exports;
   - host renders those facts using the selected renderer;
   - host passes the rendered string as `cfg["symbol_inventory"]`;
   - host passes bounded render metadata as `cfg["symbol_inventory_meta"]`
     (`renderer_id`, counts, omitted counts, source hash/renderer hash when
     available);
   - `agent.prompt/task-message` appends the rendered inventory to the initial
     user message after the task/context block, and `system-message` keeps only
     the stable syntax rule.

   This preserves "prompt assembly lives in preludes" for message composition:
   the host supplies only sanitized facts/rendered policy text, and the prompt
   prelude decides where it appears. Add a golden kernel prompt/request test
   proving the rendered inventory is present in the LLM request and no raw
   private fields are present.

6. **Swappable renderer policy**

   Add a bounded option for choosing the renderer. The default renderer must be
   stable and tested. Experimental renderers may differ in wording/layout only.
   A renderer option must validate fail-closed with a stable error; no unknown
   renderer should silently fall back during experiments.

   If the renderer itself is expressed as a prelude component, keep the same
   authority split: it receives sanitized inventory facts and returns text. Its
   source hash must appear in bundle provenance when swapped.

7. **Deterministic renderer-swap proof**

   Prove swappability without a live model and without changing runtime
   authority:

   - compile the same kernel runtime prelude twice, changing only the inventory
     renderer policy/component;
   - assert `agent.core`, `agent.feedback`, mission context, tools, and eval
     behavior are identical across both runs;
   - assert only the renderer/prompt component hash changes in provenance;
   - assert rendered inventory text changes in the expected bounded way;
   - assert private tools and hidden exports remain absent from both rendered
     outputs;
   - assert a model program can still evaluate the same PTC-Lisp expression
     under both renderers.

   If the renderer is not yet a prelude component in Phase 1, prove the
   equivalent host-level seam: same inventory facts, two renderer modules/ids,
   different rendered text, identical runtime eval path, and stable renderer
   id/hash in `cfg["symbol_inventory_meta"]`.

8. **Live prompt-comprehension smoke**

   After Phase 1 integration and deterministic tests pass, run one
   non-comparative live smoke on the exact failure mode from the C probe. This
   is not an A/B, not M3 evidence, and not a statistical claim. It only checks
   that the real model sees the value/function contract and no longer
   systematically treats `data/x` as callable.

   Command template:

   ```sh
   mix ptc.kernel_feedback_ab --live --model deepseek \
     --case context_aggregation --cell C --runs 10 \
     --stop-on-failure --allow-failures \
     --unsafe-debug-report reports/kernel_eval/debug-symbol-inventory-context.md
   ```

   Acceptance:

   - record pass/fail count and the prompt hash used;
   - inspect the first failure if any;
   - if a failure still uses `(data/x)`, `get-context`, or
     `tool/get-context`, the prompt/inventory contract is not launch-ready;
   - unsafe debug output is evidence for diagnosis only and must not be used as
     benchmark evidence or committed unless explicitly requested.

### Phase 2 - Deferred Reminder Policy

9. **Turn-aware render context**

   Do not implement this in Phase 1 unless explicitly requested. Record the
   future render context shape:

   - `turn`
   - `phase` (`initial`, `retry`, `after_error`, `compacted`)
   - `last_error_reason`
   - omitted counts / token budget hints when already available

   This enables later experiments on how often to remind the model of available
   symbols:

   - full inventory on turn 0;
   - compact reminder on retry;
   - focused reminder after `unknown_namespace`, `unbound_var`, or
     `unknown_tool`;
   - refresh after compaction.

   Do not run that policy A/B in this implementation session.

10. **Discovery alignment note**

   Do not implement full discovery changes unless they are already needed for
   tests. Add a follow-up note for:

   - `(ns-publics 'data)` returning projected `data/*` value facts;
   - `(doc 'data/numbers)` saying `kind: value` and usage `data/numbers`;
   - `(apropos "...")` using the same symbol inventory.

   This must be compatible with `docs/plans/chunked-tool-results-and-data-prelude.md`:
   future callable `data/*` helpers may coexist with data values, so the
   distinction remains per symbol.

## Plan Fit

- **Lisp kernel architecture:** This is policy rendering, not mechanism. It
  belongs beside `agent.prompt`, `agent.feedback`, and bundle provenance.
- **RunEnv future plan:** Context, prelude, tools, and memory remain eval
  inputs. Inventory rendering is sibling policy/projection and should not be
  folded into `RunEnv`.
- **Prelude PromptInventory:** This plan generalizes the current prelude-only
  renderer. It should extend/reuse it, not fork a competing prompt registry.
- **SubAgent namespace renderer:** Reuse or promote its type/sample formatting
  because teardown will otherwise delete useful substrate accidentally.
- **Data prelude / paginated reads:** This plan does not implement paging. It
  only reserves a representation where future `data/*` functions and current
  `data/*` values can coexist.
- **D17 source exposure:** Phase 1 does not resolve source discovery. Its
  guarantee is narrower: the renderer and rendered prompt inventory do not
  include prelude source. A later D17 task must decide whether `source` is
  masked for `agent.*` policy components.
- **S19 feedback A/B:** This is a prompt/inventory policy substrate, not a
  feedback-only A/B cell. Do not compare it against S19 feedback cells without
  a new preregistration.
- **D4 turn logs:** Out of scope. If reports include rendered inventory hashes,
  use the current sanitized event/report path and note that canonical TurnEvent
  evidence remains D4.

## Verification

Minimum deterministic checks:

- `Prelude.PromptInventory` renders `def` constants as values and `defn`
  exports as functions.
- `data/*` facts are `kind: :value`, include bounded type/sample, and never
  render as `(data/x)`.
- secret-like `data/*` keys render no sample by default.
- tool facts are `kind: :function`, render callable usage, and exclude kernel
  private tools plus private mission tools.
- memory-summary facts normalize existing `"value"`/`"function"` kind labels
  and consume only `memory_summary.entries`, not the memory Agent map.
- function memory entries render without captured env, source body, or raw
  closure internals.
- prelude `:constant` exports normalize to inventory `:value`; prelude
  `:function` exports normalize to inventory `:function`.
- renderer output is deterministic, sorted, capped, and reports omissions.
- renderer receives no raw prelude source, private env, tool closures, raw
  memory values, or full data beyond bounded samples.
- invalid renderer option fails closed.
- golden kernel prompt contains the value/function rule, includes
  `cfg["symbol_inventory"]` output, and remains domain-blind.
- rendered prompt inventory does not include `(source ...)` hints unless D17 is
  explicitly resolved in the same session.
- existing S19 report redaction tests still pass.
- `mix precommit`.
- independent `codex review` before launch-ready status.

Live checks are optional and must be non-comparative unless preregistered. A
single live smoke may verify that the default prompt still works, but it cannot
be reported as an A/B result.

## Deliverables

- Phase 1 shared symbol inventory projection.
- Phase 1 default bounded renderer.
- Kernel prompt integration through `cfg["symbol_inventory"]` and
  `cfg["symbol_inventory_meta"]`.
- Tests for value/function rendering, redaction, and invalid options.
- Documentation updates in architecture/roadmap/spikes as needed.
- A short Phase 2 note identifying future turn-aware reminder policy and
  discovery alignment, without implementing or running them.

## Stop Conditions

Stop and report if:

- implementing the renderer requires exposing unsuppressed sensitive data, raw
  memory, private prelude env, or prelude source to model-visible text;
- bounded data samples cannot be made suppressible for secret-like keys;
- `data/` cannot be projected without changing evaluator semantics;
- prelude constants cannot be distinguished from functions without extending
  compiler/export records;
- the integration cannot thread `cfg["symbol_inventory"]` without bypassing the
  prompt prelude;
- the renderer option would silently change capability grants;
- unrelated dirty state makes it unclear which prompt/hash/report changes are
  yours.
