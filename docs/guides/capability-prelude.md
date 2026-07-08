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
> is no generic capability catalog yet. The optional `PreludeStore` authoring
> surface records new source versions, but it is host-gated, compile-checked,
> volatile in-memory state; stored preludes still do not mint credentials or
> tool authority. See `docs/plans/archive/capability-prelude-discovery.md` for
> the deferred catalog/profile work.

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

Prompt-visible exports are summarized in the shared symbol inventory assembled
dynamically — the core prompt templates stay domain-blind (they never mention
`crm`). Each entry carries an explicit kind and usage shape: `defn` exports are
functions, while `def` exports are values used directly. `:discoverable` exports
are omitted from the inventory but still reachable via the discovery forms (§6).
The renderer output does not include prelude source; `(source ...)` remains a
separate discovery form.

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
> default completely. A guard that stops with its own `%PtcRunner.Step{}` has
> that step adopted verbatim as the final result — build it from the loop
> state the guard received (especially its memory) rather than from
> externalized values, or keyword identity is lost downstream.

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
(source 'crm/get-user)   ; prints the rendered defining form, returns nil
(apropos "user")         ; fuzzy search across prelude + local + MCP
```

Exact prelude-export refs resolve through the prelude first; private helpers
have no export record, so they never appear in `doc`/`meta`/`ns-publics`/
`apropos` and are not callable by qualified symbol. The one exception is
`source`: a private helper a public export reaches is readable via
`(source 'crm/<helper>)` (read-only — it shows the body, it does not make the
helper callable). `source` is prelude-only: an unknown ref prints
`"no source available"` and returns `nil`.

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
and shared symbol-inventory renderer as SubAgent execution — it is not a
parallel implementation:

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

Hosts that already have multiple prelude sources can compose them in process
without a store:

```elixir
PtcRunner.Lisp.run(program,
  prelude: [
    %{id: "log", source: log_source, origin: :memory},
    %{id: "paged", source: paged_source, origin: {:file, "priv/paged.clj"}}
  ]
)
```

Selections are concatenated in explicit order, duplicate namespaces fail closed,
and the aggregate is compiled once into the same `%PtcRunner.Lisp.Prelude{}`
artifact used by the single-prelude path.

For in-process prelude iteration, hosts can use the volatile core store:

```elixir
{:ok, store} = PtcRunner.PreludeStore.new()
{:ok, v1} = PtcRunner.PreludeStore.write(store, "paged", paged_source_v1)
{:ok, v2} = PtcRunner.PreludeStore.write(store, "paged", paged_source_v2)

{:ok, candidate} =
  PtcRunner.PreludeStore.read(store, %{id: "paged", version: v2.version})

candidate.compiled
```

`PreludeStore` is compile-on-write with bounded in-memory retention. Every
successful `write/4` creates a new monotonic version and makes it the
current/default version for that id. A bare id reads the current/default
version, `"paged@7"` reads an explicit retained version, and
`%{id:, version:, checksum:}` adds a checksum assertion. Older superseded
versions may be pruned once the per-id retention window is full. An explicit
version selected with `set_default/4` is retained alongside that latest-version
window, even if later writes move the default back to the newest version.

The store keeps explicit default selection separate from newest-version
tracking:

```elixir
{:ok, _selection} =
  PtcRunner.PreludeStore.set_default(store, "paged", v1.version, %{
    "reason" => "verifier preferred v1"
  })

{:ok, current} = PtcRunner.PreludeStore.read(store, "paged")
current.version
# => 1

[%{current_version: 1, latest_version: 2}] = PtcRunner.PreludeStore.list(store)
{:ok, history} = PtcRunner.PreludeStore.history(store, "paged")
```

Use `history/2` to inspect retained versions for one id. Use `set_default/4`
only for an explicit host-owned promotion or rollback after verification; it
does not delete later versions, but normal retention pruning may still remove
superseded rows that are neither explicitly selected nor inside the retained
latest-version window.

For reproducible experiments and operator handoffs, the store also supports
host-side state capture:

```elixir
{:ok, snapshot} = PtcRunner.PreludeStore.snapshot(store)
{:ok, restored} = PtcRunner.PreludeStore.restore(snapshot)
diff = PtcRunner.PreludeStore.diff(snapshot, restored)
{:ok, manifest} = PtcRunner.PreludeStore.export(restored, "priv/preludes")
```

`snapshot/1` and `restore/2` preserve retained version numbers, current/default
selections, dependency pins, checksums, and stale-base safety state. `diff/2`
compares snapshots or a snapshot against a live store. `export/3` writes the
current source files plus a manifest and `.deps` sidecars compatible with the
existing seed-directory loader. Because export is a flattened current-source
seed, sidecars use seed-local dependency ids while the manifest records the
original pinned dependency versions. See `PtcRunner.PreludeStore` for the exact
snapshot format and error contracts.

Stored source and metadata are untrusted prompt surfaces. Use
`PtcRunner.PreludeCandidate.public_view/1` for model-facing projections.
Model-facing store tools keep source bounded and filter metadata to documented
public scalar keys; private backing-tool ledgers summarize source args and
filter metadata before traces or `step.tool_calls` retain them.

MCP sessions can attach host-shipped `prelude/` wrappers over private store
tools. When a prelude store is configured and no separate runtime prelude is
already attached, read-only sessions receive the read-only wrapper for
inspection (`list`, `history`, `read`, `source`, `forms`, `form-deps`, `deps`,
`form`). Editor sessions receive the full wrapper only when the operator starts
with `--sessions-allow-prelude-write` and the session starts with
`mode: "write_capable"`. The model-visible API includes:

```clojure
(prelude/list)
(prelude/history "paged")
(prelude/read "paged@2")
(prelude/source "paged")
(prelude/forms "paged")
(prelude/form-deps "paged" "some-helper")
(prelude/deps "paged")
(prelude/form "paged" "some-helper")
(prelude/write {:id "paged" :source new-source :metadata {:reason "add profile"}})
(prelude/edit {:id "paged" :edits [...] :metadata {:reason "add profile"}})
(prelude/set-default {:id "paged" :version 1 :metadata {:reason "rollback"}})
```

`prelude/forms`, `prelude/form-deps`, and `prelude/deps` project the compiled
`form_graph` (no re-parsing) for a stored candidate by id or `id@version`:

- `(prelude/forms id)` — one row per top-level form (public AND private,
  including unreferenced/dead helpers), sorted by name: `name`, `visibility`
  (`"public"`/`"private"`), `kind` (`"function"`/`"constant"`), `arity` (int or
  `"variadic"`), a bounded `doc`, and `byte_size` (the form's exact source
  span length; omitted, cosmetic fail-soft, on the rare read-time scan
  failure of an already-compiled candidate).
- `(prelude/form-deps id name)` — one named form's direct sibling `calls`
  (each entry carries its own `visibility`), plus `requires`/`tool_refs` split
  into `direct` (the form's own body) and `transitive` (the closure over the
  siblings it calls) — the transitive view is what widens when a private
  helper's authority changes.
- `(prelude/deps id)` — the whole intra-namespace direct-reference graph,
  `{name -> [direct sibling names]}`, covering every form including dead
  privates.

An unknown id returns the same public `not_found` error as `prelude/read`; an
unknown form name returns `{:reason "form_not_found" :id id :name name ...}`.
All three carry structure and authority facts only — no source text below the
whole-candidate `prelude/source` bound.

`(prelude/form id name)` returns the named form's EXACT byte-slice source
text — `{name:, visibility:, source:}` — located via a byte-exact top-level
span scanner (`PtcRunner.Lisp.Prelude.FormScanner`), never a re-rendered
approximation. `source` is bounded the same way `prelude/source` bounds a
whole candidate (64 KB); an oversized form fails closed with
`{:reason "source_truncated" :source_bytes n}` rather than truncating. As
with `forms`/`form-deps`/`deps`, `name` is keyed against `form_graph` — the
`(ns ...)` directive itself is not a valid `name` here; it is reachable only
through `prelude/edit`'s `set_ns_doc` op.

`(prelude/edit {:id :edits :metadata})` applies a form-keyed BATCH of edits to
the CURRENT candidate for `id` and writes the spliced result as one new
version — the model emits only the deltas; the server holds the text and
performs the splice, so untouched forms are byte-identical by construction.
Each entry in `:edits` is a map with an `"op"` (values use underscores, e.g.
`"replace_form"`, not `"replace-form"`):

```clojure
(prelude/edit
  {:id "paged"
   :edits [{:op "replace_form" :name "inspect" :source "(defn inspect [] {:v 2})"}
           {:op "add_form" :source "(defn- helper [] 1)" :placement "before" :anchor "inspect"}
           {:op "remove_form" :name "dead-helper"}
           {:op "set_ns_doc" :doc "Updated namespace doc."}]
   :metadata {:reason "cleanup"}})
```

- `replace_form` swaps a named form's definition; the head may change freely
  (`defn` <-> `defn-` <-> `def`) — a visibility flip is an ordinary replace,
  surfaced in the result's `public_surface` diff, not rejected.
- `add_form` inserts a new named form; `:placement` is `"end"` (default),
  `"before"`, or `"after"` (`"before"`/`"after"` require `:anchor`).
- `remove_form` deletes a named form and its header comments.
- `set_ns_doc` replaces (or inserts, if absent) only the `(ns ...)` form's
  docstring.

All ops resolve against the CURRENT candidate's spans and splice in one pass;
a batch is rejected outright (no partial application) when two ops target the
same form, an `add_form` anchors to a form the same batch removes, an
`add_form` name already exists or is added twice, or a target/anchor name
does not exist. Removing a helper another surviving form still calls fails
the existing compile gate, naming the now-undefined symbol. Editing a
non-current base is rejected as `:stale_base` — like `prelude/write`,
edit-and-fork is not supported.

On success the result is `prelude/write`'s result (`id`, `version`,
`checksum`, `namespaces`, `exports`, `metadata`) plus:

- `base_version`/`parent_checksum` — the version and checksum this edit was
  applied against;
- `forms` — `{replaced:, added:, removed:, ns_doc_set:}`, the names touched;
- `public_surface` — `{added:, removed:, changed:}`, diffing the OLD and NEW
  compiled `form_graph` (every form, not only exports — so a `defn`/`defn-`
  visibility flip surfaces as `changed` rather than silently disappearing).
  Each per-form view carries visibility/kind/arity/effect AND the form's
  authority — for public names the compiled export's `requires` union
  (body-inferred + explicit metadata), `provider_ref`, and
  :prompt/:discoverable `export_visibility`; for privates the
  graph-transitive view — so an authority-only edit (swapping a helper's
  `tool/call` target, or touching only explicit export metadata) still
  lands in `changed`. A human reviewer sees every capability-relevant
  change without a source diff.

`prelude/set-default` accepts an optional checksum:

```clojure
(prelude/set-default
  {:id "paged"
   :version 1
   :checksum "..."
   :metadata {:reason "verified candidate"}})
```

`PtcRunner.Session` can resolve store refs once at session start and freeze the
compiled bundle for that session:

```elixir
session = PtcRunner.Session.new(prelude_store: store, preludes: ["paged"])
{{:ok, step}, session} = PtcRunner.Session.eval(session, "(paged/inspect)")
```

### Composing preludes: declared dependencies

A stored prelude can call another stored prelude's **public** exports by
declaring the dependency at write time (`requires_preludes`, a vector of
`"id"` or `"id@version"` strings):

```clojure
(prelude/write {:id "audit"
                :source audit-source
                :requires_preludes ["base"]})
```

The write resolves each declared dep from the store (a bare id resolves to
the **current version at write time**), compiles the candidate with the
deps' export tables in scope, and records the resolution as explicit pins —
echoed and stored as `prelude_deps` metadata
(`[{:id "base" :version 2 :checksum "..."}]`). Because a dep must already
exist before its dependent can be written, the dependency graph is acyclic
by construction. Write-time validation is the same analyzer user code gets:
wrong arity and calls to non-exports are rejected precisely, and `defn-`
privates of the dep have no export record, so they are unreachable across
preludes — the library boundary comes for free.

Attach resolves the transitive pin closure: selecting `["audit"]` auto-pulls
`base@pinned`, and the session's resolved refs mark auto-pulled components
with `required_by: ["audit"]`. A session needing two different versions of
the same prelude (directly or transitively) fails closed at session start,
naming the requirers. Identical refs deduplicate to one component.

Rules worth knowing:

- **Pins do not float.** Upgrading `base` does not change `audit` until
  `audit` is rewritten or re-edited. `prelude/edit` inherits the base
  version's resolved pins (`base@2`, not the bare declaration); pass an
  explicit `requires_preludes` to change them, or `[]` to drop them.
- **`def` initializers cannot reference deps** (`:dep_ref_in_def`): constant
  initializers evaluate at prelude compile time under a no-op tool executor,
  where a dep call would silently compute garbage. Wrap the value in a
  `defn` instead.
- **Authority is unioned.** An export that reaches a dep export inherits its
  transitive `requires`/`tool_refs`, so attach-time validation and the
  pre-execution tool guard see the full capability surface — a dependent
  cannot smuggle a tool call in through a dep.
- **Undeclared cross-namespace calls still fail** at write with
  `unknown namespace` — declaration is the only path to visibility, even if
  the other prelude exists in the store.
- Dep-pinned versions are retained by the store's pruning ring, like
  `set_default` pins — a pin can never dangle.
- The MCP server's boot seeding (`--prelude-store-seed`) declares seed-file
  deps via a sidecar: `audit.clj` + `audit.deps` (one `id`/`id@version` ref
  per line, `#` comments allowed); seed order is resolved automatically.

Note the naming: `requires_preludes`/`prelude_deps` are **prelude-level**
dependencies; `(prelude/form-deps id name)` and `(prelude/deps id)` remain
**form-level** introspection within one namespace.

---

## 9. Traceability

When a prelude is attached, `step.prelude_trace` carries a **credential-free**
summary so a run's capability environment is reproducible from traces:

- prelude source hash and compiled-artifact hash,
- selected protected namespaces,
- component ids, hashes, namespaces, and origins when the prelude was composed
  from multiple selected sources,
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
