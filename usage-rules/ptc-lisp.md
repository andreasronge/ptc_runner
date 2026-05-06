# PTC-Lisp Usage Rules

PTC-Lisp is a deterministic Clojure subset executed in a sandboxed BEAM
process. It's the language the LLM emits inside `SubAgent.run/2`, but you can
also run programs directly when you don't need an LLM.

## When to use `PtcRunner.Lisp.run/2` directly

Use it when **you** already have the program string (or generate it from your
own template) and want sandboxed execution with tool access. Common cases:

- Replaying / re-running an LLM-generated program from a trace.
- Running a fixed data pipeline you wrote yourself.
- Testing tool wiring without paying for an LLM call.

For everything else, use `PtcRunner.SubAgent.run/2` instead.

## Basic shape

```elixir
{:ok, step} = PtcRunner.Lisp.run(
  ~S|(->> data/items (filter :active) (count))|,
  context: %{items: items}
)

step.return  #=> 3
```

With tools (note kebab-case in the Lisp call, string key in the map, arity-1 fn):

```elixir
{:ok, step} = PtcRunner.Lisp.run(
  ~S|(tool/get-user {:id 123})|,
  tools: %{"get-user" => fn %{"id" => id} -> MyApp.Users.get(id) end}
)
```

`Lisp.run/2` returns `{:ok, %Step{}}` / `{:error, %Step{}}`. Same shape as
`SubAgent.run/2`'s step.

## Resource limits (default-on)

Every program runs in an isolated process with hard caps:

- `:timeout` — total wall-clock time, default **1000 ms**.
- `:max_heap` — max heap in words, default **1_250_000** (~10 MB).
- `:pmap_timeout` — per-task timeout in `pmap`/`pcalls`, default 5000 ms.
- `:max_symbols` — symbol/keyword table cap (10_000), guards against atom-exhaustion.

Bump `timeout` and `max_heap` for large data analyses. Bump `pmap_timeout`
when tools are LLM-backed.

## Calling tools from PTC-Lisp

Tool names: kebab-case. Three invocation forms:

```clojure
(tool/get-config)                              ; no args  → %{}
(tool/get-user {:id 123})                      ; map arg
(tool/search :query "elixir" :limit 10)        ; keyword-style → %{"query"=>"elixir","limit"=>10}
```

All three reach your Elixir tool function as a **string-keyed map** (or `%{}`).
The Elixir-side `tools:` map key uses a **string**: `"get-user"`.

Tool contract (always):

- Function is **arity-1** taking a string-keyed map.
- Returns any Elixir term.
- Should **not** raise — return `{:error, reason}` for failures.

Functions of other arities passed through `tools:` will crash at invocation
time. Wrap zero-arity / multi-arity functions: `fn _args -> Mod.fun() end` /
`fn %{"a" => a, "b" => b} -> Mod.fun(a, b) end`.

## What's available in the language

PTC-Lisp covers ~40% of `clojure.core` (211 of 534 vars), plus `clojure.string`,
`clojure.set`, and `java.lang.Math`. Highlights:

- Threading: `->`, `->>`
- Sequence: `map`, `filter`, `reduce`, `take`, `drop`, `partition`, `group-by`
- Collection aggregators (PTC extensions): `sum`, `avg`, `sum-by`, `avg-by`, `min-by`, `max-by`, `pluck`
- Predicates: `where`, `all-of`, `any-of`, `none-of`
- Parallel: `pmap`, `pcalls` (BEAM-native, runs concurrently)
- Control flow: `if`, `cond`, `when`, `let`, `loop`/`recur`
- Multi-turn loop control: `(return v)`, `(fail reason)`
- Definitions: `def` (variable, persists in memory), `defn` (function)

The full list lives in `docs/function-reference.md`. Use `mix
usage_rules.search_docs <name> -p ptc_runner` to look one up.

**Not available** (deliberate omissions): I/O, file system, HTTP, atoms (Clojure
atoms), refs, agents, lazy seqs (everything is eager), macros, namespaces.

## Namespace forms

| Form | Meaning |
|------|---------|
| `data/key` | Reads `context[:key]` (or `context["key"]`). |
| `tool/name` | Calls a registered tool. |
| `*1`, `*2`, `*3` | Last 1/2/3 turn results (multi-turn agents only). |

## Temporal values

Pass Elixir temporal structs (`DateTime`, `NaiveDateTime`, `Date`, `Time`)
directly in `context:` and tool results. PtcRunner normalizes them to ISO 8601
strings at LLM-facing boundaries (templates, data inventory, tool result
encoding, `:string` coercion, and PTC-Lisp `(str ...)`). Do not pre-render
Elixir sigils like `"~U[2026-05-03 09:14:00Z]"` for the LLM.

```elixir
{:ok, step} =
  PtcRunner.SubAgent.run(
    "How old is this event in hours?",
    context: %{opened_at: ~U[2026-05-03 09:14:00Z]},
    tools: %{"now" => fn _args -> ~U[2026-05-05 10:00:00Z] end},
    llm: llm
  )
```

In PTC-Lisp, use the Java-shaped interop functions the model is likely to know:

```clojure
(def opened-ms (.getTime (java.util.Date. data/opened_at)))
(def now-ms (.getTime (java.util.Date. (tool/now))))
(return {:age_hours (int (/ (- now-ms opened-ms) 3600000))})
```

Supported date/time interop includes:

- `(java.util.Date.)` for current UTC time.
- `(java.util.Date. value)` for ISO 8601 strings, RFC 2822 strings, Unix
  seconds/milliseconds, and Elixir `DateTime` / `NaiveDateTime` / `Date` values.
- `(.getTime date)` for Unix milliseconds.
- `(java.time.LocalDate/parse "2026-05-03")` for ISO dates.
- `(.isBefore a b)` / `(.isAfter a b)` for same-type date comparisons.

Mixed `Date` vs `DateTime` comparisons raise; convert both sides to the same
shape first.

## Memory contract

The top-level program's value passes through to `step.return` **unchanged** —
no implicit map merge, no `:return` key handling. Persistence is **explicit**:
use `(def x v)` to store a value (it becomes `memory[:x]` and survives across
turns within one `SubAgent.run/2`). `(defn name [...] ...)` does the same for
functions.

## Common pitfalls

- **Using underscores in tool names inside lisp.** `(tool/get_user ...)` works,
  but `(tool/get-user ...)` is the convention and the LLM will prefer it.
- **Index access into lists.** `(list 1 2 3)[0]` is invalid. Use `(nth xs 0)`
  or `(first xs)`.
- **Arithmetic / comparison on `nil`.** `nil` is falsy in `if`/`when`/`and`/`or`,
  but `(+ nil 1)`, `(< nil 5)`, etc. raise type errors. Guard with
  `(or x default)` or `(if x ... )` before doing math on possibly-nil values.
- **Side effects.** PTC-Lisp is functional. There is no `def!` / mutable
  reference. `def` *adds* a binding to memory; it does not mutate in place.
- **Trying to recurse forever.** `recur` is required for tail-call recursion.
  Plain function self-calls will hit the heap cap fast.

## Validating without running

```elixir
case PtcRunner.Lisp.validate(source) do
  :ok                -> # valid PTC-Lisp
  {:error, messages} -> # list of String.t() describing parse / analysis errors
end
```

Catches parse and analysis errors (unknown forms, bad arity) without
executing. Use in development to lint LLM-generated programs before
sending them to the sandbox.
