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

## Boundary: Mechanism (kernel) vs Policy (prelude)

| Kernel owns (failure path, authority) | Prelude owns (optimization path) |
| --- | --- |
| Outer wall-clock deadline + heap cap | Turn loop structure, stop conditions below the backstop |
| LLM transport + call-counter budget (fail-closed) | Prompt assembly, message list construction |
| Strict sandbox for model programs (1s/10MB) | Program extraction from LLM text |
| Capability grants (which tools each level sees) | Feedback rendering, truncation caps + hint wording |
| `(return v)` / `(fail v)` sentinel protocol | Retry phrasing, must-return nudges |
| Telemetry / turn-event emission | What context/memory slices the model is shown |
| Prelude compilation + bundle provenance | Domain helpers |

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
                                 namespace_deps: ...)   # exact shape: R5
       NOTE: raw Bundle.compile/1 is dep-blind BY DESIGN (bundle.ex:56-61) —
       each namespace compiles in isolation (namespace_deps defaults to %{},
       compiler.ex:145-167), so an undeclared cross-namespace ref like
       (feedback/config) fails "unknown namespace" even within one source
       blob. The layered bundle REQUIRES declared deps via
       compile_precompiled/2 or a store-resolved attach.
  2. capabilities = %{
       # all three use the {fun, visibility: :private} options form —
       # a bare closure normalizes to :public (tool.ex:159, 270-299)
       "llm-complete"  => {counted, budget-capped wrapper over the LLM callback;
                          normalizes both callback shapes ({:ok, %{content:,
                          tokens:}} from LLM.callback/2 per llm.ex:78, and bare
                          {:ok, text} from test lambdas) into one prelude-facing
                          map %{content, tokens}; tokens feed metrics + budget,
                          visibility: :private},
       "eval-program"  => fn %{"src" => s, "memory" => m, ...} ->
                            PtcRunner.Lisp.run(s, context: mission_ctx, memory: m,
                                               tools: mission_tools,
                                               timeout: 1_000, max_heap: strict)
                            |> project_step()   # -> {:ok :return :fail :prints :memory}
                          end,
       "log"           => telemetry sink }
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

**Naming.** Dotted names (`agent.core`, `agent.feedback`) are *component/file
ids* in the bundle list. The declared PTC-Lisp namespace names are the bare
`agent`, `prompt`, `feedback` — hence call sites `(agent/run-mission ...)`
and `feedback/config`. Whether dotted namespace names are even legal in
`(ns ...)` is unverified; R5 settles it, and the two schemes may then be
collapsed into one.

- Policy *data* is a constant export: `(def config {:max-chars 1200 ...})` in
  a policy namespace; the loop reads `feedback/config`.
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
   `{:ok, %{content: String.t(), tokens: tokens()}}` (`@spec` llm.ex:153,
   response type llm.ex:78); inline test lambdas may return bare
   `{:ok, text}`. The kernel's `llm-complete` must normalize both and must
   not drop `tokens`.
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

## Open decisions

Record the resolution here when made:

- **D1 — Memory threading.** Value-threaded through `eval-program` args
  (elegant: memory is just data in the loop) vs host-held in the closure.
  Decided by spike S2. Verified fact 8 already shows value-threading is lossy
  for keyword values at the arg boundary, so the likely outcome is host-held
  memory (or an opaque memory token) unless S2 shows the lossiness doesn't
  bite in practice.
- **D2 — Kernel module home.** `PtcRunner.Kernel` in `lib/ptc_runner/kernel/`
  (working assumption; 0.x, breaking changes fine) vs a separate Mix project.
- **D3 — Prelude file home.** `priv/preludes/agent/*.lisp` compiled in via
  `@external_resource` (mirrors `priv/prompts/` convention) vs plain files
  loaded at runtime.
- **D4 — Turn events.** Kernel emits `PtcRunner.TraceLog.TurnEvent` per
  llm/eval pair (recommended: keeps existing metrics/introspection working for
  A/B measurement) vs new minimal log. Supporting precedent:
  `TraceLog.record_turn_event/1` is documented as *the single emission point
  shared by both turn drivers* (Session and the SubAgent loop), and
  `test/ptc_runner/trace_log/turn_log_integration_test.exs` asserts both
  drivers emit the same top-level event shape — the kernel would become the
  third driver under the same emission point and parity test.
- **D5 — Step projection shape.** Exact map `eval-program` returns to the
  loop; start minimal (`:ok :return :fail :prints :memory`) and grow only on
  demonstrated need.
- **D6 — turn_history.** Whether inner evals get `*1`/`*2`/`*3` threading in
  V1 (probably not; loop can pass prior results as context/memory).
- **D7 — capability visibility.** RESOLVED 2026-07-07: `llm-complete`,
  `eval-program`, `log` are `visibility: :private` tools declared by
  `agent.core`'s exports — reuses shipped private-tool authority instead of
  relying on "the outer env is trusted anyway". (Review round 1 finding.)
- **D8 — Eval harness home.** Where the lifted case data, oracle core,
  SampleData, and SearchTool live so that `mix ptc.kernel_eval` (a `lib/`
  mix task) can reach them without `MIX_ENV=test`. Working recommendation:
  `lib/ptc_runner/kernel/eval/` — shipped in the 0.x lib for the experiment,
  deleted or promoted with the verdict. Alternatives (demo/ stays entangled
  with its singleton Agent; `test/support/` is invisible to mix tasks)
  rejected for the reasons in parentheses.

## Out of scope for the experiment

MCP server, compaction, journal/plans/progress, text mode, `tool_call`
transport, compiled agents, budget introspection, sessions, upstream runtime.
Nothing here migrates the existing SubAgent — `exp/lisp-kernel` is additive
until the experiment earns a verdict.
