# Prelude introspection

## Problem

`{:visibility :discoverable}` has exactly one consumer in the tree:
`Prelude.prompt_exports/1` (`lib/ptc_runner/lisp/prelude.ex:107`), a single
`Enum.filter` that keeps `:prompt` records. Every enumeration surface reads
through it:

- the prompt inventory (`mission_inventory.ex:123`, `:148`, `:184`);
- `kernel/mission-inventory` and `kernel/mission-model-context`, which replay
  the frozen inventory string — a byte-identical copy of the prompt;
- `cap/list` → `tool/cap-list` → `Environment.metadata/1`, which returns host
  capabilities and never prelude exports.

So a `:discoverable` export is reachable only by a caller that already knows its
name. The second state of the bit is unreachable. `cap` — whose own docstring is
"Capability discovery and envelope composition helpers" — is itself
`:discoverable`.

`dd2d2b25` removed the language-level discovery forms while removing MCP catalog
discovery. The deleted `Discovery` module was two-layered: prelude refs resolved
first (rank `-1`, "exact prelude refs do NOT fall through to MCP discovery"),
and only a miss fell through to builtins and MCP. Only the fallthrough layer was
MCP-specific. The prelude layer was collateral.

## Goal

Four introspection builtins over the attached prelude, usable identically from
the REPL, from workflow/mission source, and from one prelude reading another
prelude's docs. Plus one prompt line so a model knows they exist.

## Surface

| form | returns |
|---|---|
| `(dir)` | sorted vector of namespace names that have at least one public export |
| `(dir ns)` | sorted vector of export refs in `ns` |
| `(apropos query)` | sorted vector of export refs matching `query` |
| `(doc ref)` | prints rendered documentation, returns `nil` |
| `(export-meta ref)` | keyword-keyed map of structured metadata, or `nil` |

References are **strings** — `(doc "inspection/model-exchanges")`.

`doc` prints rather than returning, so documentation text flows through the
print budget instead of the result channel. In the REPL the reader is a human;
in a program the text is never the value you want to carry into the next turn.
`export-meta` is the structured sibling a prelude calls when it needs the data.

### Naming

The removed form was `(meta tool-ref)`. **Do not reuse that name.**
`clojure.core/meta` takes an object and returns its metadata map; a string-ref
export lookup is unrelated, and taking a core Clojure name for different
semantics contradicts the repo's Clojure-default policy and permanently burns
the name. `export-meta` says what it returns and collides with nothing.

`dir`, `doc`, and `apropos` keep their Clojure names. Their divergence is
narrower — same intent, prelude-scoped rather than var-scoped, string argument
rather than symbol — and is recorded as a DIV.

`describe` is already a builtin; it is not available as an alternative name.

### `export-meta` shape

Keyword keys, matching the `cap/describe` envelope convention.

```clojure
{:ref "inspection/model-exchanges"
 :namespace "inspection"
 :symbol "model-exchanges"
 :kind :function
 :arity 2
 :params ["run-id" "cursor"]
 :call "(inspection/model-exchanges run-id cursor)"
 :doc "..."
 :visibility :discoverable
 :effect :read
 :signature "(run-id :string, cursor :string?) -> {...}"}
```

Field rules:

- `:kind :constant` omits `:arity` and `:params`; `:call` is the bare ref, and
  `:type` replaces `:signature`.
- Variadic functions report `:arity :variadic` and keep `"&"` in `:params`.
- `:signature`/`:type` are omitted entirely when undeclared, not set to `nil`.
- `:doc` is `nil` when the export has no docstring.
- `:effect` is always present, `:unknown` included.
- `Export.tool_refs`, `requires`, `min_arity`, `declared_effect`, and the
  `parsed_*` fields stay internal — they describe capability wiring, not the
  calling contract.

### `doc` rendering

```
inspection/model-exchanges
(inspection/model-exchanges run-id cursor)
  (run-id :string, cursor :string?) -> {items [...], next_cursor :string?}
  effect: read

  Correlated model exchanges for one run, one page per call.
```

The contract line is omitted when unsigned, the docstring block when absent, and
a constant prints its bare ref as the call form. Output goes through
`EvalContext.append_print/2`, so it is subject to `max_print_length` truncation
like any other print.

### Misses and bad input

- Unknown ref, malformed ref (no `/`, empty namespace, unknown namespace), or
  no attached prelude: `doc` prints `No documentation found for "<ref>".` and
  returns `nil`; `export-meta` returns `nil`. A lookup miss is not a program
  failure.
- `(dir "unknown-ns")` returns `[]`; `(dir)` with no prelude returns `[]`.
- `apropos` matching is case-insensitive substring (`String.downcase/1`) over
  the ref and the docstring; an export with no docstring matches on ref alone.
  An empty or whitespace-only query returns `[]` — **not** every export.
- A non-string argument is a `{:type_error, …}`; wrong argument count is an
  `{:arity_error, …}`.

## Scope boundaries

Deliberately **not** included. Each was in the deleted code; none is needed.

- **No MCP or catalog layer.** No `discovery_exec`, no `tool/servers`, no
  upstream fallthrough, no source ranking. `PtcRunner.Upstream.*` is gone.
- **No builtin/Java coverage.** `apropos`/`dir` see prelude exports only, not
  `clojure.core`, curated Java classes, or the `Registry` surface. Builtins are
  already in the specification and `docs/function-reference.md`. This drops
  `@curated_namespaces`, `@class_aliases`, `@namespace_aliases`, and the
  tokenizing scorer.
- **No macro-like ref arguments.** The old forms accepted unquoted symbols via
  an `analyze_discovery_ref` clause and a `{:repl_discovery, …}` AST node.
  Strings only means no new AST node and no `analyze.ex` dispatch change.
- **No `(source ref)`.** It needed `Prelude.source_index`, no longer a field.
- **No `all-ns` / `ns-publics` / `ns-name`.** `(dir)` and `(dir ns)` cover it.
- **No options maps.** The old `apropos` took `{:limit n}`.
- **No result cap.** An introspection result is an ordinary Lisp value bounded
  by the same sandbox heap cap (`max_heap`, default 1,250,000 words) as any
  collection a program can build, and the export set it is drawn from is fixed
  when the host compiles the bundle. There is no per-run growth, so there is
  nothing to truncate and no silent cap to explain. (The 256 KiB inventory
  ceiling is *not* a bound here — it covers only `:prompt` exports.) `doc` is
  additionally bounded by `max_print_length`.
- **No inventory schema change.** `MissionInventory` version 2 and its frozen
  hashes are untouched. The prompt line is the entry point.

## Architecture fit

**Privates stay private.** Introspection reads `Prelude.exports`, which holds
public `:prompt` and `:discoverable` records only. `form_graph` also carries
`defn-` entries and is deliberately not the backing store. `(dir)` derives its
namespace list from the public export set rather than `Prelude.namespaces/1`, so
a namespace containing only private helpers does not appear.

**No new *execution* authority; it does add information.** Introspection returns
names, docstrings, and contract strings — never callables. Evaluated source can
already call every public export in the resolved bundle, `:discoverable`
included (`docs/guides/kernel-maintainer.md:126`), so nothing becomes callable
that was not callable before. What does change is that composition-internal APIs
(`cap`, `agent.prompt`) become *visible* to model-authored code. That is the
point of the change and it is a real widening of what a model can see; it is not
a widening of what it can do.

**Component dependency edges are not enforced here.** Those edges are validated
at compile time against resolved `{:prelude_call, ref}` forms and govern which
namespaces a prelude may *call*. `(doc "other/thing")` takes a runtime string;
there is no ref to validate and nothing to grant. Cross-component doc reads are
therefore possible and accepted.

**Introspection shows exactly what the caller can call.** Three mechanisms can
narrow the prelude surface a given run sees. All are ordinary `Lisp.run/2`
options, so an embedder can set them even though no code in this repository
does; ignoring them would advertise refs the caller cannot invoke and make the
prompt line false.

- **Grant projection** (`prelude_filtered_exports`, `lisp.ex:735`) — already
  handled. A narrowed grant hands the run a `%Prelude{}` whose `exports` list is
  already the narrow set; the option only carries the *removed* records so
  `PreludeScope.filtered_export/2` can produce a better analysis error.
  Introspection reads `prelude.exports` and is therefore narrowed for free.
- **`prelude_export_mask`** (`lisp.ex:734`) — honor it. This is not speculative
  semantics: the field's only three readers were `Discovery.prelude_dir/4`,
  `prelude_apropos_matches/3`, and `prelude_ns_publics/3`. It has always been a
  *discovery* mask, and it is orphaned precisely because discovery was deleted.
  Restoring its readers is restoring its purpose. Shape is
  `%{namespace => MapSet.t(ref)}`; `nil` means unrestricted;
  `normalize_export_mask/1` (`eval/context.ex:323`) already collapses malformed
  input and empty maps to `nil`. A namespace absent from the map is hidden, and
  within a present namespace only listed refs are visible.
  Unlike the deleted code — where `prelude_doc/2` and `prelude_meta/2` took no
  mask while the enumerations did — **all four forms are masked**. A mask that
  hides a ref from `dir` but reveals it to `doc` is not a mask.
- **`strict_transitive_calls` / `direct_namespaces`** (`eval.ex:903`) — honor
  it. It rejects a prelude call when the origin is session-authored and the
  namespace is neither direct nor free of transitive requirers. Applying the
  same predicate to introspection is what makes "exports found this way are
  callable" true by construction. Note it restricts only session-authored
  origins (`nil` or `:user_closure`), so a prelude reading another prelude's
  docs is never affected — exactly the goal case.

To keep one source of truth, extract the authorization decision from
`Eval.authorize_prelude_resolution/2` into
`EvalContext.prelude_ref_visible?/2`, which reads only `EvalContext` fields it
already exposes (`strict_transitive_calls`, `direct_namespace?/2`,
`transitive_namespace_requirers/2`, `current_origin/1`). `eval.ex` calls it for
enforcement and `apply.ex` calls it to build the introspection filter, so the
two cannot drift.

## Implementation

### 1. `PtcRunner.Lisp.Introspection`

New module. Pure, no evaluator coupling. Visibility arrives as a predicate the
caller builds, so the module never reads `EvalContext` and never invents its own
restriction semantics.

```elixir
@type visible :: (Export.t() -> boolean())

@spec namespaces(Prelude.t() | nil, visible) :: [String.t()]
@spec dir(Prelude.t() | nil, String.t(), visible) :: [String.t()]
@spec apropos(Prelude.t() | nil, String.t(), visible) :: [String.t()]
@spec export_meta(Prelude.t() | nil, String.t(), visible) :: map() | nil
@spec render_doc(Prelude.t() | nil, String.t(), visible) :: String.t()
```

`apply.ex` builds the predicate once per call from `eval_ctx`: mask membership
`and` `EvalContext.prelude_ref_visible?/2`.

### 2. Shared call rendering

`MissionInventory.export_call/1` is private and sits above `Lisp` in the
dependency order, so `Introspection` cannot call it. Move it to
`PtcRunner.Lisp.Prelude.Export` as `call_form/1` and have both `MissionInventory`
and `Introspection` consume it. This is what keeps the printed form and the
inventory form from drifting; without the move they are two copies.

### 3. Bindings and dispatch

- `lib/ptc_runner/lisp/runtime/builtins.ex` — `{:dir, {:special, :dir}}`,
  `{:apropos, {:special, :apropos}}`, `{:doc, {:special, :doc}}`,
  `{:"export-meta", {:special, :export_meta}}`.
- `lib/ptc_runner/lisp/eval/apply.ex` — a `do_apply_fun({:special, _}, …)`
  clause per form, reading `eval_ctx.prelude`. `doc` returns
  `{:ok, nil, EvalContext.append_print(eval_ctx, rendered)}` exactly as
  `println` does.
- **One shared invocation helper for both call paths.** The direct dispatcher
  returns `{:error, {:type_error, …}}` tuples; a HOF bridge cannot — it must
  raise through `HostContext.error!/1` (`eval/host_context.ex:89`). Route both
  through a single `invoke(op, args, eval_ctx)` that validates argument count
  and string-ness once and produces the canonical reason, so a bridge cannot
  leak a raw `FunctionClauseError` from `Introspection` misreported as a `map`
  failure.
- **`closure_to_fun/3` bridge per form — required, not optional.**
  `Runtime.Callable.call/2` has no `{:special, _}` clause and no `EvalContext`,
  so a special reaching HOF position via `closure_to_fun`'s pass-through clause
  errors. Verified: `(map println [1 2 3])` works only because
  `apply.ex:782` has a bespoke `{:special, :println}` bridge, while
  `(map apply [1 2])` — a special with no bridge — returns an error.
  The three read-only bridges are pure closures over `eval_ctx.prelude`. The
  `doc` bridge mirrors `println`'s: it calls `EvalContext.append_print/2`,
  discards the returned struct, and relies on the process-scoped
  `Capture.record_print/1` side channel (`eval/context.ex:365`) for the print to
  survive.
- `lib/ptc_runner/lisp/runtime/args.ex` — extend `valid_callable?/1`.
- `Runtime.Predicates.type_of/1` (`predicates.ex:364`) and `Runtime.Describe`
  (`describe.ex:575`) match `{tag, _, _}` — a **three**-element tuple — for
  `:special`, but specials are two-element `{:special, name}`. Today
  `(fn? apply)` returns `false` for exactly this reason. Add two-element
  `{:special, atom()}` recognition so the new builtins are not misclassified by
  `fn?`, `ifn?`, and `describe`. This incidentally corrects `(fn? apply)` to
  `true`; call that out in the PR body rather than special-casing four names and
  leaving the shape wrong.
- `lib/ptc_runner/lisp/eval/helpers.ex` — `describe_type/1` clauses.
- Document the two-element `{:special, atom()}` binding shape in `Env`'s binding
  model, which currently omits it.

### 4. Registry entries are compile-time, not documentation

`priv/functions.exs` is loaded at compile time by `Registry` and `BuiltinNames`
(`@external_resource` + `Code.eval_file/1`), and `SourceAtoms` derives the
bounded source vocabulary from it. Four entries with `dispatch: :env`,
`binding: :special`, `category: :core`, `section: "Introspection"` must land in
the same change as `Builtins.bindings/0`, or the drift guards in
`registry_test.exs` ("all env builtins are in registry", "no orphaned registry
entries", "binding type matches env.ex") fail. Then run `mix ptc.gen_docs`.

Set `ptc_extension?: true` and `clojure_var: nil` on all four. They are PTC
extensions over the attached prelude, not implementations of `clojure.repl/dir`
or `clojure.core/meta`, and declaring a `clojure_var` would put them in scope of
the conformance audit and `SpecValidator` guards that expect a Clojure-var
correspondence they cannot satisfy. `docs/clojure-conformance-gaps.md` gets a
note that the Clojure vars of these names remain unimplemented.

### 5. Prompt

One bullet in `priv/preludes/kernel/agent.prompt.clj` `render`, in the PTC-Lisp
block. It must name all four forms and state that discovered exports are
callable — otherwise it contradicts the existing "Generated programs run only
against the advertised mission API below" line.

```
- The API below is the prompt-visible subset; (dir) lists namespaces, (dir "ns") its exports, (apropos "term") searches, (doc "ns/name") prints documentation, (export-meta "ns/name") returns it as data. Exports found this way are callable.
```

### 6. Docs

- `docs/ptc-lisp-specification.md` — an Introspection section: prelude-only
  scope, `doc`-prints/`export-meta`-returns split, miss behavior.
- `docs/clojure-conformance-gaps.md` — DIV entries: `dir`/`doc`/`apropos` are
  prelude-scoped rather than var-scoped and take string refs; `clojure.core/meta`
  is not implemented and `export-meta` is not a substitute for it.
- `priv/functions.exs` — `quote`'s `see_also: ["dir", "doc", "meta"]` is a
  dangling reference to the removed forms. Reset to `[]`; refs are strings now.
- `docs/guides/components-and-preludes.md:29`,
  `docs/guides/kernel-maintainer.md:129`, `lib/ptc_runner/kernel/library.ex:22`
  — say how a `:discoverable` export is found, not only what it is withheld from.

## Testing

- **Unit** (`test/ptc_runner/lisp/introspection_test.exs`) — namespace listing
  excludes private-only namespaces; ref listing; substring match over ref and
  docstring; empty/whitespace query → `[]`; case-insensitivity; `export-meta`
  field set for function, constant, variadic, signed, unsigned, and nil-doc
  exports; unknown/malformed ref → `nil`; nil prelude → empty.
- **Rendering** — `doc` output for signed, unsigned, constant, variadic, and
  nil-doc exports; the miss line; `max_print_length` truncation.
- **Direct dispatch** — a successful direct call of every form and overload
  (`(dir)` and `(dir ns)`) plus nil-prelude behavior, exercised through
  `Lisp.run/2`. Pure-module tests do not prove the `{:special, _}` clauses.
- **HOF bridges** — the case that fails without a bridge:
  `(map export-meta (dir "ns"))`, plus `apply`, `partial`, `comp`, and `pmap`
  for each of the four forms, and `doc` inside `map` asserting prints are
  captured in order.
- **Restriction guards** — the tests that stop introspection drifting from
  callability. One run with `:prelude_export_mask` set: masked refs absent from
  `dir`/`apropos`, and `doc`/`export-meta` miss on them. One run with
  `:strict_transitive_calls` plus `:direct_namespaces`: a transitively-required
  namespace is absent from session-authored introspection, and every ref
  `apropos` does return is callable from that same program.
- **Predicates** — `fn?`, `ifn?`, `describe` over all four; plus the corrected
  `(fn? apply)`.
- **Arity and type errors** — each form with wrong count and non-string args.
- **Prelude-to-prelude** — the goal case. A two-namespace test bundle where an
  export in `a` calls `(export-meta "b/thing")` and returns it, and separately
  calls `(doc "b/thing")` — asserting on captured prints, since `doc` returns
  `nil`.
- **REPL** (`ReplSession`) — `(dir)`, `(dir "inspection")`, `(doc "…")` across
  session turns.
- **Discoverability regression** — the test that pins the point of the change:
  `inspection` is absent from the rendered prompt inventory *and*
  `(dir "inspection")` returns its exports. Both states of the bit observable in
  one test.
- **Privacy** — a bundle with a `defn-` helper: it appears in `form_graph` and
  in no introspection answer, and its namespace is absent from `(dir)` if it has
  no public exports.
- **Registry drift** — existing `registry_test.exs` guards must pass unchanged.

## Verification

`mix precommit`, then `MIX_ENV=dev mix docs --warnings-as-errors`.
