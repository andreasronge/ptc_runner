# Decision note: reclassify char-literal GAPs as DIV

**Status:** agreed, not yet applied
**Date:** 2026-05-29
**Affects:** `GAP-S120`, `GAP-S130` in [clojure-conformance-gaps.md](../clojure-conformance-gaps.md); ~37 manual conformance cases; spec [§3.5](../ptc-lisp-specification.md)

## Decision

`GAP-S120` and `GAP-S130` are **misclassified as bugs**. They should be **intentional
divergences (`DIV-*`)**, coupled to `DIV-36`.

- `GAP-S120` — character literals compare equal to one-character strings (`(= \a "a") => true`)
- `GAP-S130` — sequence helpers treat character literals as strings (`(count \a) => 1`, etc.)

## Why this is DIV, not BUG

PTC-Lisp has **no distinct character type**. A character literal `\a` evaluates to the
single-character string `"a"`. This is not an accident — it is *forced* by the earlier,
documented decision (`DIV-36`, spec §3.3) that strings seq into single-character **strings**,
not chars. The two are one coherent design; you cannot reclassify one without the other.

### Empirical coupling (verified against the interpreter)

```clojure
(seq "ab")                              ; => ["a" "b"]   ; string elements are strings
(first "raspberry")                     ; => "r"
\r                                      ; => "r"          ; char literal = same single-char string
(= \r (first "raspberry"))              ; => true         ; works ONLY because both are "r"
(filter #(= \r %) "raspberry")          ; => ["r" "r" "r"]
(count (filter #(= \e %) "hello"))      ; => 1            ; this IS the spec §3.5 example
(filter #(contains? #{\a \e \i \o \u} %) "hello")  ; => ["e" "o"]
```

If `\a` became a true scalar **in isolation** (strings still seq to single-char strings),
every line above would silently return `[]` / `0` / wrong results — **P0 silent-wrong-answer
bugs**, including the spec's own §3.5 examples. Making `\a` a true scalar *correctly* would
require also changing strings to seq into real chars, i.e. overturning `DIV-36` and the entire
string-as-sequence model — a large breaking redesign, not a bug fix.

### Alignment with stated design philosophy (spec §1)

- **Design goal #1 (LLM-friendly):** current behavior makes the common char idiom
  (`#(= \r %)` over a string) work; the "fix" would silently break it.
- **Philosophy rule #1 (no try/catch → signal, don't raise):** `GAP-S130` wants
  `(count \a)` to *raise* like Clojure; with no recovery path that is an unrecoverable
  crash — the opposite of the stated direction.
- **Coherence with `DIV-36`:** the grapheme/string-element behavior is already filed
  "by design," but its inseparable twin (char literals) was filed as 37 bugs. Same
  decision, two verdicts.

### LLM-expectation angle

A Clojure-trained model expects `\a` ≠ `"a"`, so current PTC behavior *does* surprise that
prior — but **harmlessly**: models rarely compare a char literal to a string expecting
`false`; they use char literals against characters pulled from strings, which are single-char
strings, so it "just works." Making `\a` scalar would instead surprise the *self-consistency*
prior **harmfully**, producing a value that prints like `"a"` but isn't `=` to it (a footgun)
plus a second look-alike scalar type. Harmless-surprise beats harmful-surprise for
no-try/catch, LLM-generated code.

## Out of scope

`GAP-S122` (`float ##Inf`) and `GAP-S127` (`double?`/`float?` on special float literals) are a
*separate* concern — numeric range/predicates, not the char model — and remain defensible as
real bugs. Do **not** fold them into this change.

## Proposed mechanical change (when applied)

1. Add one new `DIV-*` entry ("character literals are single-character strings"), cross-linked
   to `DIV-36`, replacing `GAP-S120` and `GAP-S130`.
2. Flip the ~37 affected manual cases from `{:bug, "GAP-S120"|"GAP-S130"}` to
   `{:diverges, "DIV-*"}` with `ptc_expected` set to the current PTC value (the runner already
   asserts the PTC value for divergences).
3. Add a one-line DIV cross-link in spec §3.5 (the behavior is already documented there as a
   feature; it just needs to point at the DIV entry).
4. Regenerate audit docs (`mix ptc.gen_docs`) and refresh the coverage report
   (`mix ptc.conformance_report --write-inventory`).
