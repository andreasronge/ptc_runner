# Capability Preludes — Authoring & Deploying Guide

A **capability prelude** lets a deployment expose curated, Lisp-facing APIs to
agents without hard-coding each one into the library or stuffing full source
into the prompt. You write a small PTC-Lisp file that declares protected
namespaces (e.g. `crm`) with public exports; agents call and discover those
exports like any built-in, while private helpers stay hidden.

This guide is the practical how-to: building a prelude, wiring it into a run,
and the decisions you make along the way. For the language-level rules see
[§9.9 Capability Prelude](../ptc-lisp-specification.md#99-capability-prelude) in
the specification; for the discovery forms see
[function-reference.md](../function-reference.md).

> **V1 scope.** A prelude is **stateless**: it defines namespaces, constants,
> functions, docstrings, and metadata, but holds no hidden mutable state. There
> is no authoring DSL, no LLM-authored preludes, and no generic capability
> catalog yet — see `docs/plans/capability-prelude-discovery.md` for the
> deferred work.

---

## 1. Quick start (60 seconds)

Compile a prelude source string into an artifact, then attach it to a SubAgent:

```elixir
prelude_source = """
(ns crm
  "CRM helpers."
  {:visibility :prompt})

(defn get-user
  "Return a CRM user by id."
  [id]
  (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
"""

{:ok, prelude} = PtcRunner.Lisp.Prelude.Compiler.compile(prelude_source)

agent =
  PtcRunner.SubAgent.new(
    prompt: "Look up the requested user",
    runtime_prelude: prelude,
    llm: llm
  )
```

The agent's program can now call `(crm/get-user data/user-id)`, branch on the
result, and discover the export with `(ns-publics 'crm)` / `(doc 'crm/get-user)`.

Compile once, attach anywhere — the **same artifact** works across direct
execution, SubAgent execution, and the REPL (§7).

---

## 2. Anatomy of a prelude file

```clojure
(ns crm
  "CRM helpers."              ; optional namespace docstring
  {:visibility :prompt})      ; optional namespace metadata (defaults below)

(def page-size 50)            ; a constant export

(defn- normalize-id           ; PRIVATE helper (defn-): not user-visible
  "Trim and tag a raw id."
  [raw]
  (str "norm:" raw))

(defn get-user                ; PUBLIC export (defn)
  "Return a CRM user by id."
  [id]
  (tool/call {:server "crm" :tool "get_user" :args {:id (normalize-id id)}}))
```

- **`(ns name "doc" {meta})`** is a *compiler directive* — it declares a
  protected namespace. Declare each namespace **exactly once** per file;
  reopening it is rejected.
- **`(defn name "doc" [args] body)`** defines a public export.
- **`(defn- ...)`** defines a private helper. Public exports may call it; user
  code can never resolve or discover it by qualified symbol.
- **`(def name value)`** defines a constant export. Reference it as a value
  (`crm/page-size`); a zero-arg call `(crm/page-size)` also yields the value.
- You may declare several namespaces in one file.

### Reserved namespaces

A prelude **cannot** declare the host-reserved namespaces `tool`, `data`,
`budget`, or `ptc.core` — compilation fails. These stay under host control.

---

## 3. Calling exports from agent code

Prelude exports wrap the existing tool surfaces unchanged, so they are
**recoverable-by-default**. A wrapper around `(tool/call ...)` returns the same
result map a direct call returns, and the agent branches on it:

```clojure
(def res (crm/get-user "u_123"))
(if (res :ok)
  (return {:user (res :value)})
  (return {:error (res :reason)}))
```

| Key       | Meaning                                  |
|-----------|------------------------------------------|
| `:ok`     | `true` on success, `false` on a recoverable failure |
| `:value`  | the result payload when `:ok`            |
| `:reason` | the failure reason when not `:ok`        |

### Abort-on-error helpers

If you want a helper that aborts the whole program on failure (rather than
returning a recoverable map), call `fail` yourself and **name it with a `!`
suffix** so the behavior is visible at the call site:

```clojure
(defn get-user!
  "Return a CRM user, or abort the program."
  [id]
  (let [res (get-user id)]      ; call the sibling by its BARE name
    (if (res :ok) (res :value) (fail {:reason (res :reason)}))))
```

Keep `fail` for intentional aborts; do **not** make every wrapper abort by
default.

> **Calling siblings.** Within a prelude namespace, call other exports/helpers
> by their **bare** name (`get-user`), not qualified (`crm/get-user`). Qualified
> self-references are rejected at compile time — qualified refs are for *user*
> code calling the prelude, not for the prelude calling itself.

---

## 4. Public, private, and prompt visibility

Every public export has a **visibility**, set on the export (or defaulted from
the namespace, then the global default `:prompt`):

| Visibility       | In the prompt inventory? | Discoverable? |
|------------------|--------------------------|---------------|
| `:prompt`        | yes (compact entry)      | yes           |
| `:discoverable`  | no                       | yes           |

```clojure
(ns crm "CRM." {:visibility :prompt})   ; namespace default

(defn get-user "..." [id] ...)          ; inherits :prompt

(defn list-users
  "List CRM users."
  {:visibility :discoverable}           ; per-export override
  []
  (tool/call {:server "crm" :tool "list_users" :args {}}))
```

Prompt-visible exports are summarized in a compact, **deployment-defined**
prompt inventory assembled dynamically — the core prompt templates stay
domain-blind (they never mention `crm`). `:discoverable` exports are omitted
from the inventory but still reachable via the discovery forms (§6).

> Visibility can only be **narrowed** by host policy. Prelude metadata is
> advisory and can never broaden what is exposed.

---

## 5. Backing tools and upstream `requires`

When an export wraps a **literal** upstream call, the compiler infers its
backing operation id and records it under `requires`:

```clojure
(defn get-user [id]
  (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
;; => provider_ref "upstream:crm/get_user", requires ["upstream:crm/get_user"]
```

Two backing id shapes are inferred and validated:

- `"upstream:<server>/<tool>"` — a **literal** `(tool/call {:server "x" :tool
  "y" ...})`. Validated against the selected upstream runtime.
- `"tool:<name>"` — a **typed tool** call `(tool/<name> ...)` (a host-bound
  capability). Validated against the run's granted `tools:` map. The synthetic
  `"call"` of `(tool/call ...)` is **not** promoted to `tool:call` — literal
  upstream calls are already covered precisely by their `upstream:` id.
- An export that reaches a backing **through a private helper** inherits the
  requirement transitively (it still fails closed at attach time).
- A **dynamic** `(tool/call {:server server :tool tool ...})` whose server/tool
  are runtime values cannot be inferred — it carries no `requires` and must be
  declared explicitly if you want a fail-closed guarantee.

You can also declare backing metadata explicitly. `requires` is the **union** of
inferred and explicit ids — explicit can **add** requirements but never drop an
inferred (fail-closed) one. `provider-ref` and `effect` keep explicit-override
semantics:

```clojure
(defn search
  "Search users."
  {:provider-ref "upstream:crm/search" :effect :read
   :requires ["upstream:crm/search"]}
  [query]
  (tool/call {:server "crm" :tool "search" :args {:q query}}))
```

Metadata uses kebab-case keywords (`:provider-ref`); they are normalized at the
host boundary. Malformed `:requires` (non-string entries) **fails compilation**
rather than being silently dropped; an unrecognized id *shape* (neither
`upstream:` nor `tool:`) fails closed at **attach** time.

### Attach-time validation

When you attach a prelude *with a selected upstream runtime* (§7), each public
export's `requires` is checked against that runtime **before any user code
runs**. If a required upstream operation is not configured/granted, attachment
fails fast with `:prelude_attach_failed` — so a backing that is missing *at
attach time* can never cause a partial run with side effects.

This holds at the **initial** attach across every execution surface: direct
`Lisp.run`, the multi-turn SubAgent loop's first turn, and the single-shot fast
path. On the multi-turn path each turn re-validates, and a mid-run
`:prelude_attach_failed` is a **hard stop**, never a recoverable retry turn — but
note the scope: under the default `:live` catalog a backing can disappear *after*
an earlier turn has already executed a side effect, so the hard stop then
guarantees only that **no further turn runs**, not that the whole run was
side-effect-free. An unconditional cross-turn guarantee requires a
frozen-for-the-run catalog snapshot (a planned optimization); until then the
honest scope is **fail-closed before any side-effecting turn**. The validation
covers **the agent given the runtime**: a child SubAgent invoked via `as_tool` is
**upstream-blind** — it does not inherit the parent's runtime, so its own
`requires`-backed prelude is only validated if that child is itself run through
its own upstream bridge/runtime.

> **Default side-effect guard.** Fail-closed `requires` validation bounds
> *which* operations a prelude may reach. `PtcRunner.Upstream.Eval.run_subagent/3`
> also installs a default continuation guard: after an observed upstream
> `tool/call`, read-classified calls may continue, while write-classified or
> unknown-effect calls stop before the next LLM turn with
> `:partial_side_effects`. The failure details contain sanitized
> `%{matched_calls: [%{server, tool, effect}, ...]}` entries only — never
> upstream args or results. A host-supplied `continuation_guard` overrides this
> default completely.

> The prelude does **not** define upstream endpoints or credentials. It only
> *wraps* operations the host has already configured. Credentials live in
> host/deployment config and never appear in the artifact, prompts, or traces.

---

## 6. Discovering exports from agent code

Agents discover prelude exports with the same forms used for built-ins and MCP
tools. Namespace refs accept a quoted symbol (`'crm`) or a string (`"crm"`):

```clojure
(all-ns)                 ; sorted namespace names, incl. attached prelude ns
(ns-name 'crm)           ; => "crm"
(ns-publics 'crm)        ; map of public symbol => compact metadata
(dir 'crm)               ; member lines (honors {:limit :offset})
(doc 'crm/get-user)      ; docstring
(meta 'crm/get-user)     ; structured metadata (arity, effect, provider, ...)
(apropos "user")         ; fuzzy search across prelude + local + MCP
```

Exact prelude-export refs resolve through the prelude first; private helpers
have no export record and never appear.

---

## 7. Attaching a prelude to a run

The same compiled artifact attaches through four seams.

**Direct execution** (`PtcRunner.Lisp.run/2`) — pass a compiled artifact *or*
source (compiled before user-code analysis):

```elixir
PtcRunner.Lisp.run(program, prelude: prelude)
# or, to validate `requires` against a selected upstream runtime:
PtcRunner.Lisp.run(program, prelude: prelude, runtime: upstream_runtime)
```

**SubAgent** — the `runtime_prelude:` field on `%PtcRunner.SubAgent.Definition{}`
(via `SubAgent.new/1`). This works across every SubAgent execution path
(multi-turn loop, single-shot, and compiled agents):

```elixir
%PtcRunner.SubAgent.Definition{runtime_prelude: prelude}
```

**Upstream-backed single program** — `PtcRunner.Upstream.Eval.run_lisp/3` runs
**one** Lisp program against a selected upstream runtime and forwards that
runtime into the attach path automatically, so `requires` are validated:

```elixir
PtcRunner.Upstream.Eval.run_lisp(runtime, program, prelude: prelude)
```

**Upstream-backed multi-turn SubAgent** — `PtcRunner.Upstream.Eval.run_subagent/3`
is the analogue of `run_lisp/3` for a **multi-turn** agent. It owns a single
`RunContext` for the whole run, enriches the agent with the upstream-call tool
**before** prompt generation, and threads the runtime into **every** turn so the
prelude `requires` validate fail-closed per turn:

```elixir
PtcRunner.Upstream.Eval.run_subagent(runtime, agent, llm: llm, context: ctx)
```

The distinction: `run_lisp/3` runs a **single program**; `run_subagent/3` runs a
**multi-turn agent**. Both forward the same `runtime` into the attach path, so in
either case `requires` are validated against the selected upstream.

> **Default side-effect guard.** `run_subagent/3` validates a prelude's
> `requires` fail-closed per turn and installs a default side-effect continuation
> guard. Read-classified upstream calls may continue; write or unknown calls stop
> before the next turn with `:partial_side_effects` and sanitized
> `%{matched_calls: [...]}` details. Pass `continuation_guard:` to replace this
> default with host-owned policy. (See §5.)

If no upstream runtime is selected (e.g. a direct `Lisp.run` with a stub
`tools:` map), **`upstream:` requirements are skipped** (there is no runtime to
check; the granted `(tool/call ...)` closure plus the pre-execution tool guard
still apply). **`tool:` requirements are always validated** against the granted
`tools:` map and fail closed when ungranted — so a host-bound capability prelude
(like the `log/` introspection prelude) is guarded whether or not a runtime is
configured.

---

## 8. Iterating with the REPL

The REPL uses the **same** compiler, protected-namespace tables, export records,
and prompt-inventory renderer as SubAgent execution — it is not a parallel
implementation:

```bash
# Attach a prelude file and open the REPL
mix ptc.repl --prelude crm.clj            # alias: -p crm.clj

# Print the prompt inventory the agent would see
mix ptc.repl --prelude crm.clj --show-prompt-inventory

# Evaluate a program against the attached prelude
mix ptc.repl --prelude crm.clj -e "(ns-publics 'crm)"
```

`--prelude` is separate from `-l/--load` (which loads ordinary user code).
`--help` is side-effect-free — it never loads the prelude.

---

## 9. Traceability

When a prelude is attached, `step.prelude_trace` carries a **credential-free**
summary so a run's capability environment is reproducible from traces:

- prelude source hash and compiled-artifact hash,
- selected protected namespaces,
- the public export records (ref, namespace, symbol, arity, params, visibility,
  effect, provider, requires).

No closures, no private env, and no secrets appear in it.

---

## 10. Authoring conventions

- **One namespace, one declaration.** Put all of a namespace's defs under a
  single `(ns ...)` directive.
- **Curate Lisp-facing names** in kebab-case (`get-user`), even when the backing
  tool uses snake_case (`get_user`).
- **Keep wrappers recoverable**; reserve `!`-suffixed helpers for explicit
  aborts.
- **Hide implementation details** behind `defn-`; expose only what agents should
  call.
- **Mark rarely-used exports `:discoverable`** to keep the prompt inventory
  small while staying reachable via `(apropos ...)` / `(ns-publics ...)`.
- **Declare `requires`/`provider-ref` explicitly** when the backing call isn't a
  simple literal, so attach-time validation still protects you.

---

## 11. Troubleshooting

| Symptom | Cause & fix |
|---|---|
| `unknown namespace crm/...` at runtime | The prelude wasn't attached on this execution path. Confirm `prelude:` / `runtime_prelude:` is set; for SubAgents this covers loop, single-shot, and compiled agents. |
| `prelude attach failed: ... upstream:crm/get_user` (`:prelude_attach_failed`) | A public export `requires` an upstream operation the selected runtime doesn't provide. Configure/grant it, or attach without a `:runtime` to skip the upstream check. |
| `prelude attach failed: ... requires granted tool \`log_sessions\`` (`:prelude_attach_failed`) | A public export `requires` a `tool:<name>` the host did not grant. Add the closure to the run's `tools:` map (these are validated even with no `:runtime`). |
| `cannot redefine crm/get-user` / `crm is a protected namespace` | Agent code tried to `def`/`defn` into a protected namespace or over an export. Protected names are immutable from user code. |
| `namespace 'crm' is declared more than once` | Two `(ns crm ...)` directives in one file. Merge them. |
| `invalid visibility` / `:requires must be a list of strings` / `duplicate ... ref` | Bad export metadata — compilation fails fast. Fix the metadata. |
| `prelude evaluation exceeded sandbox limits` | A `(def ...)` constant's value is too expensive/large; constants are evaluated under a bounded sandbox at compile time. Use a cheaper constant. |
| A `:prompt` export doesn't show in the prompt | Check its visibility — `:discoverable` exports are intentionally omitted from the inventory (still discoverable). |

---

## See also

- [PTC-Lisp Specification §9.9 — Capability Prelude](../ptc-lisp-specification.md#99-capability-prelude) — language-level rules.
- [SubAgent Advanced](subagent-advanced.md#capability-prelude) — namespaces, the `user/` namespace, and prelude attachment in context.
- [Function Reference](../function-reference.md) — `doc`, `dir`, `meta`, `apropos`, `ns-publics`, `all-ns`, `ns-name`.
