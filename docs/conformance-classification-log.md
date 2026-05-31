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
