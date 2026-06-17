# Run Environment and Future Capability Runtime

**Status:** the closed-context borrowed-closure lifetime guard has SHIPPED. The
`PtcRunner.Lisp.RunEnv` refactor is deferred — this doc is the active
architecture source for it (durable option-classification guidance plus the
deferred `RunEnv` struct/API and future runtime/kernel design notes).

## Goal

Separate an immediate borrowed-capability lifetime bug fix from a future typed
Lisp run-environment refactor.

The work is intentionally sequenced:

1. **Delivered:** borrowed upstream closures that start after
   `RunContext.close/1` fail before upstream side effects.
2. **Keep as durable design guidance:** preserve the eval-input vs sibling-policy
   option classification table so new options land in the right bucket.
3. **Defer until the conversation control plane becomes committed work:** add
   `PtcRunner.Lisp.RunEnv`, teach `PtcRunner.Lisp.run/2` to accept
   `env: %RunEnv{}`, and project `PtcRunner.Upstream.RunContext` into it.

`PtcRunner.Upstream.Eval` already keeps Lisp evaluation owned by
`PtcRunner.Lisp`: `run_lisp_with_records/3` is a thin `with_run_context/3` +
`eval_options/1` + `Lisp.run/2` convenience. `RunEnv` would make that projection
typed and explicit; it is not required to remove a current provider-owned
evaluation path.

Near-term non-goals:

- no neutral `PtcRunner.Runtime` or provider behaviour;
- no `PtcRunner.Lisp.RunEnv` implementation;
- no `env: %RunEnv{}` path on `PtcRunner.Lisp.run/2`;
- no `RunEnv.from_run/2` or `RunEnv.from_capabilities/2`;
- no public `isolation: :none`;
- no deprecation of legacy flat `Lisp.run/2` options;
- no Lisp-facing conversation control plane.

## Boundaries

The target architecture boundary, if/when `RunEnv` ships, is:

```text
RunEnv
  evaluation inputs and borrowed callable capabilities

Sibling run options
  execution policy, resource limits, output rendering, and instrumentation

Upstream RunContext
  lifecycle, counters, collectors, upstream runtime handle, and close boundary
```

Three run nouns must stay distinct:

- `PtcRunner.Lisp.RunEnv` would be the input surface for one Lisp evaluation. It
  would not own lifecycle. It is deferred (this doc is its design source).
- `PtcRunner.Upstream.RunContext` is the closeable upstream lifecycle boundary.
  It owns counters, collectors, and borrowed closure validity. Its close-boundary
  guard has shipped.
- Future names such as `RunScope` or `PtcRunner.Runtime.*` are deferred and
  non-binding.

## Option Classification

Rule: if an option changes what the program computes over or observes during
evaluation, it belongs in the eventual `RunEnv`. If it changes resource policy,
sandboxing, parallelism, instrumentation, or post-eval rendering, it remains a
sibling option to `Lisp.run/2`.

| Option | V1 home | Reason |
| --- | --- | --- |
| `:context` | `RunEnv.context` | Program reads it through `data/*`. |
| `:memory` | `RunEnv.memory` | Program reads and extends user namespace. |
| `:turn_history` | `RunEnv.turn_history` | Program reads `*1`, `*2`, `*3`. |
| `:prelude` | `RunEnv.prelude` | Program sees prelude exports. |
| `:tools` | `RunEnv.tools` | Program calls `tool/*`. |
| `:discovery_exec` | `RunEnv.discovery_exec` | Program calls discovery forms. |
| `:signature` | `RunEnv.signature` | Program return is validated against it. |
| `:tool_cache` | `RunEnv.tool_cache` | Program can observe cached tool behavior. |
| `:strict_data` | `RunEnv.strict_data` | Program observes missing data as error vs `nil`. |
| `:budget` | `RunEnv.budget` | Program reads budget introspection data. |
| `:runtime` | `RunEnv.runtime` | Borrowed validation handle for prelude `requires`. |
| `:timeout` | sibling policy | Top-level execution timeout. |
| `:compile_timeout` | sibling policy | Compile-phase bound. |
| `:max_program_bytes` | sibling policy | Source-size preflight limit. |
| `:max_heap` | sibling policy | Sandbox heap policy. |
| `:worker_max_heap` | sibling policy | Parallel worker heap policy. |
| `:max_parallel_workers` | sibling policy | Parallel worker global cap. |
| `:max_symbols` | sibling policy | Parser/analyzer resource policy. |
| `:pmap_timeout` | sibling policy | Parallel operation timeout. |
| `:pmap_max_concurrency` | sibling policy | Parallel scheduling policy. |
| `:max_print_length` | sibling rendering/policy | Print output cap. |
| `:max_tool_calls` | sibling policy (overloaded — see note below) | Lisp tool-call cap on the direct env-path only. |
| `:filter_context` | sibling policy | Host-side context projection optimization. |
| `:float_precision` | sibling rendering | Post-eval float rendering/normalization. |
| `:journal` | sibling instrumentation | Trace/journal side channel, not program input. |
| `:trace_context` | sibling instrumentation | Trace side channel. |
| `:link` | sibling policy | Sandbox process-linking policy. |
| `:caller` | sibling telemetry | Entry telemetry tag. |
| `:profile` | sibling telemetry | Entry telemetry tag. |
| `:isolation` | sibling policy | Future execution strategy selector. |

Upstream context-limit options are not Lisp options. They are consumed by
`PtcRunner.Upstream.Eval.with_run_context/3` (the full set is `@context_keys` in
eval.ex:13-19):

- `:max_tool_calls`
- `:max_catalog_ops`
- `:call_timeout_ms`
- `:max_response_bytes`
- `:max_catalog_result_bytes`

**`:max_tool_calls` is overloaded** and the two meanings must not be collapsed:

- On the **direct `Lisp.run` env-path** it is the Lisp sibling cap read by
  `run_params` (lisp.ex:394; fails `:tool_call_limit_exceeded`). It is excluded
  from `RunEnv.keys/0`, so it rides in `policy_opts`.
- On the **upstream path** `with_run_context/3` consumes it as the `RunContext`
  cap via `Keyword.take(opts, @context_keys)` (eval.ex:57 →
  `check_call_cap`, run_context.ex:39-53; fails `:cap_exhausted`) and `Keyword.drop`
  removes it before `Lisp.run` — so the Lisp sibling cap is unreachable there.

## Deferred: `PtcRunner.Lisp.RunEnv`

Do not implement this section in the closed-context-guard PR. Keep it as the
reviewed target shape for a future control-plane-driven `RunEnv` cutover.

V1 struct:

```elixir
defmodule PtcRunner.Lisp.RunEnv do
  @enforce_keys []
  defstruct context: %{},
            memory: %{},
            turn_history: [],
            prelude: nil,
            tools: %{},
            discovery_exec: nil,
            signature: nil,
            tool_cache: %{},
            strict_data: false,
            budget: nil,
            runtime: nil
end
```

`RunEnv.new/1` accepts only the V1 field keys above. Unknown keys raise
`ArgumentError`. It does not accept sibling policy/instrumentation options.

`RunEnv.to_flat_opts/1` or an internal equivalent should return the current
flat option shape expected by `PtcRunner.Lisp.run/2` internals:

```elixir
[
  context: env.context,
  memory: env.memory,
  turn_history: env.turn_history,
  prelude: env.prelude,
  tools: env.tools,
  discovery_exec: env.discovery_exec,
  signature: env.signature,
  tool_cache: env.tool_cache,
  strict_data: env.strict_data,
  budget: env.budget,
  runtime: env.runtime
]
```

`runtime` is a borrowed, read-only validation handle. `RunEnv` must not start,
stop, own, or mutate it. It is present so prelude `requires` validation keeps
working through upstream projections.

`RunEnv.keys/0 :: [atom()]` returns the 11 V1 field atoms (`:context`, `:memory`,
`:turn_history`, `:prelude`, `:tools`, `:discovery_exec`, `:signature`,
`:tool_cache`, `:strict_data`, `:budget`, `:runtime` — **including `:runtime`**).
Derive it once from the struct (e.g. `@keys Map.keys(%RunEnv{}) -- [:__struct__]`)
so the defstruct, `new/1` key validation, `to_flat_opts/1`, the forbidden-key list
in `Lisp.run/2`, and the `run_lisp_with_records/3` take/drop split all consume a
single source of truth and cannot drift.

## Deferred: `Lisp.run/2` `env:` API

Add support for:

```elixir
PtcRunner.Lisp.run(source, env: %PtcRunner.Lisp.RunEnv{}, timeout: 1_000)
```

Rules:

- Legacy flat options remain supported for 0.x.
- With `env:` present, flat eval-input keys are forbidden and raise
  `ArgumentError`: `:context`, `:memory`, `:turn_history`, `:prelude`,
  `:tools`, `:discovery_exec`, `:signature`, `:tool_cache`, `:strict_data`,
  `:budget`, `:runtime`.
- With `env:` present, sibling policy/instrumentation keys remain allowed:
  `:timeout`, `:compile_timeout`, `:max_program_bytes`, `:max_heap`,
  `:worker_max_heap`, `:max_parallel_workers`, `:max_symbols`,
  `:pmap_timeout`, `:pmap_max_concurrency`, `:max_print_length`,
  `:max_tool_calls`, `:filter_context`, `:float_precision`, `:journal`,
  `:trace_context`, `:link`, `:caller`, `:profile`, and future `:isolation`.
- With `env:` present, unknown top-level keys raise `ArgumentError`.
- On the legacy flat path, keep current unknown-key tolerance in the deferred
  `RunEnv` refactor. Global strict-key checking is separate hardening.
- `caller` and `profile` telemetry validation continue to run at entry.
  `signature_supplied?` MUST be derived from the **effective merged** signature
  *after* the env merge — on the env-path `:signature` lives in `env.signature`
  (a forbidden flat key), so computing it from raw `opts` (as today at lisp.ex:246)
  would emit `false` for every env-path run that sets a signature. The
  `:telemetry.span` around `do_run` (lisp.ex:256) is preserved unchanged.

Implementation shape (ordering is normative):

```elixir
def run(source, opts \\ []) do
  {env, opts} = normalize_env_opts!(opts)          # 1. pop/validate :env
  caller = validate_caller!(Keyword.get(opts, :caller, :in_process_v1))
  profile = validate_profile!(Keyword.get(opts, :profile))
  inner_opts =                                      # 2. merge env -> flat opts
    merge_env_for_internal_run(env, opts)
    |> Keyword.delete(:caller)
    |> Keyword.delete(:profile)
  signature_supplied? =                             # 3. compute AFTER merge
    not is_nil(Keyword.get(inner_opts, :signature))
  # 4. existing :telemetry.span([:ptc_runner, :lisp, :execute], ...) wrapping
  #    do_run(source, inner_opts), unchanged.
end
```

Helper contracts:

- `normalize_env_opts!/1` — no `:env` key ⇒ return `{nil, opts}` unchanged
  (legacy tolerance, including current unknown-key tolerance). `:env` present ⇒
  pop `:env`; require its value to be a `%PtcRunner.Lisp.RunEnv{}`; raise
  `ArgumentError` on `env: nil`, plain maps, duplicate `:env` keys, any of the 11
  forbidden eval-input keys, and any unknown top-level key; return
  `{env, sibling_opts}`.
- `merge_env_for_internal_run/2` — `(nil, opts)` returns `opts` verbatim (no
  default-`RunEnv` wrapping, no injected keys, so the legacy flat path is
  untouched). `(env, sibling_opts)` returns `to_flat_opts(env) ++ sibling_opts`;
  the two key-sets are disjoint by construction, so concat order is safe.

No public `isolation: :none` ships with the deferred `RunEnv` work. If
`:isolation` is accepted at all while wiring `env:`, only `:sandbox` is valid.

## Deferred: Upstream Projection

`PtcRunner.Upstream.Eval` remains the canonical upstream projection module.
Do not add `with_run_context/3` or `eval_options/1` to
`PtcRunner.Upstream.Runtime` in the deferred `RunEnv` work.

Current projection seam:

```elixir
PtcRunner.Upstream.Eval.with_run_context(runtime, context_opts, fn run_context ->
  env =
    run_context
    |> PtcRunner.Upstream.Eval.eval_options()
    |> Keyword.put(:runtime, runtime)
    |> Keyword.merge(context: ctx, memory: memory)
    |> PtcRunner.Lisp.RunEnv.new()

  PtcRunner.Lisp.run(source, env: env, timeout: timeout)
end)
```

`eval_options/1` must keep returning exactly:

```elixir
[tools: tools, discovery_exec: discovery_exec]
```

This is intentionally frozen so MCP handlers, REPL discovery, tests, and the
new `RunEnv` projection can share the same upstream closures.

Prelude-backed upstream runs must thread `runtime:` into `RunEnv`; otherwise
attach-time `requires` validation silently degrades to compile-only validation.

## Deferred: `run_lisp/3` Disposition

If `RunEnv` ships later, do not delete `PtcRunner.Upstream.Eval.run_lisp/3` in
that refactor. It has live production callers:

| Caller | Target |
| --- | --- |
| `lib/ptc_runner/session.ex` | Keep call unchanged; implementation becomes thin projection convenience. |
| `lib/mix/tasks/ptc.repl.ex` | Keep call unchanged; implementation becomes thin projection convenience. |

`run_lisp_with_records/3` has no production callers, but many tests depend on
it. Keep it `@doc false` and implement it through the same projection path.

`run_subagent/3` stays. It has a live MCP caller and correctly owns one
`RunContext` spanning the whole multi-turn mission.

Implementation target:

```elixir
def run_lisp_with_records(runtime, program, opts \\ []) do
  context_opts = Keyword.take(opts, @context_keys)
  lisp_opts = Keyword.drop(opts, @context_keys)

  with_run_context(runtime, context_opts, fn context ->
    env =
      lisp_opts
      |> Keyword.take(RunEnv.keys())
      |> Keyword.merge(eval_options(context))
      |> Keyword.put(:runtime, runtime)
      |> RunEnv.new()

    policy_opts = Keyword.drop(lisp_opts, RunEnv.keys())
    PtcRunner.Lisp.run(program, Keyword.put(policy_opts, :env, env))
  end)
end
```

`Keyword.merge(eval_options(context))` is ordered **after**
`Keyword.take(RunEnv.keys())` deliberately: the upstream `:tools`/`:discovery_exec`
closures override any caller-supplied values, and the `"call"` closure stays
reserved and non-displaceable by caller tools (mirrors eval.ex:66-68 and the
`run_subagent/3` bridge-owned rule). Do not reorder this merge.

`Keyword.put(:runtime, runtime)` is also deliberate, not `put_new`: the upstream
path must validate prelude `requires` against the same runtime that owns the
borrowed `tools`/`discovery_exec` closures. A caller-supplied `runtime:` option
must not make prelude validation observe a different upstream surface than
execution dispatches through.

`policy_opts` MUST preserve today's flat-path unknown-key tolerance rather than
inheriting the strict env-path raise. `PtcRunner.Session` forwards arbitrary user
`run_opts` (session.ex:66,82,144-145), so routing them through the strict `env:`
path unchanged would make a Session carrying any key outside
`RunEnv.keys ∪ sibling-allow-list ∪ @context_keys` start raising on the upstream
path while the in-process path stays tolerant. Before attaching `env:`, narrow
`policy_opts` with `Keyword.take(policy_opts, <sibling allow-list ∪ [:caller, :profile]>)`
so unrecognized keys are dropped (as today), not raised.

## Deferred: Migration Table

| Surface | Current shape | Migration |
| --- | --- | --- |
| Direct `PtcRunner.Lisp.run/2` tests and callers | Flat opts | Stay flat for 0.x; add new `env:` tests. |
| `PtcRunner.Session` upstream path | `UpstreamEval.run_lisp/3` | Keep caller; update helper implementation. |
| `mix ptc.repl` upstream eval path | `UpstreamEval.run_lisp/3` | Keep caller; update helper implementation. |
| `mix ptc.repl` discovery helpers | `with_run_context/3` + `eval_options/1` | Stay as-is. |
| MCP tools/session handlers | Manual `run_context` + `eval_options/1` | Stay as-is; must keep manual drain timing. |
| `Upstream.Eval.run_lisp_with_records/3` tests | Thin helper | Keep helper, route through `RunEnv`. |
| `Upstream.Eval.run_subagent/3` | One context across mission | Stay as-is for lifecycle; optionally build per-turn `RunEnv` later. |
| `SubAgent.Loop.LispOpts.build/4` | Shared flat Lisp opts for loop transports | Migrate as one unit if SubAgent turns move to `env:`. |
| Other SubAgent builders (`runner.ex`, `compiler.ex`, `tool_normalizer.ex`) | Independent flat opts | Audit together before any SubAgent `env:` migration to avoid reintroducing route divergence. |
| `mcp_server` snapshot eval (`PtcRunnerMcp.Sessions.run_snapshot` → `Session.lisp_opts/3`, sessions.ex:296 / session.ex:779) | Independent flat opts builder | Stay as-is; out-of-scope-but-verify-still-compiling (the closed-context guard protects this path regardless, since it lives in the CallTool/Discovery closures). |

## Delivered: Borrowed Closure Lifetime (shipped)

The closed-context borrowed-closure lifetime guard described in this plan has
SHIPPED — see `lib/ptc_runner/upstream/{run_context,call_tool,discovery,eval}.ex`
and its tests. Borrowed upstream closures (`tools:` / `discovery_exec:`) that
start after the `RunContext` close boundary now fail closed: closed tool calls
return `Result.error(:run_context_closed, "run_context_closed")`, closed
discovery returns `{:world_fault, :run_context_closed}`, and
`:run_context_closed` is part of `PtcRunner.Upstream.Result.reason/0`. The
remainder of this doc is the deferred `RunEnv` design.

## Isolation

This slice keeps the existing sandbox behavior. `isolation: :none` is deferred.

If an `:isolation` option is added while wiring `env:`, only `:sandbox` is
accepted in 0.x. `:none` would need a separate spec because it changes top-level
timeout, crash isolation, and heap behavior.

## Testability Invariants

The runtime cleanup must not make ordinary tests heavier. These remain
first-class:

- inline `llm:` callbacks for SubAgent tests;
- inline `tools:` maps;
- plain `context:` maps;
- no API keys, app config, or OTP runtime for direct Lisp/SubAgent unit tests.

Runnable doctest shape:

```elixir
iex> mock_llm = fn _request ->
...>   {:ok, "(->> (tool/get-orders) (filter #(> % data/threshold)) (reduce +))"}
...> end
iex> {:ok, step} = PtcRunner.SubAgent.run(
...>   "Total value of orders over ${{threshold}}",
...>   tools: %{"get-orders" => fn _ -> [1500.0, 950.0, 50.0] end},
...>   context: %{threshold: 100},
...>   llm: mock_llm,
...>   max_turns: 1
...> )
iex> step.return
2450.0
```

The closed-context guard's acceptance tests have shipped alongside the guard
(see `lib/ptc_runner/upstream/{run_context,call_tool,discovery,eval}.ex` tests).

Deferred acceptance tests if/when `RunEnv` ships:

- `RunEnv.new/1` accepts valid eval-input keys and raises on unknown keys.
- `Lisp.run(source, env: env)` produces the same result as the equivalent flat
  opts for a plain tool/context/memory case.
- `Lisp.run(source, env: nil)`, `env: %{}`, and duplicate `env:` keys raise
  `ArgumentError` before evaluation.
- `Lisp.run(source, env: env, context: %{})` raises because `context:` is a
  duplicate eval-input channel.
- `Lisp.run(source, env: env, foobar: 1)` raises `ArgumentError` (unknown
  top-level key on the env-path).
- Policy siblings such as `timeout:` and `max_heap:` are accepted with `env:`.
- **env↔flat parity** across every program-affecting channel — assert
  `step.return`/`step.status` (NOT the whole `Step`, which carries
  non-deterministic `usage.duration_ms`/timestamps) for `strict_data`
  (missing-key → error vs `nil`), `turn_history` (`*1`), `signature` (validated
  vs rejected), `prelude` exports, plus `tool`/`context`/`memory`.
- **Default-drift guard:** each of the 11 `%RunEnv{}` field defaults equals its
  `run_params`/`do_run` default (lisp.ex:366-399 — all 11 match today).
- **Telemetry:** `Lisp.run(src, env: %RunEnv{signature: sig})` emits
  `signature_supplied?: true` on `:start` and `:stop`; `false` when
  `env.signature` is `nil`.
- Upstream `run_lisp/3` still validates prelude `requires` through `runtime:`.
- Upstream `run_lisp_with_records/3` ignores caller-supplied `runtime:` for
  projection; prelude `requires` validation uses the bridge runtime that owns the
  borrowed upstream closures.
- **Reserved `"call"` precedence:** `run_lisp_with_records(runtime, prog, tools:
  %{"call" => fake})` still dispatches through the upstream `"call"` closure (the
  caller tool does not displace it).
- **Session tolerance preserved:** `PtcRunner.Session.new(foo: 1)` evaluates on
  the upstream path without `ArgumentError`, matching the in-process path.

Do **not** add an `isolation: :none`-rejection test in the closed-context guard
PR. Isolation remains deferred with the `RunEnv` API work (see Non-goals and
§Isolation).

## Appendix: Future Runtime Direction

Do not implement this appendix in the closed-context guard PR or the deferred
`RunEnv` refactor.

A future neutral host integration layer may be useful after another
lifecycle-bearing provider exists. Prefer a non-conflicting name such as
`PtcRunner.Host` unless the existing `PtcRunner.Lisp.Runtime`,
`PtcRunner.Upstream.Runtime`, and `:runtime` option collisions are resolved.

Possible future vocabulary:

- **Host/Runtime** — long-lived host integration state and provider lifecycle.
- **Provider** — a capability family such as upstream tools, LLM callbacks,
  SubAgents, sessions, trace history, filesystem access, or native tools.
- **Descriptor** — trace-safe discovery and validation data.
- **RunScope** — one bounded host operation with grants, budgets, deadlines,
  collectors, trace scope, events, and close hooks.
- **Projection** — a consumer-specific view such as a Lisp `RunEnv`, SubAgent
  tool map, MCP tool description, REPL command surface, or trace/debug record.

The future shape should keep execution explicit:

```elixir
PtcRunner.Host.with_run(host, opts, fn scope ->
  env = PtcRunner.Lisp.RunEnv.from_scope(scope, context: ctx)
  PtcRunner.Lisp.run(source, env: env)
end)
```

The constructor name above (`from_scope/2`) is a non-binding placeholder; it,
`from_run/2`, and `from_capabilities/2` are all deferred (see Non-goals) and only
one would ever ship. `PtcRunner.Lisp` remains the owner of Lisp evaluation.
Providers contribute capabilities; they do not own evaluation.

## Appendix: LLM Callback Primitive

The existing LLM callback API remains the smallest LLM capability primitive:

```elixir
llm = fn request ->
  {:ok, "(return {:answer 42})"}
end
```

That shape is intentionally valuable:

- tests can pass inline callbacks without global configuration;
- users can wrap any provider or framework;
- no runtime process is required for stateless model calls;
- `PtcRunner.LLM.callback/2` remains the adapter-to-function constructor;
- the `PtcRunner.LLM` behaviour remains the reusable adapter boundary.

Any future LLM provider should compose aliases, grants, budgets, tracing,
fallbacks, and descriptors around callbacks. It should not replace them.

Do not make Lisp-side LLM calls part of the default user-space surface. If
`(llm/call ...)` is added, it must be an explicitly granted capability with
token budgets, recursion/turn controls, tracing, and model alias restrictions.
