# PTC-Lisp Conformance Review Implementation Plan

This plan instantiates `docs/plans/conformance-review.md` for the local
conformance-review worktree.

## Current Foundation

- Explicit case data lives under `test/support/lisp_conformance_cases/`.
- `PtcRunner.TestSupport.LispConformanceRunner` executes cases against both
  PTC-Lisp and Babashka, then classifies `:match`, `{:diverges, "DIV-*"}`,
  `{:bug, "GAP-*"}`, `:unsupported`, `:ptc_extension`, and `:unknown`.
  PTC and Babashka execution are timeout-wrapped so exploratory lazy/window
  probes cannot hang the review process indefinitely.
- `mix ptc.conformance_report --write-inventory` builds
  `conformance_inventory.json` from audit metadata and reports supported audit
  entries that still lack explicit cases, case policy counts, and documented
  `GAP-*`/`DIV-*` ids that still lack regression cases.
- `test/ptc_runner/lisp/conformance_runner_test.exs` proves the runner catches
  matches, intentional divergences, known bugs, unsupported cases, PTC errors,
  Clojure errors, and value mismatches.

## Near-Term Review Loop

1. Add or generate small deterministic cases for supported audit entries without
   coverage.
2. Run:

   ```bash
   MIX_ENV=test mix run -e 'alias PtcRunner.TestSupport.LispConformanceCases.Manual; alias PtcRunner.TestSupport.LispConformanceRunner; IO.inspect(LispConformanceRunner.run_cases(Manual.all()))'
   mix ptc.conformance_report --write-inventory
   mix test test/ptc_runner/lisp/conformance_runner_test.exs --include clojure
   ```

3. For every mismatch, classify it using the policy:
   `BUG`, `DIV`, `UNSUPPORTED`, `PTC_EXTENSION`, or `UNKNOWN`.
4. Record accepted bugs/divergences in `docs/clojure-conformance-gaps.md`.
5. Update audit metadata sources, then regenerate generated docs with
   `mix ptc.gen_docs`.

## First Findings Logged

- `GAP-S09`: `find` is registered as `clojure.core/find` but currently behaves
  like predicate-first search.
- `GAP-J01`: Java numeric parse aliases return `nil` on invalid strings instead
  of raising like Java; floating parsers also reject whitespace Java accepts.
- `GAP-J02`: fixed; `Boolean/parseBoolean` now returns Java-compatible boolean
  results for nil/null and string inputs and raises on non-string, non-nil
  inputs.
- `GAP-J03`: `java.util.Date.` numeric constructor treats epoch milliseconds as
  seconds, including negative epoch values.
- `GAP-J04`: `.getTime` is exposed as `java.time.Instant` compatibility even
  though Java `Instant` uses `toEpochMilli`.
- `GAP-J05`: Java string overload probes found missing `startsWith` offset,
  `lastIndexOf` from-index, and integer character-code overloads for
  `indexOf`/`lastIndexOf`.
- `GAP-J06`: Java temporal probes found `Instant/parse`, `LocalDate/parse`,
  and `java.util.Date.` accepting date/date-time strings that the Java oracle
  rejects.
- `GAP-J07` and `GAP-J08`: Java Math probes found `Math/min`/`Math/max`
  accepting variadic arguments and `Math/round` edge semantics differing for
  negative halves, NaN, and infinity saturation.
- `GAP-J10`: Java Math probes found generic numeric behavior leaking into
  Java-shaped calls: `Math/abs` does not preserve `Long/MIN_VALUE` overflow,
  mixed `Math/min`/`Math/max` overloads are accepted, and integer
  `Math/round` is accepted despite no Java long overload.
- `DIV-37`: Clojure core numeric probes confirmed `quot` follows PTC-Lisp's
  arbitrary-precision integer model instead of the JVM `Long/MIN_VALUE`
  overflow edge.
- `GAP-S30`: `clojure.set/intersection` probes expanded the existing finite
  seqable-input gap beyond maps/nil to vector arguments in both first and later
  positions.
- `GAP-S65`: `format` probes expanded the existing width/padding gap to
  combined float width+precision padding and sign flags (`%+d`, `% d`).
- `GAP-S82`: regex probes found `re-seq` no-match returns `[]` where Clojure
  returns `nil`.
- `DIV-22` and `DIV-36`: `subs` probes added regression cases for clamped end
  indexes, reversed ranges, and grapheme-based substring offsets.
- Runner hardening: direct Java temporal objects from Babashka render as
  `#object[...]`; normalization now extracts their stable ISO value so direct
  `LocalDate` return cases can be compared.
- `GAP-S83`: map/vector boundary probes found `update` cannot append at a
  vector's count index even though Clojure's `update` follows `assoc`
  semantics and PTC-Lisp already supports vector append through `assoc`.
- `GAP-S48`: sequence boundary probes expanded `butlast` coverage to empty and
  singleton inputs, which should return `nil` in Clojure but currently return
  `[]`.
- `DIV-25`: stack-helper probes added `peek` on `(list ...)` to the intentional
  list-as-vector divergence coverage.
- `GAP-S84`: predicate probes found `seq?` returns true for vectors, while
  Clojure only returns true for seq values.
- `DIV-25`: predicate probes also added `vector?` on `(list ...)` coverage for
  the intentional list-as-vector model.
- `GAP-S11`, `GAP-S32`, and `GAP-S48`: string sequence boundary probes
  expanded existing cases for `nth` default arity, negative `take-last`, and
  empty/singleton `butlast` on strings.
- `GAP-J01`: Java numeric parser probes expanded the existing Java-shaped parse
  gap to integer range checks for `Integer/parseInt` and `Long/parseLong`.
- `GAP-S85`: Clojure `parse-long` probes found out-of-range long values return
  arbitrary-precision integers instead of Clojure's nil parse-failure signal.
- `GAP-J05`: Java string overload probes expanded coverage for `startsWith`
  offset boundary values plus integer character-code/from-index overloads on
  `indexOf` and `lastIndexOf`.
- `GAP-J03` and `GAP-J04`: Java time probes expanded Date millisecond-vs-second
  constructor coverage and Instant `.getTime` convenience leakage to
  fractional-second instants.
- `GAP-J11`: `java.util.Date.` probes found a Java-accepted legacy date string
  that PTC-Lisp rejects while the constructor is still marked supported.
- `GAP-S25`, `GAP-S27`, and `GAP-S80`: `clojure.string` probes expanded split
  limit coverage, replacement-function group handling, and negative
  `last-index-of` behavior for empty search strings.
- `GAP-S86` and `GAP-S87`: binding probes found unsupported `:syms` map
  destructuring and rejected string inputs for vector destructuring in both
  `let` and `fn` parameters.
- `DIV-13`: namespaced keyword probes expanded the intentional data-model
  divergence to `:keys` destructuring with namespaced keyword literals.
- `GAP-S33` and `GAP-S88`: invocation/protocol probes expanded final string
  `apply` coverage and found `empty` returns errors or `{}` for non-collection
  values where Clojure returns `nil`.
- `GAP-S65` and `GAP-S89`: regex/format probes expanded zero-padded hex
  formatting coverage and found supported `format` rejects boolean and newline
  conversions from Java Formatter.
- Runner hardening: Clojure EDN result parsing now preserves sets with nested
  collection values, closing a false-positive class for `#{[... ]}` and map
  entry sets.
- `DIV-26`: stack/slice boundary probes expanded collection boundary coverage
  to negative `subvec` start indexes, which PTC-Lisp clamps as a recoverable
  signal value instead of raising.
- `GAP-S71`: predicate-combinator probes expanded higher-order callable
  coverage to set predicates inside `every-pred` and `some-fn`.
- `DIV-29`: sequence accessor probes expanded direct map positional-operation
  coverage from `first`/`rest` to `second`, `last`, and `next`.
- `DIV-38`: map view probes documented that `seq`, `keys`, and `vals` expose
  deterministic sorted-key views rather than Clojure's map iteration order.
- `GAP-S71` and `GAP-S91`: `clojure.walk` probes expanded map/set callable
  coverage and found `walk` accepts invalid transformed map-entry shapes where
  Clojure raises.
- `GAP-S92` and `GAP-S93`: regex probes found optional unmatched capture groups
  are collapsed instead of represented as nil slots, and `str` leaks regex
  internals instead of returning the pattern text.
- `GAP-S47` and `DIV-37`: numeric probes expanded tied `max-key` coverage and
  arbitrary-precision integer overflow coverage to core `abs`.
- `GAP-J04` and `GAP-J12`: Java temporal probes expanded Instant `.getTime`
  leakage coverage and found LocalDate day arithmetic rejects floating numeric
  arguments that Clojure's Java interop coerces for `long` parameters.
- `GAP-S12`, `GAP-S23`, `GAP-S83`, and `GAP-S90`: map-helper probes expanded
  string `get-in`, string `select-keys` keyseq, and vector append `update-in`
  coverage, and found `merge` rejects vector targets Clojure can conjoin into.
- `GAP-S49` and `GAP-S79`: sequence-helper probes expanded `mapcat` nil-result
  coverage and found `split-at` rejects whole-number float counts accepted by
  Clojure.
- `DIV-31`: predicate/coercion probes expanded numeric predicate divergence
  coverage for string inputs to `infinite?` and `NaN?`; nearby predicate arity
  and scalar checks matched or were intentionally out of scope.
- `GAP-S10` through `GAP-S14`: edge-case mismatches around `nth`, `get`,
  vector callability, and `contains? nil`.
- `GAP-S15`: `clojure.string/split` keeps an extra trailing empty element for
  empty-regex splits.
- `GAP-S16` and `GAP-S17`: `clojure.core/replace` sequence form is missing,
  and `key`/`val` accept plain vectors where Clojure requires map entries.
- `GAP-S18`: `doseq` runs the body, but `def` side effects inside the body do
  not update the outer var.
- `GAP-S19` through `GAP-S21`: boundary probes found nil-root map helpers that
  raise, nil-as-empty seq helpers that raise, and empty `reduce` without init
  returning `nil` instead of using the reducing function identity.
- `GAP-S22` through `GAP-S24`: follow-up map boundary probes found `get-in`
  default conflation for present nil values, `select-keys` nil keyseq errors,
  and `update-keys`/`update-vals` returning nil for nil maps.
- `GAP-S25` through `GAP-S27`: string boundary probes found missing
  3-arity `clojure.string/split`, `join` nil handling, and replacement
  function support in `clojure.string/replace`. Later string probes expanded
  `GAP-S26` with nil separators and string collections.
- `GAP-S50` and `GAP-S51`: string boundary probes found NBSP whitespace
  semantics mismatches in `blank?`/`trim*` and `split-lines` empty-string
  handling.
- `GAP-S52`: bitwise boundary probes found negative shift/test indexes
  rejected even though Clojure/JVM defines finite behavior for them.
- `GAP-S53`: timeout-safe window probes found `(partition -1 xs)` raising
  even though Clojure returns an empty sequence.
- `GAP-S54` and `GAP-S55`: map boundary probes found zero-map `merge` /
  `merge-with` returning `{}` instead of `nil`, and empty-path `update-in`
  dropping Clojure's nil-key update.
- `GAP-S56` and `GAP-S57`: sequence boundary probes found `empty` returning
  `""` for strings instead of `nil`, and `concat` rejecting string inputs
  despite adjacent helpers treating strings as seqable.
- `GAP-S58`: higher-order helper probes found `juxt` result functions only
  accepting one call argument instead of forwarding all arguments.
- `GAP-S59` and `GAP-S60`: collection helper probes found `reduce-kv`
  rejecting vectors and `interpose` rejecting string inputs.
- `GAP-S61` and `GAP-S62`: numeric coercion probes found `parse-double`
  rejecting whitespace Clojure accepts and `int` raising on NaN instead of
  returning zero.
- `GAP-S63` and `GAP-S64`: callable/predicate probes found keyword invocation
  matching string-keyed map entries and zero-arity `distinct?` returning true
  instead of raising.
- `GAP-S65` and `GAP-S66`: string/regex helper probes found `format`
  ignoring width/padding flags and `re-pattern` rejecting already-compiled
  regex patterns.
- `GAP-S67`: finite sequence helper probes found `group-by` rejecting string
  inputs even though adjacent helpers treat strings as seqable.
- `GAP-S68`: map boundary probes found `assoc-in` with an empty path replacing
  the whole map instead of updating the nil key.
- `GAP-S69`: numeric boundary probes found floating division by zero returning
  infinity even though Clojure raises.
- `GAP-S70`: predicate probes found `counted?`, `indexed?`, and `reversible?`
  returning true for strings even though Clojure returns false.
- `GAP-S71`: higher-order helper probes found map callables rejected in
  `map`, `filter`, `some`, `keep`, `every?`, and `not-any?` function
  positions; later walk probes expanded this to `clojure.walk/walk`,
  `prewalk`, and `postwalk` transform functions, and combinator probes expanded
  it to `comp`, `partial`, `complement`, `every-pred`, `some-fn`, and `fnil`.
  Later sequence probes expanded it again to `partition-by`, `map-indexed`, and
  `keep-indexed`.
- `GAP-S72`: control-form probes found `case` accepting duplicate constants
  and rejecting vector constants.
- `GAP-S73` and `GAP-S74`: string probes found regex replacement strings do
  not honor capture-group references or malformed dollar errors, and
  `clojure.string/split` accepts plain string delimiters that Clojure rejects.
- `GAP-S75`: map-transform probes found `update-keys` and `update-vals`
  rejecting vector inputs; the same probe expanded `GAP-S71` to cover map
  callables in `update-keys`/`update-vals` transform position.
- `GAP-S76`: collection-construction probes found `conj` rejecting map
  sources when conjoining into a map. The same probe expanded `GAP-S41` for
  `into nil` and `DIV-25` for `(conj nil ...)` vector-first semantics.
- `GAP-S77`: traversal probes found `tree-seq` over a string root recursing
  until heap limit instead of terminating over characters.
- `GAP-S78`: identifier/coercion probes found `keyword` raising on non-string
  non-keyword inputs even though Clojure returns nil.
- `GAP-S79`: index/count boundary probes found `subs`, `nth`, `take`, and
  `drop` rejecting floating numeric arguments that Clojure coerces to Java ints.
- `GAP-S80`: string index probes found `clojure.string/last-index-of` returning
  `0` for a negative from-index where Clojure returns nil.
- `GAP-S81`: flatten boundary probes found scalar, string, and map roots raising
  instead of returning an empty sequence.
- `GAP-S28` and `GAP-S29`: numeric boundary probes found zero-arity `-`
  returning `0` instead of raising and unary `/` returning its argument instead
  of the reciprocal.
- `GAP-S30`: set boundary probes found `set` and `clojure.set/*` rejecting nil
  or seqable inputs accepted by Clojure; later set probes expanded this with
  `clojure.set/union` on a vector input, plus map-entry behavior in
  `clojure.set/union` and `clojure.set/intersection`.
- `GAP-S31` and `GAP-S32`: partition/window boundary probes found nil padding
  in `partition` raising, plus negative counts in `take`, `drop`, and
  `take-last` returning non-Clojure slices.
- `GAP-S20` expanded with `interleave` nil inputs, which should stop at the
  empty seq instead of raising; later nil-as-empty probes added `flatten`,
  `distinct`, `reverse`, and `sort`.
- `GAP-S33`: `apply` rejects a nil final argument sequence instead of treating
  it as empty; later apply probes expanded this to string final arguments.
- `GAP-S34` through `GAP-S36`: callable/lookup boundary probes found missing
  2-arity `keyword`, `contains?` string indexes, and `get` on sets.
- `GAP-S37` and `GAP-S38`: control-flow probes found `case` no-match/no-default
  returning nil and `condp` missing the `:>>` result-function form.
- `GAP-S39` through `GAP-S41`: binding/constructor probes found missing vector
  destructuring `:as`, including function params and rest-plus-`:as`, `vec nil`
  returning nil, and `into` rejecting string sources.
- `GAP-S42` and `GAP-S43`: map/update probes found `fnil` missing the
  two-/three-default forms and `select-keys` rejecting vector indexes.
- `GAP-S44`: predicate probes found `char?` returning true for one-character
  strings.
- `GAP-S45`: finite sequence-generator probes found zero-step `range` returning
  an empty vector instead of repeating the start under bounded `take`.
- `GAP-S46` and `GAP-S47`: sorting/key probes found nil comparator handling in
  `sort` and tie behavior in `min-key` differing from Clojure.
- `GAP-S48`: collection boundary probes found `last`, `butlast`, `ffirst`, and
  `nfirst` mishandling nil input.
- `GAP-S49`: mapcat probes found missing multi-collection support and string
  result concatenation.
- `DIV-15` expanded to cover both multi-arity `fn` and `defn`.
- `DIV-14` expanded to cover destructuring rejection in `when-let`,
  `if-some`, and `when-some`, not just `if-let`.
- `DIV-26`, `DIV-27`, and `DIV-28`: intentional collection boundary,
  membership, and PTC type-keyword semantics needed explicit regression cases
  and documentation.
- `DIV-29`: direct positional sequence operations reject maps; callers should
  use `seq`, `entries`, `keys`, or `vals` when they want an ordered map view.
- `DIV-30`: ordering comparisons, `compare`, `sort`, and related helpers use
  PTC's recoverable total term ordering for nil, maps, and mixed data.
- `DIV-31` through `DIV-33`: numeric predicate, equality, and NaN comparison
  policies needed explicit regression cases. Later probes expanded `DIV-31`
  to cover `infinite?` and `NaN?` nil inputs and added missing audit metadata
  for `NaN?`.
- `DIV-20` documentation needed tightening: BigDecimal and ratio literals are
  unsupported, so positive Clojure examples cannot execute in PTC-Lisp.
- `DIV-13` gained runtime keyword-coercion coverage for namespaced keyword
  strings, and `DIV-34` records the PTC data-model divergence for empty keyword
  names.
- `DIV-35` records the stricter PTC keyword character set for runtime
  `keyword` coercion.
- `DIV-36` records PTC-Lisp's intentional grapheme-based string indexing for
  Clojure-named string and sequence helpers.
- `GAP-J09`: Java string probes found `.length`, `.substring`, `.indexOf`, and
  `.lastIndexOf` using grapheme indexes for non-BMP characters instead of Java
  UTF-16 code-unit indexes.
- Historical fixed gaps and older design divergences now have explicit
  regression coverage through `regression_ids`; the report currently shows
  `130/130` documented `GAP-*`/`DIV-*` ids with cases.
- Pure-candidate sweeps added explicit unsupported cases for Clojure and Java
  audit candidates; the report currently shows `62/62` candidate entries with
  cases.
- Predicate probes confirmed `list?` is intentionally unavailable with no list
  runtime type, expanding `DIV-25` with explicit regression cases for both list
  aliases and vectors.
- Associative boundary probes expanded existing `GAP-S09`, `GAP-S35`, and
  `DIV-27` coverage for `find` missing/out-of-range keys, `contains?` string
  bounds, and vector membership-versus-index semantics.
- Indexed access probes found `GAP-S94`: `nth` rejects nil input where Clojure
  returns nil, and expanded `GAP-S11` coverage for nil and negative-index
  default arities.
- Associative builder probes mostly matched but expanded `GAP-S68` for
  `assoc-in` empty paths on empty maps and `GAP-S83` for `update-in` appending
  into an empty vector.
- String split probes found `GAP-S95`: two-arity `clojure.string/split` keeps
  trailing empty fields and returns an empty vector for empty input, where
  Clojure drops trailing empty fields and returns `[""]` for empty input.
- Set helper probes expanded `GAP-S30` with later-position nil operands for
  `clojure.set/union`, `intersection`, and `difference`.
- Java parse probes expanded `GAP-J01` with empty-string `Double/parseDouble`
  and `Float/parseFloat`, where Java raises but PTC-Lisp returns nil.
- Integer and Long parse probes expanded `GAP-J01` with empty-string and
  leading-whitespace inputs, where Java raises `NumberFormatException` but
  PTC-Lisp returns nil.
- Java string overload probes expanded `GAP-J05` with empty-prefix
  `startsWith` and empty-substring `lastIndexOf` from-index boundary cases.
- Java date probes expanded `GAP-J03` with the `java.util.Date.` `-1`
  millisecond constructor case, which PTC-Lisp currently scales to seconds.
- Java time probes expanded `GAP-J06` with non-midnight no-zone date-time
  parser inputs and `GAP-J12` with fractional `LocalDate` day counts.
- Format probes found `GAP-S96`: `format` rejects several Java Formatter
  conversions and explicit argument indexes, including `%S`, `%,d`, `%X`, `%g`,
  `%c`, and `%2$s`.
- Map-entry probes expanded `GAP-S09` with `find` cases for present nil map
  values, present nil vector values, and negative vector indexes.
- Collection constructor probes expanded `GAP-S30` with `(set {:a 1})`, where
  Clojure treats maps as seqable entries but PTC-Lisp raises.
- Numeric bit helper probes expanded `GAP-S52` with negative-index `bit-set`,
  `bit-clear`, and `bit-flip`.
- Predicate/order probes expanded `DIV-30` for mixed scalar `compare` and
  nonnumeric `min`/`max`/`min-key`/`max-key`, and expanded `DIV-32` for `not=`
  on int/float numeric equality.
- String boundary probes expanded `DIV-22` with `(subs "abc" 4 4)`, where
  both start and end are beyond length and PTC-Lisp returns the empty-string
  signal value instead of raising.

## Next High-Value Probes

- Add a small extractor for existing `assert_clojure_equivalent/1` calls so
  current tests can be represented in the explicit case format.
- Add deterministic local-doc example extraction before importing upstream test
  suites.
- Continue boundary/error probing around supported behavior and PTC
  extensions, especially nil/empty/wrong-type cases that are not yet covered by
  the deterministic suite.
