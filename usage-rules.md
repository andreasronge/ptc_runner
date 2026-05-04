# PtcRunner Usage Rules

PtcRunner is a BEAM-native library for **Programmatic Tool Calling (PTC)**: the LLM
writes a small program (in PTC-Lisp, a Clojure subset) and PtcRunner executes it
in a sandboxed BEAM process. The LLM is the programmer, not the runtime.

This file covers the consumer-facing API. Sub-rules cover specific topics:

- [`usage-rules/subagent.md`](usage-rules/subagent.md) — the agentic loop API (most common entry point)
- [`usage-rules/ptc-lisp.md`](usage-rules/ptc-lisp.md) — running PTC-Lisp directly without an LLM
- [`usage-rules/llm-setup.md`](usage-rules/llm-setup.md) — providers, callbacks, model aliases
- [`usage-rules/testing.md`](usage-rules/testing.md) — mocking the LLM in ExUnit

## Mental model

- `SubAgent.run/2` is the **primary** API. It runs a loop: prompt → LLM → PTC-Lisp
  program → sandboxed execution → repeat until `(return ...)` or `(fail ...)`.
- The LLM never returns the *answer* directly. It returns a *program* whose
  evaluation is the answer. Don't try to make the LLM "just answer" in PTC-Lisp
  mode — set `output: :text` instead.
- Programs run inside isolated BEAM processes with timeouts and a heap cap.
  Tools are pure-ish callbacks the program may invoke.
- A single `SubAgent.run/2` call returns `{:ok, %Step{}}` / `{:error, %Step{}}`
  for normal LLM/program failures — it does **not** raise. `SubAgent.new/1`
  *does* raise `ArgumentError` on bad option types, and `SubAgent.run!/2`
  raises on `{:error, _}`.

## Installation

```elixir
def deps do
  [
    {:ptc_runner, "~> 0.10"},
    {:req_llm, "~> 1.8"}  # optional but recommended — built-in LLM adapter
  ]
end
```

`req_llm` is **optional**. Without it, `PtcRunner.LLM.callback/2` will not work
and you must pass an LLM callback function explicitly. `req`, `kino`, and
`req_llm` are all optional deps. Don't assume their modules are loaded.

## Golden path

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "How many r's are in raspberry?",
  llm: "haiku"   # any model alias from PtcRunner.LLM.callback/2
)

step.return  #=> 3
```

With tools and a typed return value:

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Find the most expensive product",
  signature: "{name :string, price :float}",
  tools:     %{"list_products" => fn _args -> MyApp.Products.list() end},
  llm:       "haiku"
)

step.return["name"]   #=> "Widget Pro"
step.return["price"]  #=> 299.99
```

## Core API surface

For most consumers these entry points are all you need:

| Function | Use when |
|----------|----------|
| `PtcRunner.SubAgent.run/2` | Single execution of an agentic loop |
| `PtcRunner.SubAgent.new/1` | Build a reusable agent struct (separates definition from runtime) |
| `PtcRunner.SubAgent.compile/2` | Bake the LLM-generated program into a deterministic Elixir function (max_turns: 1, ptc_lisp only) |
| `PtcRunner.SubAgent.as_tool/2` | Wrap an agent so a parent agent can call it as a tool |
| `PtcRunner.SubAgent.chat/3` | Multi-turn chat that threads `messages` (and `memory` in PTC-Lisp mode) |
| `PtcRunner.Lisp.run/2` | Execute a PTC-Lisp program **without** an LLM (data pipelines) |

Don't reach into `PtcRunner.SubAgent.Loop.*`, `PtcRunner.Lisp.Eval.*`, or other
internal namespaces — they will change without notice (this is a 0.x library).

## Common mistakes

- **Tool function arity.** Tools must be **arity-1** functions taking a
  string-keyed argument map: `fn %{"id" => id} -> ... end`. Bare references
  like `&MyApp.list/0` or `&MyApp.search/2` will crash at runtime — they are
  silently passed through normalization but called with one map arg. Wrap as
  `fn _args -> MyApp.list() end` or `fn %{"q" => q, "n" => n} -> MyApp.search(q, n) end`.
- **Passing a string when you wanted a struct.** `SubAgent.run("...", opts)` is
  fine for one-offs but uses defaults for everything else. Use
  `SubAgent.new(opts)` + `SubAgent.run(agent, runtime_opts)` for reusable agents.
- **Forgetting `(return ...)` in multi-turn mode.** If the agent has tools or
  `max_turns > 1`, the LLM **must** call `(return value)` to finish. Otherwise
  it loops until `max_turns_exceeded`. For one-shot reasoning, set `max_turns: 1`.
- **Mistaking the LLM output for Elixir.** The LLM produces PTC-Lisp (a Clojure
  subset), not Elixir. Don't `Code.eval_string` it.
- **Assuming `req_llm` is required for any LLM access.** It isn't.
  `PtcRunner.LLM.callback("haiku")` only works when `req_llm` is in deps **or**
  you've configured a custom adapter via `config :ptc_runner, :llm_adapter, MyAdapter`.
  Function LLMs (anonymous `fn`) work without either. Atom LLMs (`:haiku`)
  require an `llm_registry`.
- **Tool key naming.** In `tools:` maps, **string keys** are required. Inside
  PTC-Lisp, tools are referenced kebab-case: `"get-user"` is invoked as
  `(tool/get-user {:id 1})`. Underscores work too but kebab-case is the
  Clojure convention the LLM expects.
- **Calling tools "as the LLM".** The LLM doesn't call your tools — the
  PTC-Lisp interpreter does, when the LLM-generated program reaches a
  `(tool/...)` form. Tools must therefore be safe to invoke at any time.
- **Treating `step.return` as raw text.** With a signature, `step.return` is
  a map keyed by **strings**, not atoms (`step.return["name"]`, not `step.return.name`).

## When to use which mode

| Mode | Set | Good for |
|------|-----|----------|
| PTC-Lisp loop *(default)* | `output: :ptc_lisp` (default) with tools | Agentic data analysis, RAG, multi-source joins |
| Single-shot PTC-Lisp | `max_turns: 1`, no tools | Cheap reasoning where you trust the model |
| Text mode (raw) | `output: :text`, no signature | Plain text answers, summarisation |
| Text mode (JSON) | `output: :text` with signature | Classification, extraction, structured output |
| Text mode + tools | `output: :text` with `tools` | Smaller LLMs that can do native tool calling but not write PTC-Lisp |

Don't enable `output: :ptc_lisp` (the default) for tasks that don't need
program-level orchestration — text mode is faster and cheaper.

## Required vs optional `run/2` options

An LLM is required for execution. Provide it either on the agent struct
(`SubAgent.new(llm: ...)`) **or** at runtime (`SubAgent.run(agent, llm: ...)`)
— not necessarily both. The runtime opt overrides the struct.

Most-used runtime options: `tools:`, `signature:`, `context:`, `max_turns:`,
`output:`, `retry_turns:`, `llm_query:`, `builtin_tools:`, `llm_registry:`,
`llm_retry:`, `on_chunk:`, `collect_messages:`. See `SubAgent.new/1` for the
full set including struct-only fields.

## Looking things up

- Public API surface: see `PtcRunner.SubAgent` and `PtcRunner.Lisp` moduledocs.
- All built-in PTC-Lisp functions: `mix usage_rules.docs PtcRunner.Lisp` or the
  generated `docs/function-reference.md` in HexDocs.
- Anything *the LLM* needs to know goes into the system prompt that ptc_runner
  builds — you don't write that yourself. Don't duplicate language-spec
  guidance into your application prompt.
