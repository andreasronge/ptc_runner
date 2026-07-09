# Lisp Kernel — Architecture

**Status:** active experiment design, branch `exp/lisp-kernel`. This is the
durable reference for the kernel/prelude boundary; update it as spikes and
milestones land. The evolving task list lives in [`roadmap.md`](roadmap.md);
spike evidence lives in [`spikes.md`](spikes.md).

## The Bet

Rewrite the agent runtime as a **small kernel plus preludes**: keep PTC-Lisp
(~27k LOC) unchanged, replace the ~19.5k LOC `sub_agent/` machinery with a
kernel of roughly 300–600 LOC, and express everything that is *policy* — the
agentic loop itself, prompt assembly, feedback rendering, truncation wording
and caps — as PTC-Lisp preludes.

Why believe it: the irreducible mechanism in today's SubAgent loop is only
(1) call the LLM callback, (2) run a program in the sandbox under limits,
(3) honor the `(return v)` / `(fail v)` protocol, (4) enforce runaway guards
and telemetry. Everything else is policy hardcoded in Elixir, and the
"run program → build feedback → thread state" logic is triplicated across the
three transports (`loop.ex`, `ptc_tool_call.ex`, `text_mode.ex`).

The payoff being tested: **a policy change (e.g. a truncation-hint experiment)
becomes a prelude diff, A/B-measurable with zero Elixir changes.**

### Relationship to prior plan docs

- `docs/plans/future/programmable-agent-loop.md` explored "loop policy in
  preludes" and parked it — but what it rejected was a *hook framework bolted
  onto the production loop*, with its attribution and fallback burdens. Here
  the loop **is** the prelude, not a hook into an Elixir loop; most of those
  objections don't apply. Its one rule we keep: **the failure path stays
  host-owned** (see Boundary below).
- `docs/plans/future/capability-kernel-runtime.md` — the deferred `RunEnv`
  option classification (eval-input vs sibling policy) is the kernel's
  eval-input surface, already designed. Its appendix explicitly contemplates
  `(llm/call ...)` as a granted capability, never a global builtin.
- `docs/plans/future/model-visible-content-surfaces.md` — Treatment A
  (truncation hints) is the natural first A/B for the feedback prelude.
- `docs/plans/lisp-kernel/autonomous-symbol-inventory-rendering.md` — the
  follow-up substrate for presenting `data/`, tools, memory, and prelude
  exports through one sanitized symbol inventory. It is prompt/rendering policy,
  not runtime authority, and must stay compatible with the deferred `RunEnv`
  split.

## Boundary: Mechanism (kernel) vs Policy (prelude)

| Kernel owns (failure path, authority) | Prelude owns (optimization path) |
| --- | --- |
| Outer wall-clock deadline + heap cap | Turn loop structure, stop conditions below the backstop |
| LLM transport + call-counter budget (fail-closed) | Prompt assembly, message list construction |
| Native model-action protocol validation | Retry phrasing, must-return nudges |
| Strict sandbox for model programs (1s/10MB) | Feedback rendering, truncation caps + hint wording |
| Capability grants (which tools each level sees) | Context/memory slices the model is shown |
| `(return v)` / `(fail v)` sentinel protocol | Domain helpers and policy data |
| Telemetry / turn-event emission | Event annotations and policy labels |
| Prelude compilation + bundle provenance | Swappable policy components |

A buggy loop prelude may waste its budget; it must never be able to exceed it.
A crashed loop prelude surfaces as a kernel error with the bundle provenance
attached — never a silent hang.

## Two-Level Limits (verified)

The obvious objection — "the sandbox is 1s/10MB, an agent loop runs for
minutes" — dissolves because both limits are per-call options, verified in
`lib/ptc_runner/sandbox.ex`:

- `Sandbox.execute/3` takes `timeout:` (wall-clock ms) and `max_heap:` (words
  above a measured post-copy baseline; `0` disables). Defaults 1000ms /
  1_250_000 words are just defaults.
- Tool closures execute **inside** the sandbox process (`eval_fn.(ast,
  context)`, sandbox.ex:216), so a blocking multi-second LLM call simply
  consumes the outer run's generous timeout. No clock-pausing mechanism needed.
- `max_heap_size` is a per-process BEAM flag and is **not inherited** by
  child processes — a nested `Lisp.run` spawned from inside a tool closure
  gets its own fresh strict budget.

So:

- **Loop program** (trusted, host-authored prelude): `timeout:` = mission
  deadline, `max_heap:` relaxed (order 64MB, per the heap re-baseline work).
- **Model program** (untrusted, LLM-emitted): standard strict sandbox,
  spawned per-eval by a kernel capability.

Known wrinkle: if the outer sandbox is timeout-killed, an in-flight inner
sandbox is orphaned until its own 1s limit fires (acceptable; `link:` exists
if not). See spike S1.

## Copy-Volume Budget (risk)

The two-level sandbox is a security/resource-boundary design, not a free data
movement design. BEAM process isolation copies ordinary terms between process
heaps at every boundary:

1. host -> outer sandbox: loop AST, context, memory, tools/closures, compiled
   prelude environment;
2. outer sandbox -> inner sandbox: model source/AST, mission context, memory,
   and domain tools passed through `eval-program`;
3. inner sandbox -> outer sandbox: projected result, prints, memory/result
   values;
4. outer sandbox -> host: final loop result and telemetry/projection.

Large ref-counted binaries are a partial exception; nested maps/lists/tuples
are copied. `Sandbox.execute/3` re-baselines after the host grant is copied in,
so granted data is not billed against normal program heap headroom, but setup
copy time, setup heap, and GC pressure are still real. Oversized grants can
still die during setup via `:setup_max_heap`.

Design rule for the kernel:

- `eval-program` returns a bounded projection, never a raw `Step`.
- Inner eval context is mission data only; no language spec, prompt state,
  loop config, or full catalogs unless the model program needs them.
- Memory defaults toward host-held native state or opaque handles; the prelude
  may see bounded summaries/diffs/keys, not the full growing native memory map
  by default.
- Tool results and prints crossing back into the loop are capped before they
  become loop memory or feedback text.

Spike S5 measures this explicitly. Copy volume is treated as a third budget
beside wall-clock and heap.

## Model Action Protocol (V1)

V1 uses **native provider tool calling** as the only model action protocol. The
model receives normal chat messages plus exactly one model-visible tool:

```
run_ptc_lisp({
  "program": "(return ...)"
})
```

The PTC-Lisp source comes from the `program` tool argument, not from Markdown or
free-text code-fence extraction. Normal assistant text is a protocol error
unless D14 explicitly admits a terminal final-answer state. The default M1
posture is stricter: `(return v)` from an evaluated PTC-Lisp program is the
only successful model answer. That gives the experiment a sharper boundary:

- no code-fence parser in the loop prelude;
- every accepted model action is a tool call; everything else is a protocol
  error unless D14 later admits a terminal final-answer state;
- retry feedback can say "call `run_ptc_lisp` with a valid program" instead of
  explaining extraction rules;
- provider mechanics live at the LLM transport boundary.

The cost is that `llm-complete` is no longer `%{content, tokens}` only. It must
normalize provider responses into a transport-neutral action envelope:

```
%{
  content: String.t() | nil,
  tool_calls: [%{name: String.t(), arguments: map()}],
  tokens: map(),
  model: String.t(),
  provider: String.t() | nil,
  provider_meta: map()
}
```

The kernel then validates that envelope into one prelude-facing action:

- `{:tool_call, %{program: source, tokens: ..., meta: ...}}`
- `{:final, %{content: text, tokens: ..., meta: ...}}` only if D14 admits an
  explicit terminal final-answer state;
- `{:protocol_error, reason}` for missing/multiple/wrong tool calls, invalid
  arguments, or disallowed free text.

Free-text code extraction, Markdown parsing, structured-output-only mode, and
legacy text-code fallback are out of scope for V1. They may remain useful as
incumbent behavior to compare against, but they are not part of the kernel
action protocol.

`commentary` is deliberately excluded from the V1 schema until a spike shows it
improves trace quality or model compliance enough to justify the extra model
surface. If admitted later, it is metadata only: never executable program text,
never feedback instructions, and never a second answer channel.

## Capability Model

Kernel capabilities are entries in the **outer** run's `tools:` map, declared
with `visibility: :private` — hidden from LLM-facing discovery and callable
only by an active prelude export that carries them in its inferred
`tool_refs` (shipped private-tool authority, `PtcRunner.Tool` docs). The
inner eval receives only the mission's domain tools. So a model program can
never reach the LLM or the evaluator, and even within the outer sandbox only
`agent.core`'s own exports can — fail-closed by construction, defense in
depth by declaration.

```
Kernel.run(mission, cfg)
  1. bundle = compile the prelude components
       M1 (single namespace):  Bundle.compile([core_src])
       M2+ (layered):          Bundle.compile_precompiled(components,
                                 namespace_deps: %{"agent.core" => ["agent.feedback"]})
       NOTE: raw Bundle.compile/1 is dep-blind BY DESIGN (bundle.ex:56-61) —
       each namespace compiles in isolation (namespace_deps defaults to %{},
       compiler.ex:145-167), so an undeclared cross-namespace ref like
       (agent.feedback/config) fails "unknown namespace" even within one source
       blob. The layered bundle REQUIRES declared deps via
       compile_precompiled/2 or a store-resolved attach.
  2. capabilities = %{
       # all three use the {fun, visibility: :private} options form —
       # a bare closure normalizes to :public (tool.ex:159, 270-299)
       "llm-complete"  => {counted, budget-capped wrapper over the LLM callback;
                          sends the run_ptc_lisp tool schema, normalizes provider
                          responses into the action envelope above, validates the
                          V1 model-action protocol, and returns a prelude-facing
                          action value; tokens feed metrics + budget,
                          visibility: :private},
       "eval-program"  => {fn %{"src" => s, "memory" => m, ...} ->
                             PtcRunner.Lisp.run(s, context: mission_ctx, memory: m,
                                                tools: mission_tools,
                                                timeout: 1_000, max_heap: strict)
                             |> project_step()  # -> {:ok :return :fail :prints :memory}
                           end, visibility: :private},
       "log"           => {telemetry sink, visibility: :private} }
     # M1 hardcodes this trio. R24/S10 decide whether additional private
     # capabilities can be supplied by config/bundle selection without editing
     # PtcRunner.Kernel.run/2.
  3. PtcRunner.Lisp.run("(agent/run-mission data/mission data/cfg)",
                        prelude: bundle, tools: capabilities,
                        context: %{mission: ..., cfg: ..., language_spec: ...},
                        timeout: deadline_ms, max_heap: relaxed)
  4. Host backstops: outer deadline, outer heap, LLM-call counter.
```

The kernel reuses `PtcRunner.Lisp`, `PtcRunner.LLM`, `PtcRunner.Sandbox`,
`Prelude.Compiler`/`Bundle`, and (for measurement) `PtcRunner.TraceLog`
untouched. It renders the language-spec prompt host-side from the existing
`priv/prompts/` templates and hands it to the prelude as *data* — the prompt
prelude decides how to compose it.

## Prelude Layering (config as composable preludes)

Composition is shipped mechanism, all in core `ptc_runner`:

- `PtcRunner.Lisp.Prelude.Bundle.compile/1` — order-preserving source
  concatenation, duplicate-namespace rejection, one aggregate compile,
  per-component provenance in `prelude.metadata`. **Dep-blind by design**:
  cross-namespace calls between components need declared deps via
  `compile_precompiled/2` + `namespace_deps:` or a store-resolved attach
  (bundle.ex:56-72; R5 pins the call shape we use).
- `PtcRunner.PreludeStore` — `requires_preludes` (`id@version` pins,
  transitive resolution, `namespace_deps:` compile scoping).

Layering:

```
agent.core      — the loop: turn iteration, return/fail handling, budget wind-down
  requires ───► agent.prompt    — system/task/catalog rendering
  requires ───► agent.feedback  — eval-result rendering, truncation caps + hints
                domain.*        — optional problem helpers (never required by agent.*)
```

**Naming.** Dotted names (`agent.core`, `agent.prompt`, `agent.feedback`) are
the declared PTC-Lisp namespaces for M2, not only component/file IDs. A source
probe on 2026-07-08 confirmed `(ns agent.core ...)` compiles, so the loop call
site becomes `(agent.core/run-mission ...)`, with cross-namespace policy calls
such as `agent.feedback/eval-feedback`.

- Policy *data* is a constant export: `(def config {:max-chars 1200 ...})` in
  a policy namespace; the loop reads `agent.feedback/config`.
- **Swapping a policy = swapping one component in the bundle list** (same
  namespace name, different source). Bundle provenance records which version
  ran. An A/B cell is two bundles differing in one component.
- `agent.*` preludes are subject to the repo's **domain-blind rule**
  (CLAUDE.md): no hints about test data, benchmark domains, or expected
  answers. Only `domain.*` components may reference their own domain.

## Verified substrate facts

Claims above rest on these, checked 2026-07-07 on `main`:

1. `Sandbox.execute/3` per-call `timeout:`/`max_heap:`; tool closures run in
   the sandbox process; heap flag not inherited (sandbox.ex:157–232, moduledoc).
2. `Bundle.compile/1` + `compile_precompiled/2` with `namespace_deps:`
   (lib/ptc_runner/lisp/prelude/bundle.ex); `requires_preludes` handling in
   core `lib/ptc_runner/prelude_store.ex`.
3. Prelude source format: `(ns name "doc" {meta})`, `defn`/`defn-`/`def`,
   `:prompt`/`:discoverable` visibility, namespace-scoped `private_env`,
   reserved namespaces `tool`/`data`/`budget`/`mcp`/`ptc.core`
   (protected_namespaces.ex:30; docs/guides/capability-prelude.md,
   lisp/prelude.ex).
4. Language adequacy for the loop: `loop`, `recur`, `re-find`, `re-matches`,
   `re-seq`, `format`, `str` all in the 354-builtin registry
   (priv/functions.exs).
5. LLM callback contract: 1-arity fn over `%{system:, messages: [%{role:,
   content:}]}`. Real callbacks built by `PtcRunner.LLM.callback/2` return
   `{:ok, %{content: String.t(), tokens: tokens()}}` for text responses and may
   return native tool-call response shapes (`llm.ex` response types). Inline
   test lambdas may return bare text/action fixtures. The kernel's
   `llm-complete` must normalize supported shapes into the V1 action envelope
   and must not drop `tokens`.
6. `Step` carries `return`, `fail`, `memory`, `prints: [String.t()]`, `usage`
   (lib/ptc_runner/step.ex) — the source fields for `project_step/1`.
7. Direct tools are `tools: %{"name" => closure}` called as `(tool/name args)`;
   closures may return arbitrary values. Tools support
   `visibility: :private`: hidden from discovery, callable only by prelude
   exports that declare them in inferred `tool_refs` (lib/ptc_runner/tool.ex).
8. The tool-arg boundary is **normalizing, not transparent** (anti atom-leak,
   JSON-convention): map keys are stringified recursively and `LispKeyword`
   *values* collapse to plain name strings (eval.ex ~1166–1270). Tuples pass
   the catch-all untouched, and `{:closure, ...}` tuples are intentionally
   preserved in native memory projection (lisp.ex:1209). Consequence: memory
   value-threaded through `eval-program` args keeps closures but is lossy for
   keyword values — a semantic change vs today's host-side memory threading.
   This tilts D1 toward host-held memory; S2 measures it.
9. Sandbox heap re-baselining excludes copied-in host grants from the program's
   post-baseline heap headroom, but it does not eliminate BEAM term-copy cost or
   setup pressure. Host grants still consume setup heap/time and can fail during
   setup when `:setup_max_heap` is too low (sandbox.ex moduledoc). S5 measures
   the copy-volume budget for the nested kernel path.
10. Vertical-slice kernel evidence, 2026-07-07: `PtcRunner.Kernel.run/2`
    can compile a minimal `agent/run-mission` prelude, grant private
    `llm-complete`/`eval-program`/`log` tools, normalize one native
    `run_ptc_lisp` action, run the model program through strict inner
    `Lisp.run/2`, and return a bounded eval projection. Mock coverage is in
    `test/ptc_runner/kernel*_test.exs`; live smoke
    `mix test test/ptc_runner/kernel/e2e_test.exs --include e2e` passed on
    `openrouter:deepseek/deepseek-v4-flash`.
11. ReqLLM/OpenRouter mechanics observed in the live smoke: `temperature`
    must be a float (`0.0`, not `0`); `tool_choice` must be forwarded by
    `PtcRunner.LLM.ReqLLMAdapter` and uses map form
    `%{type: "tool", name: "run_ptc_lisp"}`. With that shape, a direct
    DeepSeek/OpenRouter probe returned exactly one tool call with
    `args: %{"program" => "(return 42)"}` plus token fields
    `input`, `output`, `cache_read`, `cache_creation`, and `total_cost`.
12. Retry transport evidence, 2026-07-08: the kernel sends the system prompt
    once through the LLM request `:system` channel, not as a synthetic system
    message in the message list. Prelude-built retry messages are normalized
    into the atom-keyed `ReqLLMAdapter.build_messages/1` contract before
    transport. Assistant retry messages include `content: nil` and clean
    atom-keyed tool-call structs; tool feedback is JSON with `type`,
    `instruction`, and `untrusted_eval_result`, so eval output is data, not
    instructions. `test/ptc_runner/kernel_test.exs` covers this adapter
    boundary and `test/ptc_runner/kernel/e2e_test.exs` includes a live
    two-turn DeepSeek retry smoke.
13. LLM error handling evidence, 2026-07-08: `llm-complete` distinguishes LLM
    transport failures from model protocol errors. `{:error, reason}` from the
    callback becomes a prelude-visible `transport_error`, and the loop returns
    a kernel error with reason `llm_transport_error`; it is not fed back to the
    model as a recoverable protocol mistake.
14. M2 2a compile-path evidence, 2026-07-08:
    `agent.core` can call public `agent.feedback/*` exports when the build uses
    the repo-supported layered path. Exact shape:
    first compile the dependency namespace, compile the dependent namespace with
    `Compiler.compile(core_source, deps: [feedback], namespace_deps:
    %{"agent.core" => ["agent.feedback"]})`, then assemble with
    `Bundle.compile_precompiled([...], namespace_deps:
    %{"agent.core" => ["agent.feedback"]})`. Raw `Bundle.compile/1` remains
    dep-blind and fails with `unknown namespace` plus the `requires_preludes`
    hint. Focused evidence:
    `mix test test/ptc_runner/kernel/prelude_split_test.exs`. In that proof,
    `agent.feedback/eval-feedback` carries empty `tool_refs`, while
    `agent.core/run-once` carries exactly `eval-program`, `llm-complete`, and
    `log`; direct model/user calls to private kernel tools still fail with
    `:private_tool_unauthorized`.
15. M2 full split evidence, 2026-07-08: default kernel policy source now lives
    in `priv/preludes/agent/core.lisp`, `prompt.lisp`, and `feedback.lisp`.
    `PtcRunner.Kernel.compile_prelude/1` compiles the full graph
    `agent.core -> [agent.prompt, agent.feedback]` with
    `Bundle.compile_precompiled/2`; `PtcRunner.Kernel.run/2` invokes
    `(agent.core/run-mission data/mission data/cfg)`. Prompt policy renders
    the request-level system string in `agent.prompt/system-message`, and the
    host forwards it as the single request `:system` channel through the
    private `llm-complete` args. The explicit Elixir `:system_prompt` opt still
    wins as a test/live override. A variant `agent.core` that omits the
    `"system"` arg now fails closed with `:missing_system_prompt`; there is no
    Elixir default prompt renderer fallback. Focused evidence:
    `mix test test/ptc_runner/kernel/action_test.exs test/ptc_runner/kernel_test.exs test/ptc_runner/kernel/prelude_split_test.exs`.
    The same tests prove a feedback-only source override changes retry wording
    without changing the Elixir loop path.
16. M2 mini eval evidence, 2026-07-08: `PtcRunner.Kernel.Eval` and
    `mix ptc.kernel_eval --suite mini` provide the first repeatable kernel eval
    path in `lib/` without `test/support` dependencies. It resolves live model
    aliases through `PtcRunner.LLM.Registry` (`deepseek` ->
    `openrouter:deepseek/deepseek-v4-flash`), defaults to deterministic mock
    mode, checks each case against an explicit expected value, and prints a
    sanitized markdown report with per-case status, `action_count`, `eval_count`,
    failure reason, and bounded trace metadata. The default report excludes raw
    prompts/messages, raw provider dumps, tool call payloads, and
    API-key-looking strings; the successful kernel return trace also keeps only
    action summaries, not generated programs or public tool-call args. Inner
    model evals receive the caller's `max_tool_calls` cap while still forcing
    `prelude: nil`, `runtime: nil`, and `discovery_exec: nil`; evidence:
    `mix test test/ptc_runner/kernel_test.exs test/ptc_runner/kernel/eval_test.exs`.
    Live DeepSeek evidence after prompt-prelude context/tool syntax changes:
    `mix ptc.kernel_eval --suite mini --live --model deepseek --allow-failures`
    returned 3/5 pass in the oracle-checked full run: arithmetic 1/1, context
    filter/count 2/2, context aggregation failed after 5/5 with
    `turn_limit_exceeded`,
    domain tool failed after 2/2 with `expected_mismatch` because the model
    returned `%{"score" => 9}` instead of scalar `9`, forced eval retry 2/2. A
    separate single-case aggregation probe
    passed 1/1, so aggregation is possible but unstable.
    M3 host-held memory update: the suite now includes `memory_persistence`;
    a focused live memory run passed 1/1, and the full six-case live run passed
    4/6. `context_aggregation` still failed after 5/5 in that full run, while
    `domain_tool` stayed red with the same scalar-extraction mismatch.
17. S19 provenance evidence, 2026-07-08: `PtcRunner.Kernel.run/2` emits one
    run-start `prelude` event when an `events` callback is supplied. The raw
    event is sourced from `PtcRunner.Lisp.Prelude.trace_summary/1`, whose
    component list is populated from `prelude.metadata.components`; the eval
    runner report then preserves only bounded provenance fields: aggregate
    `source_hash`, `artifact_hash`, protected namespaces, and per-component
    `id`, `checksum`, `source_hash`, `namespaces`, and bounded/redacted
    `origin`. The report trace does not include prelude source, prompt text,
    model programs, raw feedback wording, raw eval values, or raw host-held
    memory. Focused evidence:
    `mix test test/ptc_runner/kernel/eval_test.exs test/ptc_runner/kernel/prelude_split_test.exs`.
    The S19 frozen variants prove a feedback-only swap changes only the
    `agent.feedback` component hash while `agent.prompt` and `agent.core`
    hashes remain fixed.
18. Prompt syntax correction, 2026-07-08: the kernel prompt now teaches the
    per-symbol distinction that caused the C probe failure: value symbols are
    used directly, while only function symbols are called. This is a prompt
    policy fix, not a runtime change; `(data/x)` is still not made callable.

## Open decisions

Record the resolution here when made:

- **D1 — Memory threading.** Value-threaded through `eval-program` args
  (elegant: memory is just data in the loop) vs host-held native state or an
  opaque memory token. Decided by spikes S2 and S5. Verified fact 8 shows
  value-threading is lossy for keyword values at the arg boundary; fact 9 adds
  copy/setup pressure for a growing memory map. The likely default is
  host-held memory unless the spikes show both semantics and copy volume remain
  acceptable. M3 partial evidence, 2026-07-08: host-held native memory in
  `Kernel.run/2` proves both value and closure persistence across retry turns
  without exposing raw memory to the prelude. The host commits the memory map
  returned by `Lisp.run_native/2` with `preserve_runtime_callables: true`;
  runtime errors currently return prior memory, so partial definitions before
  runtime errors are not commit-visible without a lower-level evaluator change.
- **D2 — Kernel module home.** RESOLVED for M1 spike 2026-07-07:
  `PtcRunner.Kernel` in core `lib/ptc_runner/`, with helpers under
  `lib/ptc_runner/kernel/`. This keeps the slice close to `Lisp.run/2`,
  `Tool`, and `LLM` contracts. Release/API stability remains D18.
- **D3 — Prelude file home.** RESOLVED for M2 spike 2026-07-08:
  `priv/preludes/agent/*.lisp`, referenced by `@external_resource`, embedded
  into `PtcRunner.Kernel` module attributes for default runtime use, and
  included in the package file list plus release smoke required paths. This
  mirrors the inspectable `priv/prompts/` convention while keeping the split
  policy source swappable in tests via `PtcRunner.Kernel.compile_prelude/1`
  source overrides. Release/API stability remains D18.
- **D4 — Turn events.** RESOLVED 2026-07-09: the kernel is the third
  canonical `PtcRunner.TraceLog.TurnEvent` driver beside Session and SubAgent.
  It emits one sanitized event per LLM/eval turn through
  `TraceLog.record_turn_event/1`, preserving the existing `:events` /
  `:unsafe_debug` channel as ephemeral harness/debug output. Focused evidence:
  `mix test test/ptc_runner/kernel_test.exs test/ptc_runner/kernel/eval_test.exs test/ptc_runner/kernel/feedback_ab_test.exs test/ptc_runner/trace_log/turn_log_integration_test.exs test/ptc_runner/trace_log/turn_event_test.exs`.
  Autonomous plan:
  [`autonomous-d4-kernel-turn-events.md`](autonomous-d4-kernel-turn-events.md).
- **D5 — Step projection shape.** Initial M1 spike shape, verified
  2026-07-07: `eval-program` returns a bounded map with string status
  `"return" | "fail" | "error" | "continue"`, public `value` only for
  return/fail/continue, bounded `prints`, and error reason/message for host
  eval errors. It deliberately does not expose raw `%Step{}` or native memory.
  M3 partial update, 2026-07-08: the projection now adds bounded
  `memory_summary` with sorted defined names, changed names, per-entry
  kind/preview/truncation, summary truncation, omitted count, and measured
  `memory_bytes`; raw memory remains host-only. Compatibility decision:
  this keeps the incumbent SubAgent memory concepts but uses kernel-shaped
  names: `defined` is the bounded `stored_keys` equivalent, `changed`/`entries`
  split the incumbent changed-preview map into names plus preview records, and
  `truncated` preserves the incumbent truncation signal. Byte-cap breaches
  project as stable `memory_limit_exceeded` eval errors and preserve prior
  committed memory.
- **D6 — turn_history.** Whether inner evals get `*1`/`*2`/`*3` threading in
  V1 (probably not; loop can pass prior results as context/memory).
- **D7 — capability visibility.** RESOLVED 2026-07-07, sharpened for M2
  2026-07-08: `llm-complete`, `eval-program`, `log` are
  `visibility: :private` tools authorized by inferred export `tool_refs`, not
  namespace membership alone. M2 should keep `agent.prompt/*` and
  `agent.feedback/*` exports tool-free and assert that only the loop export
  carries the kernel trio. This reuses shipped private-tool authority instead
  of relying on "the outer env is trusted anyway". (Review round 1 finding.)
- **D8 — Eval harness home.** Where the lifted case data, oracle core,
  SampleData, and SearchTool live so that `mix ptc.kernel_eval` (a `lib/`
  mix task) can reach them without `MIX_ENV=test`. Working recommendation:
  `lib/ptc_runner/kernel/eval/` — shipped in the 0.x lib for the experiment,
  deleted or promoted with the verdict. Alternatives (demo/ stays entangled
  with its singleton Agent; `test/support/` is invisible to mix tasks)
  rejected for the reasons in parentheses.
- **D9 — Model action protocol.** RESOLVED 2026-07-07: V1 is native
  tool-call-only. The model must call `run_ptc_lisp`; free-text code
  extraction, Markdown parsing, structured-output-only mode, and legacy
  text-code fallback are out of scope.
- **D10 — Kernel error envelope.** Stable categories and rendering for prelude
  compile/runtime errors, private capability denial, LLM failure, protocol
  error, inner eval parse/eval/fail, timeout, heap/setup heap, and budget
  exhaustion. R15/R16/D5 feed the exact shape.
- **D11 — LLM budget and provider controls.** Preflight prompt budget, max
  output/reasoning budget, retry accounting, provider routing/fallback,
  generation controls, and token/cost fields. R16 resolves the contract.
- **D12 — Parallel policy.** Whether `agent.core` may use `pmap`/`pcalls`, what
  shared counters back LLM/eval budgets, and outer/inner `pmap_*`/worker heap
  settings. R21 resolves this before M1/M2 code relies on parallelism.
- **D13 — Host-held state lifecycle.** If D1 chooses host-held memory or opaque
  handles, define owner process, monitors, timeout/crash cleanup, token
  invalidation, caps, and journal/tool-cache policy.
- **D14 — Minimal model action surface.** Whether V1 remains `program`-only
  forever, admits optional `commentary` as non-instruction metadata, or admits
  any terminal final-answer text. Default M1 stance: `program` only, no final
  text; S6/R23 must justify any expansion.
- **D15 — Extension seam.** Whether future private capabilities are configured
  through a generic kernel extension contract or require explicit
  `PtcRunner.Kernel` edits. R24/S10 resolve before any promotion claim that
  policy changes are prelude-only beyond the first feedback A/B.
- **D16 — Soak and deployment envelope.** Long-run accumulation limits,
  per-node/concurrent mission caps, trace backpressure behavior, and HTTP pool
  health. R22/S11 resolve before M2/M3 claims.
- **D17 — Prelude source exposure.** Whether model programs may inspect
  `agent.*` / `feedback.*` implementation source via source-discovery
  mechanisms. If yes, the domain-blind audit includes exposed source; if no,
  source discovery for kernel policy components must be masked.
- **D18 — Release/API shape.** Whether kernel modules, eval harnesses, and
  preludes are experiment-internal, public experimental API, or shipped stable
  surface; includes package/release-smoke treatment for `priv/preludes`.
- **D19 — Symbol inventory rendering.** Phase 1 substrate landed 2026-07-08:
  `PtcRunner.SymbolInventory` projects sanitized facts for `data/`, public
  tools, memory-summary entries, and prompt-visible prelude exports with
  per-symbol `kind` (`value` vs `function`), type/sample/doc, and usage shape.
  The kernel prompt path passes rendered text and bounded metadata through
  `cfg["symbol_inventory"]` / `cfg["symbol_inventory_meta"]`; renderers receive
  only facts and may be swapped fail-closed. Turn-aware reminder policy remains
  deferred. D17 is not resolved: source discovery remains a separate policy
  question, but renderer output does not advertise or include prelude source.
- **D20 — Role-backed prelude selection.** Partially implemented 2026-07-09:
  the kernel now has `PtcRunner.PreludeRolePolicy`, `PtcRunner.PreludeRuntime`,
  role-backed `Kernel.compile_prelude/1`, source-free
  `role_prelude_selection` provenance, and per-write `PreludeStore.write/5`
  origins. The decision remains: use the existing MCP session role concept as
  the long-term kernel authority and allowed-surface abstraction instead of a
  separate "profile" layer. A role's `preludes` key keeps MCP allowlist
  semantics; a kernel run requests `preludes:` within that allowlist or falls
  back to role `default_preludes`. Source loading remains host-side and writes
  into `PreludeStore`; Lisp code must not load files/HTTP/database directly.
  Presentation options such as symbol-inventory renderer stay run-level until a
  namespaced, cross-surface extension is designed. Remaining closeout is the
  equivalence/parity and parser/config hardening in the autonomous plan:
  [`autonomous-role-backed-prelude-selection.md`](autonomous-role-backed-prelude-selection.md).

## Out of scope for the experiment

MCP server, compaction, journal/plans/progress, legacy SubAgent text mode,
legacy SubAgent `tool_call` transport, compiled agents, budget introspection,
sessions, upstream runtime.
Nothing here migrates the measured incumbent SubAgent loop until the experiment
earns a verdict. The branch may still delete obsolete non-baseline docs,
config, tests, prompts, or scaffolding when the new boundary has replaced them
and the repo stays coherent at each step.
