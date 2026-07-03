# Prelude Form-Keyed Edit and Dependency Introspection — Plan

## Status

Approved and **implemented** 2026-07-03 (Phases 1, 2, and 3 all shipped;
see the commits introducing `form_graph`, the introspection tools,
`FormScanner`, and `FormEdit`/`PreludeStore.edit`). Review sharpenings
incorporated: `prelude/form` moved behind the span scanner (no rendered
fallback), scanner test coverage is a hard gate for `prelude/edit`,
direct/transitive authority split in the dep surface, explicit-only
`add-form` placement, base version + parent checksum in the edit result.
Derived from the MCP-native prelude
self-improvement experiments (external repo `ptc-bench-comparison`,
`docs/mcp-native-prelude-self-improvement-plan.md`), whose Stage 4/5 replay
produced the motivating evidence: a naive full-source rewrite through
`(prelude/write ...)` failed structurally (the editor could not even
reconstruct a 9,294-byte source through 512-char eval previews within the
turn cap), while an in-session anchor splice succeeded with one
compile-guided retry.

## Problem

`prelude/write` accepts only a complete namespace source string. The model
authoring an edit must therefore either re-emit the whole source (proven
infeasible for real preludes) or run an in-session string splice against
`(prelude/source id)`. The splice workaround has hard ceilings:

- `prelude/source` fails closed at 64 KB (`@default_source_bytes`,
  `lib/ptc_runner/prelude_candidate.ex`), while the store accepts sources up
  to 1 MB — the workaround cannot scale to larger preludes at all.
- The splice helper is inline session code: unversioned, re-authored per
  session, and limited to substring anchors. Anchor edits carry two failure
  modes (`anchor_not_found`, `anchor_ambiguous`) that whole-form edits do not
  have.
- Out-of-region drift is only detectable post hoc (read-back diff), not
  prevented by construction.

Separately, there is no read-side introspection of a stored prelude below
whole-source granularity. A proposer cannot see reuse opportunities, a
reviewer cannot detect copy-paste growth, and an editor cannot see which
public exports a private-helper change affects.

The semantic edit unit is unambiguous: a prelude is a flat sequence of named
top-level forms, and the store compiles every candidate on write. Edits and
introspection should be keyed by top-level form name.

## Goal

1. `prelude/edit`: a store-side, form-keyed, atomically-batched edit
   operation on the authoring surface, same authority boundary as
   `prelude/write`. The model emits only deltas; the server holds the text
   and performs the splice. Untouched forms are byte-identical by
   construction.
2. Read-side form introspection on the authoring surface:
   `(prelude/forms id)`, `(prelude/form id name)`,
   `(prelude/form-deps id name)`, `(prelude/deps id)` — including private
   forms and a conservative intra-namespace dependency graph with per-form
   authority (`requires` / `tool_refs`).

## Non-goals

- **Lifting the write-capable/attach exclusion.** The cross-session
  editor/verifier split is architecturally right, not a workaround: the
  verifier runs free of editor session state, which is the contamination
  boundary the human-gated loop wants. Frozen-attach semantics would only
  let an editor smoke-test the version it attached at start — never the one
  it just wrote — so it delivers almost nothing; the real want (re-attach /
  hot-load) is a documented non-goal
  (`docs/plans/archive/live-prelude-evolution.md`). Form-level introspection
  also removes most of the reason to want same-session execution. Revisit
  only if the loop produces evidence that cross-session verification is the
  bottleneck.
- **Cross-prelude namespace dependencies** (one stored prelude's source
  calling another's namespace). Confirmed unsupported at write-time
  validation (2026-07-02 runtime check); separate track.
- **Filesystem persistence of the store.** Unchanged.

## What already exists (verified against source, 2026-07-03)

Most of the machinery this plan needs is already in the compiler — internal
and discarded, not missing.

- **Top-level name uniqueness is already enforced.** `reject_duplicate_refs`
  (`lib/ptc_runner/lisp/prelude/compiler.ex:463`) rejects duplicate names
  across both public and private definitions per namespace, and every store
  write goes through `compile_bounded`
  (`lib/ptc_runner/prelude_store.ex:302`). Every stored prelude is therefore
  already unambiguously form-keyable; Lisp last-definition-wins cannot occur
  for stored source. No new keying validation is needed — only a good error
  when a named form does not exist.
- **The intra-namespace call graph is already computed — three times per
  compile, then discarded.** `collect_refs` builds the identical
  sibling-filtered reference graph independently in `transitive_backing/1`
  (compiler.ex:651), `source_dependencies/2` (compiler.ex:1257), and
  `reachable_private_symbols/1` (compiler.ex:1373). The walker is
  scope-aware (params and `fn`/`let`/`loop`/`for`/`doseq` bindings shadow),
  skips quoted symbols and `comment` forms, and fails closed on
  unrecognized AST nodes (`leaf_or_reject`, the #1095 hardening).
- **Per-form authority is already computed.** `transitive_backing/1` yields
  `%{symbol => %{requires: [...], tool_refs: [...]}}` per namespace —
  exactly the per-form authority view `form-deps` should expose.
- **The store id `prelude` is already reserved**
  (`@reserved_store_ids`, `prelude_store.ex:33`), so the authoring-wrapper
  collision edge case is pre-guarded at write time.
- **Removal safety is already enforced.** Removing a private helper that a
  remaining form still references fails at the existing compile gate
  (`check_prelude_vars`, compiler.ex:1181, `:compile_error` with the
  undefined variable named).
- **Concurrency safety comes free.** `edit` reads the base source and
  checksum, passes the checksum as `parent_checksum`, and the store server's
  atomic recheck rejects `:stale_base` if anyone wrote in between. `edit`
  is read + splice + existing `write/4`; the store server is unchanged.

## What is genuinely new

1. **Byte spans of top-level forms in the original source.** Nothing
   provides them today: the parser tracks no source positions
   (`lib/ptc_runner/lisp/parser.ex`), and parse → swap-form → re-render via
   `Formatter` is disqualified because the reader discards comments and
   whitespace (see the fidelity disclaimer at compiler.ex:1331) — a
   re-render would reformat every untouched form, destroying the
   byte-identity guarantee that is the entire point. The implementation must
   be a raw-text top-level span scanner: depth-0 delimiter tracking that
   respects strings, comments, and every reader macro (`#(...)`, `#{...}`,
   `#"..."`, `'sym`). This is exactly the code shape that produced the
   #1095 fail-open class, so it ships only with the fail-closed cross-checks
   below.
2. **The splice + batch-edit op layer** on top of the scanner.
3. **The `prelude/` wrapper and backing-tool surface** for the four read ops
   and `edit`. Marshaling note carried over from the external plan: `edit`
   is the first private backing tool taking a list of maps (`:edits`), which
   needs explicit marshaling coverage, and arg keys must avoid hyphens (the
   tool-boundary key normalizer rewrites `-` to `_`).

## Design

### Phase 1 — extract the call graph as a first-class compile artifact

Extract the three duplicated `collect_refs`-over-siblings constructions into
one pass and store its result on `%Prelude{}` (e.g. a per-namespace
`form_graph`: for each symbol — visibility, arity, calls (sibling refs),
requires, tool_refs). `transitive_backing`, `source_dependencies`, and
`reachable_private_symbols` become consumers of the shared graph; two of the
three inline constructions are deleted. Pure refactor, no behavior change,
covered by existing compiler tests.

This is the "right abstraction" fix: the graph stops being an inline idiom
and becomes an artifact guaranteed consistent with write-time validation.

### Phase 2 — read-side introspection tools

Projections of `candidate.compiled` — no new parsing at read time.

- `(prelude/forms "id")` — one row per top-level form: name, visibility
  (`public`/`private`), kind (`function`/`constant`), arity, docstring
  (bounded), and byte size. Includes *all* forms, including unreachable
  privates.
- `(prelude/form-deps "id" "name")` — one list of sibling references with
  per-entry visibility (not the redundant
  `calls`/`private_calls`/`public_calls` triple), plus the form's authority
  split into **direct** (`requires`/`tool_refs` from the form's own body)
  and **transitive** (the closure over the sibling helpers it calls — what
  `transitive_backing` computes today). The two answer different questions:
  "what does this form itself touch" vs. "what authority does calling it
  exercise." The transitive view is the most safety-relevant part of this
  surface: it makes visible when a private-helper edit widens the transitive
  `:requires` of public exports.
- `(prelude/deps "id")` — the whole intra-namespace graph,
  `%{name => [sibling refs]}`. Edges are *direct* references only;
  transitive reachability is derivable by the reader and reported per-form
  by `form-deps`.

**`(prelude/form "id" "name")` — single form's exact source text — ships
with Phase 3, not here.** It requires the span scanner; there is no
acceptable fallback. A `Formatter`-rendered body, even clearly labeled,
would teach agents to treat non-byte-exact text as source and to build edit
anchors from it — precisely the drift class this plan exists to eliminate.
Until spans exist, `forms` + `form-deps` + `deps` (structure and authority)
plus `prelude/source` (exact text, bounded) cover inspection. When it does
ship: bounded per form, fail-closed like `prelude/source`.

**Privacy decision — two surfaces stay distinct.** The D4 reachable-only
guard on the runtime `(source ...)` discovery index is correct and stays.
The store authoring surface shows all forms including dead privates: a
write-capable session already has full source via `prelude/source`, so
there is no existence oracle to protect, and dead-private detection is one
of the review payoffs. Do not reuse `source_index` for these tools.

### Phase 3 — span scanner, `prelude/form`, and `prelude/edit`

**Scanner.** A top-level span scanner over the raw source producing, per
top-level form: name (from the head + first symbol), byte span, and the
form's leading gap (whitespace/comments between it and the previous form).
Fail-closed cross-checks, all cheap:

1. **Round-trip**: reconcatenating spans + gaps must reproduce the original
   source byte-for-byte; refuse to edit otherwise.
2. **Compiler cross-check**: the scanner's ordered form-name list must
   exactly match what `collect_specs` produces for the same source; refuse
   otherwise. Property-test this over every prelude source in the test
   corpus.
3. The existing compile gate backstops the result: a bad splice cannot be
   stored, only rejected.

With these, the worst failure mode is a loud refusal — never silent drift.

**Hard gate: `prelude/edit` (and `prelude/form`) do not ship until the
scanner test suite is green over (a) every prelude source in this repo —
`priv/prompts`, `examples/`, and the test corpus — and (b) the adversarial
reader-macro cases in the Testing section.** The runtime cross-checks above
are the safety net, not a substitute for this coverage; a scanner that
frequently trips its own refusal is not shippable either.

**Op set.**

- `replace-form name source` — works regardless of the current head
  (`defn` / `defn-` / `def`); a visibility change is an ordinary replace,
  validated by the compile gate and surfaced in the write result for human
  review. **No rename op.** A `replace-form` whose declared `name` doesn't
  match the source's derived name is rejected (`:form_name_mismatch`), not
  treated as a rename — a rename is expressed as `remove-form` +
  `add-form`, so the name a batch touches is always explicit rather than
  inferred from a before/after diff of two spans.
- `add-form source` with placement exactly one of `:before name`,
  `:after name`, or `:end` (the default). No other placement logic — no
  inference from dependencies, no "smart" ordering. Bad placement
  (define-before-use) fails loudly at the compile gate; acceptable.
- `remove-form name`.
- `set-ns-doc doc` — dedicated op for the one recurring non-form edit (the
  ns docstring); the `(ns ...)` form is not symbol-keyed like definitions.
  Concretely: the `(ns ...)` form is excluded from every name-keyed lookup
  above too (`replace-form`/`remove-form`/`add-form`'s anchor, and the
  existing-name check) — it is reachable only through `set-ns-doc`. This
  also sidesteps a real ambiguity, since the scanner derives a `name` for an
  `ns` form too (its namespace symbol), and nothing stops a `defn`/`def`
  from sharing that name (the compiler only rejects duplicate refs among
  `defn`/`def` specs, never against the ns name itself).

**Splice text rules.** `replace-form` swaps only the target's span; its
preceding gap (header comments, blank lines) is untouched. `remove-form`
removes the target's span AND its preceding gap — header comments travel
with the form they document. `add-form :before X` inserts
`"\n\n" <> new-form-text` right after whatever precedes X (i.e. before X's
own gap begins), so X's header comments stay attached to X, not to the
newly inserted form — the separator sits on the new form's LEFT edge; on
its right, X's own untouched gap provides the separation; `:after X` inserts `"\n\n" <> new-form-text`
immediately after X's span ends; `:end` appends `"\n\n" <> new-form-text`
after the last form's span, before the source's trailing gap. Untouched
forms are byte-identical by construction — their gap and span are copied
verbatim. Only the single top-level form's own span from a
`replace-form`/`add-form` source is spliced in; any leading/trailing gap in
that source itself (e.g. a comment the caller put before the form) is
discarded.

**Batch semantics.** Ops are accepted as one atomic batch producing one
version bump. Every op resolves its span against the *base* version; the
splice happens once. Reject conflicting batches: two ops targeting the same
form, or `add-form` anchored to a form removed in the same batch.
Deterministic, and it sidesteps the sequential-vs-original ambiguity
entirely. Editing a non-current base is rejected as `:stale_base` by the
existing parent-checksum path — edit-and-fork is not supported.

**Result shape.** Same as `prelude/write` (id, version, checksum) plus:

- the **base version and parent checksum the edit was applied against** —
  an audit log must connect edit intent to the exact base without a store
  round-trip, and the response is the natural place to bind them;
- which forms were replaced/added/removed;
- a public-surface diff computed from the two compiled `%Prelude{}` structs'
  `form_graph` — every form (public AND private), not `exports` alone: a
  private definition has no `Export` record at all, so diffing `exports`
  only would make a `defn` -> `defn-` visibility flip silently vanish
  instead of surfacing as a change. `effect` (read/write/unknown) is looked
  up from the matching compiled export when a name is currently public, and
  is absent for a private name. The compared per-form view also carries the
  form's transitive `requires`/`tool_refs` (codex review finding,
  2026-07-03): an authority-only edit — swapping a helper's `tool/call`
  target while visibility/kind/arity/effect all stay equal — must land in
  `changed`, not report an empty diff.

## Files to change

- `lib/ptc_runner/lisp/prelude/compiler.ex` — Phase 1 extraction; store the
  graph on `%Prelude{}` (`lib/ptc_runner/lisp/prelude.ex`).
- New module for the span scanner (e.g.
  `lib/ptc_runner/lisp/prelude/form_index.ex` or similar) — Phase 3.
- `lib/ptc_runner/prelude_store.ex` — public `edit/4` delegating to
  `write/4` after the splice.
- `lib/ptc_runner/prelude_store/tools.ex` — new wrapper fns in
  `@prelude_source`, new reserved backing tool names
  (`prelude_store_forms`, `prelude_store_form_deps`, `prelude_store_form`,
  `prelude_store_deps`, `prelude_store_edit`), marshaling for the `:edits`
  list-of-maps arg.
- Tests: `test/ptc_runner/prelude_store_test.exs`,
  `test/ptc_runner/prelude_store_tools_test.exs` (both already cover the
  write path incl. stale-parent and concurrent writes), new scanner
  property tests, compiler tests for the extracted graph.

## Testing

- Scanner property test over the prelude test corpus: round-trip
  byte-identity and form-name agreement with `collect_specs`.
- Reader-macro adversarial cases: forms containing `#(...)`, `#{...}`,
  `#"..."`, quoted symbols, strings containing `(defn `, comments containing
  unbalanced parens, and `;;`-comments between top-level forms.
- Edit-path integration: replace/add/remove batches, visibility flip
  surfaced in the result, conflicting batch rejected, `:stale_base` on
  concurrent write, removal of a still-referenced private rejected by the
  compile gate with the undefined name.
- Introspection: dead private visible in `prelude/forms`/`deps` (authoring
  surface) while still absent from the runtime `(source ...)` index (D4
  unchanged).

## Sequencing note

The external plan flagged a tension: `prelude/edit` is precisely the
engineering request the self-improvement loop was expected to produce from
its own write-failure evidence. That question is now answered — the Stage
4/5 replay *was* the evidence gathering (naive rewrite failed structurally;
splice passed with caveats; the 64 KB `prelude/source` cap makes the
in-session pattern a dead end for larger preludes). Building it now is
justified; the loop's first self-improvement target moves elsewhere, and the
external plan records that move.

Build order within this repo: Phase 1 (pure refactor, deletes duplication),
then Phase 2 (structure and authority introspection — no new risk, useful
to proposers and reviewers before edit lands), then Phase 3 (scanner, then
`prelude/form` and `prelude/edit` together behind the scanner-coverage
gate).
