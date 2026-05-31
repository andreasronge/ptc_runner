# Conformance Fix Classification Log

Per-GAP classification notes, written **before coding** each gap (see the
workflow in the agent goal / `docs/clojure-conformance-gaps.md`). One entry per
gap, in the prescribed format:

- **GAP id**
- **Classification:** BUG / DIV / UNSUPPORTED / UNKNOWN
- **Work size:** A / B / C / D
- **Spec basis:** cite `docs/ptc-lisp-specification.md` policy
- **Risk:** local / shared / refactor
- **Codex review needed:** yes / no

New gaps: add the note here *before* the implementation edit. This file is the
single source of truth so notes don't get lost in conversation transcripts.

---

## GAP-S134 + GAP-S20(freq) — direct-map-as-collection consistency rule  ·  committed

- **Classification:** BUG (both) — `distinct` BUG (too lenient), `frequencies`
  BUG (too strict); each already filed in opposite directions.
- **Work size:** A/B
- **Spec basis:** Codex consult on the most consistent rule for LLM use settled
  on: *a direct map is data, not an implicit ordered sequence — order-INSENSITIVE
  consumers accept it; ops whose result exposes/depends on traversal order
  reject it and require an explicit ordered view (`seq`/`entries`/`keys`/`vals`)*.
  Applied to the two ops the team already flagged: `frequencies` (counts →
  order-insensitive) now **accepts** maps like `count` + Clojure (GAP-S20);
  `distinct` (result order exposes traversal) now **rejects** maps like
  Clojure + DIV-29 (GAP-S134).
- **Decision boundary:** declined codex's *broader* version (rejecting
  `map`/`filter`/`reduce`/`take`/`drop` on maps). Those are whole-collection ops
  Clojure accepts, DIV-29 scopes itself to *positional* ops, PTC traversal is
  deterministic, and rejecting them would break the core LLM idiom for no real
  safety gain. The single-element positional ops (`first`/`last`/`nth`/`reverse`/
  `interpose`/`interleave`) already reject via DIV-29.
- **Risk:** local (one clause added to `frequencies`, one removed from
  `distinct`; `:distinct` added to the unordered-map type-error message).
- **Codex review:** pending.

## GAP-S102 — multi-collection `map`/`mapv` accept strings/maps (align with pmap)  ·  committed

- **Classification:** BUG
- **Work size:** A/B
- **Spec basis:** Clojure-compat default — strings/maps are seqable. `map/2`
  already coerces them and `pmap` (GAP-S132) does too, but `map/3`/`map/4`
  guarded `is_list`/`is_binary` per collection, so mixed string+list or a map
  collection raised. Coerce each collection via `Normalize.to_seq` + `zip_with`,
  matching `map/2` and `pmap`. Resolves the pmap-vs-map seqable inconsistency.
- **Risk:** local (map/3, map/4; mapv delegates). nil short-circuit preserved;
  non-seqables still raise → type_error via the :multi_arity dispatch. The 4+
  collection arity cap is unchanged (separate registration concern).
- **Codex review:** pending.

## GAP-S20 — nil-tolerant seq helpers (take/drop/flatten/distinct/reverse/sort/frequencies)  ·  committed

- **Classification:** BUG
- **Work size:** B
- **Spec basis:** Clojure-compat default — `nil` is an empty seq (rule 4:
  input-data property, not program shape). The adjacent helpers
  `map`/`filter`/`dedupe`/`sort-by`/`group-by` already treat `nil` as empty, so
  these were inconsistently strict. Added `nil` clauses (`[]`, or `{}` for
  `frequencies`).
- **Risk:** local (one `nil` clause per function; no shared-path change). The
  `frequencies`/`distinct` direct-*map* sub-cases are a separate map-seqable
  question (GAP-S134), left open.
- **Codex review:** pending.

## GAP-S98 — `interleave` accepts strings / nil (twin of GAP-S60)  ·  committed

- **Classification:** BUG
- **Work size:** A/B
- **Spec basis:** Clojure-compat default — strings are seqable and `nil` is an
  empty seq (same basis as GAP-S60 `interpose` and GAP-S20). The earlier
  GAP-S143 fix deliberately kept a `{:rest, :list}` arg-spec that left this open;
  this removes it and coerces args via `interleave_seq` (list → itself, string →
  graphemes, `nil` → `[]`). Direct maps/sets still raise → DIV-29, matching
  `interpose`. Resolves the interpose/interleave twin inconsistency.
- **Risk:** local (one function + arg-spec removal; deleted the now-unused
  `:list` arg type). Also closes the `interleave` sub-cases of GAP-S20.
- **Codex review:** pending.

## GAP-S132 follow-up — `pmap` keyword over multiple collections  ·  committed

- **Classification:** BUG (regression surfaced by the GAP-S132 multi-collection
  work)
- **Work size:** A
- **Spec basis:** Clojure-compat default — a keyword is a 2-arg IFn
  (`(:k m default)`), and `map` already honors this. The GAP-S132 multi-coll
  path pre-converted the keyword via `value_to_erlang_fn` into a strict arity-1
  closure, so `(pmap :k maps defaults)` crashed with a `:pmap_error`. Keep the
  keyword un-converted so `Callable.call` dispatches arity 1 and 2.
- **Risk:** local (one `pmap` callable branch; single-map guard preserved).
- **Codex review:** pending.

## GAP-S10 — negative `nth` index returns nil (reclassified DIV-26)  ·  committed

- **Classification:** BUG → DIV (folded into DIV-26)
- **Work size:** A
- **Spec basis:** the 2-arity `nth` delegated to `Enum.at`, which reads from the
  end for a negative index and silently returns unrelated data. A negative
  index is out of range, so it now returns the `nil` signal — the existing
  DIV-26 out-of-range policy — matching positive out-of-range and the 3-arity
  default. Remaining nil-vs-raise gap is intentional DIV-26.
- **Risk:** local (two guarded 2-arity clauses; reclassified the conformance
  case `core/nth-negative-bug-001` → `core/nth-negative-div-001`).
- **Codex review:** pending.

## GAP-S146 — one-collection `merge` / `merge-with`  ·  committed

- **Classification:** BUG
- **Work size:** B
- **Spec basis:** Clojure-compat default — `(merge x)` is one-arg identity
  (returns `x` unchanged); a single falsey arg carries no map → GAP-S54
  empty-map behavior rather than raising.
- **Risk:** shared (added count-aware `:rest_min2` arg-spec shape; preserved
  GAP-S54/S90/S100).
- **Codex review:** yes — clean.

> Note: recorded retrospectively. This note was written in-session before the
> implementation; logged here after the fact when this file was created.

## GAP-S143 — variadic `interleave` (0/1/n arity)  ·  committed

- **Classification:** BUG
- **Work size:** B
- **Spec basis:** Clojure-compat default; eager/finite (rule 2); valid 0/1/n
  arities are not malformed programs (rule 4 N/A).
- **Risk:** shared (`:collect` + new `:list` arg type; kept nil/string/map
  raising so GAP-S20/S98 + direct-map DIV still reproduce).
- **Codex review:** yes — clean.

## GAP-S16 — `clojure.core/replace` seq form (P1)  ·  committed

- **Classification:** BUG
- **Work size:** B
- **Spec basis:** Clojure-compat default; `:multi_arity` arity dispatch
  (2 = core seq replace, 3 = string replace alias). Value-model precedence:
  namespace collapse and list-keys-as-get-in-paths are documented DIVs, not
  bugs.
- **Risk:** shared (hot builtin dispatch; reused `:multi_arity` like `nth`).
- **Codex review:** yes — 2 P2s declined with documented rationale.

## GAP-S60 — `interpose` accepts strings  ·  committed

- **Classification:** BUG
- **Work size:** A/B
- **Spec basis:** Clojure-compat default; strings are seqable (peers `map`,
  `filter`, `seq`, `dedupe` already treat them so). DIV-29 (direct maps/sets)
  preserved.
- **Risk:** local (one function; nil already handled).
- **Codex review:** yes — clean.

## GAP-S94 — `(nth nil idx)` returns nil  ·  committed

- **Classification:** BUG
- **Work size:** A
- **Spec basis:** recoverable nil input (rule 4 — input-data property, not
  program shape); consistent with the existing 3-arity nil clause and lenient
  out-of-range `nth`.
- **Risk:** local (one 2-arity clause).
- **Codex review:** yes — clean.

## GAP-S48 — nil-boundary seq helpers return nil  ·  committed

- **Classification:** BUG
- **Work size:** B
- **Spec basis:** Clojure nil-as-empty-seq / empty-seq punning;
  `last`/`ffirst`/`fnext`/`nfirst`/`nnext` on nil → nil, `butlast`/`take-last`
  empty result → nil. Recoverable input. GAP-S32 (negative `take-last` count)
  preserved as a separate divergence.
- **Risk:** shared (7 functions + spec-doc examples).
- **Codex review:** yes — caught a spec-doc [P1] (stale `butlast` examples) and
  2 stale tests; all fixed before commit.

---

## GAP-S23 — `select-keys` with nil / string keyseq  ·  committed (+ DIV-46)

- **Classification:** BUG (nil sub-case) + **DIV (new DIV-46)** (string sub-case).
  Started as **work-size D** (string sub-case classification uncertain) →
  surfaced to the user, who approved "proceed", then coded.
- **Work size:** B (once the D decision is made).
- **Spec basis:**
  - Rule 1 / signal-value policy: a nil keyseq is bad *external input*; should
    return `{}`, never a raw `Protocol.Enumerable` crash → nil = BUG.
  - Value-model precedence: PTC has no char type (char ≡ one-char-string) and
    stores keyword keys as strings, so a string keyseq's chars flex-match
    keyword-derived keys universally (already true for `(select-keys {:a 1}
    ["a"])` → `%{"a" => 1}`). `(select-keys {:a 1 :b 2} ":a")` → `%{"a" => 1}`,
    not Clojure's `{}` → string = DIV, not a fixable bug.
  - The `:seqable` arg-spec already admits nil/string; honoring it via the
    canonical `Normalize.to_seq/1` coercion is the in-idiom fix.
- **Risk:** shared (coercion contract of `select_keys/2`; reuses
  `Normalize.to_seq`).
- **Codex review:** yes — clean (caught and fixed a map-keyseq path-leak
  regression mid-review: maps are not routed through `to_seq`, so their entries
  stay non-matching `{k,v}` tuples).
- **Status:** committed (`03548673`). nil → `{}` (BUG fixed); string keyseq →
  DIV-46; map keyseq → `{}` (pinned by `core/select-keys-map-keyseq-001`).
