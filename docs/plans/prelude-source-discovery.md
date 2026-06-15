# Prelude Source Discovery — Plan

**Status:** implementation-ready (codex rounds 1–3; round 3 clean — no P1/P2). Scopes GitHub
issue #1095 (add a `source` REPL discovery form for attached preludes). Builds
directly on the macro-like discovery-form machinery shipped in #1094
(`doc`/`meta`/`dir`/`ns-publics`/`ns-name` accept unquoted symbols via
`analyze_discovery_ref/1`). This plan folds in a code-verified design review:
the raw-AST renderer this feature needs already exists, so the work is source
*retention* and *wiring*, not building a printer. See "Review log" for the
round-1 corrections.

## Motivation

Paged-prelude smoke runs (#1094 follow-up) show a model can now discover the
`paged` namespace (`ns-publics`), read docstrings (`doc`), and get useful
errors — but it still cannot repair incorrect prelude usage when the docstring
is not enough, because it cannot see the *shape* behind a helper like
`paged/profile`. `clojure.repl/source` is the idiomatic answer and slots into
the existing `doc`/`dir`/`meta`/`apropos` discovery family.

The honest scope question this plan answers up front: a `source` that stops at
the public export body — which references private helpers the model cannot
inspect — is the cosmetic version, most likely to go unused. The useful version
makes same-namespace **private helpers addressable by ref** too. That is cheap
here (same renderer, same store) and is the difference between a feature that
can drive repair and a demo. See D4.

## What already exists (verified against source)

The feature does **not** need a new source renderer. The pieces are present:

- **Raw definition forms are captured.** `%Spec{}` holds `params_form` and
  `body_form` as *raw parser AST* (`lib/ptc_runner/lisp/prelude/spec.ex:20-21`).
  Desugaring (`->`/`->>`, `#()`, `#"re"`) happens later in `analyze.ex`, not in
  the parser, so `body_form` retains author *structure* (macros un-expanded).
- **A raw-form assembler exists.** `spec_to_defn_form/1`
  (`lib/ptc_runner/lisp/prelude/compiler.ex:1058-1067`) reconstructs a raw
  `(defn …)` / `(def …)` form from the original params + body, already handling
  the constant case (`params_form: nil → (def name value)`).
- **A raw-AST printer exists.** `PtcRunner.Lisp.Formatter` formats raw parser
  AST (`:symbol`, `:list`, `:vector`, `:map`, `:ns_symbol`, …) and is
  roundtrip property-tested (`test/.../formatter_test.exs`). It is distinct from
  `CoreToSource`, which prints the *analyzed/desugared* representation.

So the content renderer is `Formatter.format(spec_to_source_form(spec))`. The
two design subtleties this plan exists to pin down are **where rendered source
is stored** (D1) and **why `spec_to_defn_form` cannot be reused verbatim** (D3).

## Architecture decisions

### D1. Store precomputed source strings in a `Prelude.source_index` map

Render once at compile time, store the string, let the hot discovery path read
it — identical in spirit to how `doc`/`meta` already serve precomputed strings.

The storage *target*, however, is **not** `Export.source`. Verified: by the
time a `%Prelude{}` exists, every raw `Spec` has been consumed and discarded.
The compile pipeline is `collect_specs → build_exports → build_runtime`
(`compiler.ex:60-63`); `build_runtime` analyzes `spec_to_defn_form(spec)` into
**closures** stored in `private_env`, and the final struct keeps only
`exports`, `private_env`, `namespaces`, `source_hash`, `metadata`
(`prelude.ex:62-66`). The `ns_specs` name in the compiler is a transient
`group_by` binding (`compiler.ex:611,619`), not a retained field. Raw specs —
public and private — are gone.

Two consequences:

1. Source must be captured **during compile**, while specs still exist (in
   `build_exports`/`collect_specs`), not derived later from the struct.
2. Private exports have no `%Export{}` record, so `Export.source` could never
   hold them. A `Prelude`-level map keyed by full ref covers both visibility
   classes in one path and keeps `Export` lean (preserving its "string-backed,
   no leaked atoms" discipline, `export.ex:14-17`).

**Decision:** add `source_index :: %{String.t() => String.t()}` to `%Prelude{}`,
keyed by full ref (`"paged/profile"`, `"paged/fold-pages"`), populated at
compile time for **all** specs (public and private). Store rendered *strings*,
not raw forms — strings are deterministic, bounded, and consistent with the
existing no-raw-atoms design; they also avoid growing the struct's serialization
surface with parser AST.

### D2. `source` is prelude-only, with no MCP fallthrough

Unlike `doc`/`meta` (which fall through to MCP tool discovery on unknown refs,
`eval.ex:1733-1739`), `source` resolves **only** against the attached prelude's
`source_index`. There is no upstream/builtin source in V1 (deferred, see
"Explicitly deferred"). This makes the `:source` dispatch *simpler* than
`doc`/`meta`: prelude-hit or unavailable, never a catalog op, never a network
call. It is a deliberate divergence from the sibling forms — name it in the
docs.

### D3. Render via a new `spec_to_source_form/1` from a retained raw `metadata_form`, plus an effective-metadata header

`spec_to_defn_form/1` is built for *closure construction*, so it deliberately
drops exactly what `source` must keep. It emits only `[:defn, symbol, params |
body]` — **no docstring, no metadata map, and it normalizes `defn-` → `defn`**
(`compiler.ex:1058-1067`). Reuse it and `source` would erase the author's
metadata and hide that a helper is private. So `source` needs a sibling
assembler, `spec_to_source_form/1`. Two corrections from review make this
non-trivial:

**(a) `spec.metadata` is NOT renderable AST.** It is a *normalized Elixir map*
produced by `normalize_meta/1` (`compiler.ex:899-925`): keyword keys → binary
strings, keyword values → `{:keyword, "..."}`, strings → bare binaries, vectors
→ Elixir lists. `Formatter` formats raw parser AST and **cannot** format an
Elixir map or a plain list as a metadata value. Reconstructing `{:map, pairs}`
from the normalized map is lossy and order-destroying.

**Decision:** retain the **raw** metadata form on `%Spec{}` — add
`metadata_form :: {:map, [pair]} | nil`, captured in `handle_defn`/`handle_def`
*before* `normalize_meta` runs. `spec_to_source_form/1` then splices
`metadata_form` straight into the rendered form (Formatter-renderable, original
key order preserved). `spec.metadata` (normalized) stays as-is for everything
else. This also resolves the key-order fidelity concern.

`spec_to_source_form/1` emits, reading only fields the `%Spec{}` carries:
- `defn-` when `spec.private?`, else `defn` (the keyword carries
  visibility-for-privates);
- the docstring as a leading `{:string, doc}` when `spec.doc` is non-nil;
- `metadata_form` spliced in when present;
- constants: `(def name value)`, or `(def name "doc" value)` when `spec.doc`.

**(b) Author-literal metadata is usually absent for visibility — so add an
effective-metadata header.** Verified against the `@crm_source` fixture:
`get-user` has **no** defn-level metadata (`spec.metadata == %{}`); its
visibility is inherited from the `(ns crm … {:visibility :prompt})` directive
(`compiler.ex:298`). `list-users`, by contrast, *does* carry
`{:visibility :discoverable}` on the defn. So rendering only author-literal
metadata would show visibility for `list-users` but not `get-user` — and the
issue explicitly asks to surface visibility.

**Decision:** prepend a single **labeled** effective-metadata comment derived
from the resolved `%Export{}` (or `defn-` for privates), then the faithful
form:

```clojure
;; paged/profile — visibility: prompt, effect: read, arity: 2 (effective)
(defn profile
  "Compute sample, field presence, string-type counts, and one exact composite-key collision count in one pass."
  [source opts]
  …)
```

For a **private** ref (no `%Export{}`) the header is `visibility: private,
arity: N` from the `%Spec{}`, with `effect` omitted (not computed for privates;
see L1 step 4). The `(effective)` label is load-bearing: the **form** stays
verbatim author metadata (often none), while the **header** carries resolved
visibility/effect without masquerading as source the author wrote. This is the honest
reconciliation of "include visibility" with "preserve author shape" — and it
reverses my earlier "no header" position, which review showed would hide
visibility in the common ns-inherited case. The header is *not* a `meta`
duplicate: `meta` returns structured data; this is a one-line provenance hint
ahead of source.

**Fidelity disclaimer (document it):** the form is a *normalized* rendering.
Author *structure* is preserved (macros un-expanded) and metadata key order is
preserved (via `metadata_form`), but **comments and original whitespace are
not** — the reader discards them. Verbatim source with comments is option 3
(source spans) and is explicitly deferred.

### D4. Private helpers are addressable by ref, but not auto-expanded

Same-namespace privates are renderable for the same cost (D1 stores them) and
leak **no call capability** — `source` is read-only, privates remain
non-invokable, and the public body already names them (`fold-pages`,
`add-profile-row`). Excluding them guts the feature exactly where the real logic
lives.

**Decision:** populate `source_index` with public exports **plus the private
helpers transitively reachable from some public export**, so
`(source paged/fold-pages)` works. Each call returns **one ref's** form;
`source` does **not** transitively expand a body's private dependencies (keeps
each call bounded by the print cap and mirrors `doc`/`meta`'s one-ref shape).
The model walks the chain by issuing successive `source` calls on the names it
reads in the body.

**Why reachable-only, not all privates (review correction).** Indexing *every*
private would turn `(source ns/guessed-name)` into an existence oracle —
"source available" vs "no source available" leaks which private names exist,
independent of any public body. Restricting the index to transitively-reachable
privates keeps the property true that **every indexed private is named in some
reachable public chain**, so a private is discoverable only by reading a body
that mentions it (directly or one hop further in).

**Implementation hook (round-2 correction).** Do **not** call
`transitive_backing/1` for this — it builds the right graph but **discards it**,
returning only `%{requires, tool_refs}` (`compiler.ex:649-655`), so it cannot
tell you which private *symbols* are reachable. The reusable machinery sits one
level down and must be lifted into a new helper, `reachable_private_symbols/2`:
1. build the per-symbol same-namespace call graph exactly as `transitive_backing`
   does internally — `collect_refs/3` over each body, filtered to `ns_symbols`
   (`compiler.ex:638-647`, `699+`);
2. for each public export, walk that graph transitively (the `reachable_ids/4`
   closure-walk pattern, `compiler.ex:686-697`, but accumulating *symbols*);
3. keep reachable symbols whose `%Spec{}` is `private?`;
4. union across public exports.

Scope the graph **per namespace** (as `transitive_backing(ns_specs)` already
does via `group_by`): `collect_refs` records *bare* symbol strings and the
same-namespace filter uses `ns_symbols`, so build one graph per namespace and
key lookups by `{namespace, symbol}` — never one global bare-symbol graph
(distinct namespaces can reuse a helper name).

The index is then `public exports ∪ reachable_private_symbols(public, specs)`.
Unreferenced ("dead") privates stay hidden. (Rejected alternative: index all
privates and document the oracle — simpler, but private *names* then leak by
probing; reachable-only reuses existing graph code and keeps the weaker
exposure.)

This creates a second deliberate divergence (alongside D2) that must be named:
reachable private refs become **`source`-referenceable but invisible to
`doc`/`meta`/`ns-publics`** (they have no `%Export{}`).

### D5. `source` routes through the print channel, returns nil

Source bodies are multi-line; the result channel's MCP `:slim` budget (512
chars) would shred them — the same reason `doc` prints rather than returns
(DIV-51). On the **success path** `source` mirrors `doc`: render → print →
return `nil` (`route_doc_to_prints`, `eval.ex:1736`).

The **unavailable path is source's own**, not doc's (review correction): an
unknown `doc` ref falls through to local/MCP discovery and may *raise*
(`eval.ex:1733-1739`), whereas an unknown `source` ref prints "no source
available" and returns `nil` (D2). So D5 only claims doc-parity for the
print-and-return-nil *success* shape, not the miss behavior.

The print channel is **not** unbounded: the Lisp-level `:max_print_length`
(default 2000, `eval/context.ex`) truncates large prints just like long
docstrings. Inherit that behavior, document the cap, and note that deployments
raise `:max_print_length` for large exports. Do **not** invent a separate
source-only bypass.

### D6. Exposure class: implementation, not contract

`doc`/`meta` expose signature + docstring (the *contract*). `source` exposes the
whole body (the *implementation*) — a genuinely new exposure class, more so with
privates (D4), whose bodies were never surfaced anywhere before. A hardcoded
threshold, path, or magic constant in a body becomes visible to the model.

This is bounded correctly (attached preludes only; no arbitrary filesystem
reads; D2), but the docs must state the category precisely: **"`source` reveals
implementation, not just contract; deployments must keep secrets and credentials
out of prelude bodies, not just out of docstrings."**

## Implementation walkthrough (by layer)

### L1 — Compiler: capture source at compile time

`lib/ptc_runner/lisp/prelude/compiler.ex`, `lib/ptc_runner/lisp/prelude/spec.ex`,
`lib/ptc_runner/lisp/prelude.ex`.

1. Add `metadata_form :: {:map, [pair]} | nil` to `%Spec{}` (`spec.ex`),
   captured in **`handle_defn`** (`compiler.ex:240,252`) **before**
   `normalize_meta/1` runs (D3a). This is the only Formatter-renderable,
   order-preserving source of the author's metadata. Note: `handle_def`
   (`compiler.ex:271`) accepts only `(def name value)` / `(def name "doc"
   value)` — constants carry **no** metadata map today, so `metadata_form` is
   always `nil` for constants (extending constant metadata syntax is out of
   scope; the constant's effective visibility still shows in the header).
2. Add `spec_to_source_form/1` (D3) beside the existing `spec_to_defn_form/1`.
   Keep `spec_to_defn_form/1` unchanged — it must stay the de-metad form for
   closure construction; `check_prelude_vars`/`build_runtime` depend on its
   current shape. `spec_to_source_form/1` emits `defn-`/`defn` per `private?`,
   the docstring, and `metadata_form`.
3. Build `source_index` from the **public exports ∪ reachable privates** (D4),
   each entry `{spec_ref => header <> "\n" <>
   Formatter.format(spec_to_source_form(spec))}`. `spec_ref` is
   `"#{namespace}/#{symbol}"`. Compute the reachable-private set via the new
   `reachable_private_symbols/2` (D4) — not `transitive_backing/1`. Build the
   index in `compile/1` after `build_exports` (`compiler.ex:60-63`), where both
   the raw `specs` and the resolved `exports` are in hand — both are needed for
   the header (next item).
4. The effective header (D3b) is sourced per ref:
   - **public** ref → resolved `%Export{}` (`visibility`, `effect`, `arity`),
     available post-`build_exports`;
   - **private** ref → has no `%Export{}`; use `visibility: private`, `arity`
     from `%Spec{}.arity`, and omit `effect` (effect resolution lives in the
     export pipeline and is not computed for privates).
5. Add `source_index: %{}` to `%Prelude{}` defstruct + `@type t`
   (`prelude.ex:53-66`) and set it in `compile/1`'s struct literal
   (`compiler.ex:66-72`).
6. `artifact_hash`/`source_hash` semantics unchanged — source is already
   covered by `source_hash` (sha256 of the prelude text). `source_index` is a
   convenience cache of a deterministic function of the same text; it need not
   feed a new hash.

### L2 — Discovery: `prelude_source/2`

`lib/ptc_runner/lisp/discovery.ex`. Mirror `prelude_doc/2`
(`discovery.ex:236-243`):

```elixir
@spec prelude_source(Prelude.t() | nil, term()) ::
        {:ok, String.t()} | :unknown | {:programmer_fault, String.t()}
def prelude_source(prelude, ref) do
  with {:ok, name} <- normalize_ref(ref, "source") do
    case prelude do
      %Prelude{source_index: idx} ->
        case Map.fetch(idx, name) do
          {:ok, src} -> {:ok, src}
          :error -> :unknown
        end
      _ -> :unknown
    end
  end
end
```

`normalize_ref/2` already accepts `{:symbol_ref, _}` / string / atom (reused
from #1094), so quoted/string/unquoted refs all arrive as a string `name`.

### L3 — Parser + analyzer: register and dispatch `source`

`lib/ptc_runner/lisp/source_atoms.ex`, `lib/ptc_runner/lisp/analyze.ex`.

0. **Register the atom first (review-found P1).** `source` must be added to the
   bounded `@special_forms` table in `source_atoms.ex:92-107` (which currently
   lists `quote apropos dir doc meta ns-publics all-ns ns-name` but **not**
   `source`). Without this, `intern/1` leaves `"source"` a string, the parser
   produces `{:symbol, "source"}` (binary, not the atom `:source`), and the
   `dispatch_list_form({:symbol, :source}, …)` clause is **unreachable**. This
   is the single most likely "wired everything but it doesn't fire" failure;
   the L4 dispatch and the test in "parser/analyzer reachability" both guard it.
1. Add a `dispatch_list_form({:symbol, :source}, [ref_ast], …)` clause that
   calls `analyze_discovery_ref(ref_ast)` (the #1094 helper) → `{:repl_discovery,
   :source, [ref]}`, plus the arity-error clause, mirroring `doc`/`meta`
   (`analyze.ex:476-496`).
2. Add `:source` to `@shadowable_forms` (`analyze.ex:25-68`) so `(let [source
   x] …)` rebinds it, and ensure it surfaces in `supported_forms/0`
   (`analyze.ex:93-94`), consistent with the other discovery names.
3. `source` as a bare value (`{:var, "source"}`) stays unbound — call-position
   only, like `doc`.

### L4 — Eval dispatch: handle `:source`, print-route, unavailable shape

`lib/ptc_runner/lisp/eval.ex`.

1. In `invoke_discovery/3` (`eval.ex:1714`), add a `:source ->` branch that
   does **not** go through `invoke_prelude_ref_discovery`'s MCP-fallthrough path
   (D2). Resolve against `Discovery.prelude_source(prelude, ref)`:
   - `{:ok, src}` → route through prints (D5), return `nil`.
   - `:unknown` → print `"no source available for #{ref}"`, return `nil`
     (D2/unavailable shape). **Never raise, never hit `discovery_exec`.**
   - `{:programmer_fault, msg}` → raise `ExecutionError` (malformed ref, same
     as the other forms).
2. Reuse/parallel `route_doc_to_prints` (`eval.ex:1736`) for the print routing.
3. `normalize_catalog_value` already maps `{:symbol_ref, name}` → string
   (`eval.ex:2104`), so no new normalization.

`(source map)` (a core builtin) and `(source missing/ns)` both land on
`:unknown` → the uniform "no source available" print + `nil`. This is what
satisfies the issue's "without confusing tool-discovery fallback."

### L5 — MCP session projection: advertise `source`

`mcp_server/lib/ptc_runner_mcp/sessions/projection.ex:100-124`. The
per-namespace map already emits `namespace`/`doc`/`discover`. Add a `source`
hint pointing at a representative prompt export of that namespace:

```elixir
%{
  "namespace" => namespace,
  "doc" => compact_doc(doc),
  "discover" => "(ns-publics '#{namespace})",
  "source" => "(source #{namespace}/#{representative_symbol})"
}
```

`representative_symbol` = the first prompt export in the namespace (already in
hand via the `Enum.group_by(& &1.namespace)` grouping at line 105 — thread the
`exports` instead of discarding them with `_exports`). Omit the field if a
namespace somehow has no prompt export.

### L6 — SubAgent prompt inventory: advertise `source`

`lib/ptc_runner/lisp/prelude/prompt_inventory.ex` — the inventory renderer is
`PtcRunner.Lisp.Prelude.PromptInventory.render/2` (consumed by
`sub_agent/system_prompt.ex`), not ad-hoc text in `system_prompt.ex`. When
`runtime_prelude` is attached, the inventory hint becomes:

```clojure
;; Use (ns-publics 'ns), (doc ns/name), and (source ns/name) to inspect attached preludes.
```

Same workflow text in both MCP sessions and SubAgent loops (issue requirement).

### L7 — Docs / conformance

- `docs/ptc-lisp-specification.md` discovery table (§9) — add a `source` row:
  prelude refs only, prints + returns nil, macro-like ref. Regenerate
  `priv/spec/checksums.ex` (`mix ptc.update_spec_checksums`).
- `docs/clojure-conformance-gaps.md` — note `source` as supported for prelude
  refs (Clojure's `clojure.repl/source` analog), unavailable elsewhere for now.
- `priv/functions.exs` — add the `source` entry (Discovery section); regenerate
  `docs/function-reference.md` + `docs/conformance/index.md` via
  `mix ptc.gen_docs`.
- `docs/aggregator-mode.md` — add `source` to the discovery table with the
  prelude-only / no-fallthrough caveat.
- State the D6 exposure note and the D3 fidelity disclaimer in the spec.
- **Fix now-stale "private helpers never surface" statements** (review-found):
  any comment/doc asserting private prelude helpers never appear in a discovery
  surface (e.g. discovery/eval module comments, conformance text) becomes false
  for `source` after D4. Qualify them as "never surface in
  `doc`/`meta`/`ns-publics`/`apropos`; reachable privates are
  `source`-visible."

## Test plan

TDD per repo convention — failing test first for the core behavior.

- **Parser/analyzer reachability (guards the L3-step-0 P1):** assert
  `(source crm/get-user)` actually dispatches to discovery (not an
  unbound-var/`{:symbol, "source"}` failure). Cheapest form: it must NOT error
  with "Undefined variable: source". This test fails today and would fail again
  if the `SourceAtoms` entry is dropped.
- **Direct Lisp source discovery** (`test/ptc_runner/lisp/prelude/discovery_test.exs`,
  reuse the `@crm_source` fixture): `(source crm/get-user)`, `(source
  'crm/get-user)`, `(source "crm/get-user")` all print the rendered defining
  form (assert it contains `(defn get-user`, the docstring, and the effective
  header `visibility: prompt`) and return `nil`. Assert the three forms are
  byte-identical (macro-like parity with #1094).
- **Author-literal metadata in the form** (D3a): use `crm/list-users` — it
  carries `{:visibility :discoverable}` on the defn — and assert the rendered
  form contains that map, distinct from the effective header. (`get-user` must
  NOT be used for this assertion; its `spec.metadata` is `%{}` — visibility is
  ns-inherited, surfaced only via the header. This was the review-found test
  error.)
- **Metadata beyond visibility** (D3a): add a fixture export with
  `{:requires ["id"]}` / a multi-key metadata map; assert key order and values
  render via `metadata_form`, not the normalized map.
- **Private addressable + reachability** (D4): add a `defn-` helper *referenced
  by a public export*; assert `(source crm/<helper>)` prints `(defn- <helper>`
  and returns `nil`, while `(doc crm/<helper>)` / `(ns-publics 'crm)` still do
  **not** surface it. Add an **unreferenced** `defn-` helper and assert
  `(source crm/<dead>)` is unavailable (the reachable-only oracle guard).
- **Constant** (D3): a `(def …)` export renders `(def name value)`, and a
  documented constant renders `(def name "doc" value)`.
- **Shadowing:** `(let [source (fn [_] :x)] (source 1))` calls the local, not
  discovery (mirrors the #1094 shadowable-forms behavior).
- **Arity error:** `(source)` / `(source a b)` raise the analyzer arity error.
- **Unavailable shape** (D2): `(source map)` and `(source missing/ns)` both
  return `nil` with a "no source available" print, do not raise, and — **with a
  configured `discovery_exec` stub** (not just no backend) — never invoke it
  (no MCP fallthrough).
- **No prelude attached:** `(source crm/get-user)` → unavailable print + nil.
- **Metadata fidelity** (D3): the rendered form (sans the leading `;;` header)
  re-parses (`Parser.parse` round-trip) and the author metadata survives.
- **Print cap** (D5): an oversized body truncates at `:max_print_length` and the
  full body arrives when the host raises the cap — mirror the existing `doc`
  cap tests in `discovery_test.exs`.
- **MCP session projection** (`mcp_server/test/.../sessions_*` projection test):
  `lisp_session_start` advertises `"source" => "(source ns/sym)"` when
  prompt-visible preludes are attached, and omits it when none are.
- **SubAgent inventory** (`test/ptc_runner/sub_agent/system_prompt_test.exs` or
  equivalent): the `source` hint line appears when `runtime_prelude` is
  attached, absent otherwise.

## Explicitly deferred

- **Builtin / core / Java-interop source** (`(source map)` returning real
  source). V1 returns unavailable; a later issue can add it.
- **Upstream/MCP tool source.** Out of scope (D2).
- **Verbatim source with comments / original formatting** (option 3: parser
  source spans). Gate this investment on observed `source` call rates — if the
  normalized rendering (D3) drives repair, spans are unnecessary; if `source`
  goes unused, the fix is not more fidelity.
- **Transitive private expansion** (D4) — one ref per call by design.

## Open questions

1. **Adoption instrumentation.** `source` earns its place only if the model
   calls it during repair. Worth a counter (turn-log / catalog-op style) on
   `source` invocations + whether reaching privates correlates with repair
   success, to decide the option-3 (spans) investment. Tie into the existing
   prelude smoke/ablation work.
2. **Representative export for the projection hint (L5).** First prompt export
   is simple but arbitrary. Acceptable for a *hint*; the model uses
   `ns-publics` for the full list. Confirm no better signal (e.g. a
   namespace-level `:source_example` metadata key) is worth it.
3. **`source_index` for `:discoverable` vs `:prompt` exports.** Plan includes
   both public visibility classes plus reachable privates. Confirm
   `:discoverable` exports should be `source`-visible (they are
   `doc`/`meta`-visible today, so yes — but state it).

## Review log

### Codex round 1 (plan review, pre-implementation)

Four [P1] corrections, all verified against source and folded in:

1. **`SourceAtoms` registration missing** → without `source` in the bounded atom
   table (`source_atoms.ex:105`) the analyzer clause is unreachable. Added as
   L3 step 0 + a reachability test.
2. **Metadata is normalized, not renderable AST** → `Formatter` can't format
   `spec.metadata`. Switched D3 to retain a raw `metadata_form` on `%Spec{}`
   (also fixes key-order fidelity).
3. **Test/example asserted `:visibility` on `get-user`**, which has empty
   defn metadata (ns-inherited). Reconciled via the labeled effective-metadata
   header (D3b); moved the author-literal-metadata assertion to `list-users`.
4. **Private-ref oracle** → indexing all privates leaks names by probing.
   Restricted `source_index` to public exports ∪ transitively-reachable privates
   (D4), preserving "discoverable only by reading a body."

[P2]s folded in: tightened D5 ("mirrors doc" = success path only; the miss path
is source's own), expanded the test plan (shadowing, arity, metadata beyond
visibility, no-fallthrough with a configured `discovery_exec`, dead-private
guard), and added L7 cleanup of stale "privates never surface" comments.

Open after round 1: the three Open Questions above (adoption instrumentation,
projection representative export, `:discoverable` source-visibility) — design
choices, not correctness gaps.

### Codex round 2 (verification)

Confirmed resolved: SourceAtoms registration, normalized-metadata rejection
(retain raw `metadata_form`), and the `get-user`/`list-users` fixture-metadata
correction. One [P1] + two [P2] folded in:

1. **[P1] D4 pointed at the wrong function.** `transitive_backing/1` builds the
   same-namespace call graph but returns only `%{requires, tool_refs}`, not
   reachable private *symbols* (`compiler.ex:649-655`). Corrected D4/L1 to
   specify a new `reachable_private_symbols/2` that lifts the existing
   `collect_refs` graph + `reachable_ids` walk (`compiler.ex:638-647,686-697`)
   and filters reachable symbols by `private?`.
2. **[P2] `metadata_form` capture is `defn`-only.** `handle_def`
   (`compiler.ex:271`) has no metadata syntax; constants are always
   `metadata_form: nil`. Scoped the claim to `handle_defn`.
3. **[P2] Private header semantics.** Privates have no `%Export{}`; header uses
   `visibility: private` + `arity` from `%Spec{}`, `effect` omitted. Specified
   in D3b/L1.

SubAgent inventory hook clarified during review: the renderer is
`PtcRunner.Lisp.Prelude.PromptInventory.render/2` (consumed by
`sub_agent/system_prompt.ex`), not ad-hoc text in `system_prompt.ex` — L6 should
target `PromptInventory`.

### Codex round 3 (verification) — clean

Verdict: **implementation-ready, no P1/P2.** Confirmed the D4 re-correction is
implementable (`collect_refs` same-namespace graph + adaptable `reachable_ids`
walk), header sourcing is consistent (both `specs` and resolved `exports` in
hand in `compile/1`), and `metadata_form`/`handle_defn`-only scoping is right.
One non-blocking note folded into D4: scope `reachable_private_symbols/2` per
namespace (key by `{namespace, symbol}`), not a global bare-symbol graph.
