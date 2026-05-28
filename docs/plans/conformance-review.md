Objective

  Create a long-running, repeatable PTC-Lisp conformance review program that finds:

  - accidental bugs where PTC-Lisp should match Clojure/Java
  - intentional divergences required by the PTC-Lisp design policy
  - unsupported Clojure features that should remain out of scope
  - missing tests/documentation for supported behavior

  Primary docs to read first:

  - docs/ptc-lisp-specification.md, especially the overview and design philosophy
  - docs/clojure-conformance-gaps.md
  - docs/conformance/index.md
  - docs/conformance/*-audit.md

  Repository policy:

  - This is a 0.x library. Prefer simplification over compatibility shims.
  - Clojure compatibility is the default.
  - Sandbox safety and recoverable signal values take precedence.
  - Java-named dot methods should keep Java semantics.
  - Generated conformance docs must not be edited by hand.

  Core Classification Model

  Every reviewed behavior should end in one of these categories:

  MATCH
    PTC-Lisp matches Clojure/Java.

  BUG
    PTC-Lisp claims support but behavior differs accidentally.

  DIV
    PTC-Lisp differs intentionally because of the language policy.

  UNSUPPORTED
    Clojure feature is intentionally outside the PTC-Lisp target surface.

  PTC_EXTENSION
    Feature is PTC-specific and should be tested against the PTC spec, not Clojure.

  UNKNOWN
    Needs manual decision.

  For mismatches, use this decision rule:

  If it is a Clojure-named function and normal finite data input:
    default to BUG unless the spec clearly justifies DIV.

  If bad external input can reasonably be recovered from:
    DIV may be valid if PTC returns nil/false/empty/signal value.

  If the program itself is invalid:
    should raise; silent signal values are suspicious.

  If it is a Java-named method or class/member call:
    Java semantics should win, including exceptions.

  If behavior depends on laziness, unbounded execution, host state, I/O,
  macros, eval, metadata, vars, atoms, refs, agents, or JVM internals:
    likely UNSUPPORTED or DIV.

  Phase 1: Inventory And Baseline

  Read the generated audit metadata, not only the generated docs.

  Likely files:

  - priv/function_audit.exs
  - priv/java_compat_audit.exs
  - lib/mix/tasks/ptc.gen_docs.ex

  Tasks:

  1. Identify all supported, candidate, and not_relevant entries.
  2. Build or script a machine-readable inventory:
      - namespace
      - symbol/method
      - current audit status
      - compatibility target: Clojure, Java, PTC extension
      - notes
  3. Produce an initial coverage report:
      - supported functions with conformance tests
      - supported functions without conformance tests
      - documented DIV-* entries with regression tests
      - documented GAP-* entries with regression tests

  Expected output:

  conformance_inventory.json or .exs
  coverage report printed by a Mix task or test helper

  Phase 2: Conformance Case Format

  Add a small, explicit case format before importing large test sources.

  Suggested location:

  test/support/lisp_conformance_cases/

  Suggested shape:

  %{
    id: "core/get-001",
    namespace: "clojure.core",
    vars: ["get"],
    form: ~S[(get {:a 1} :a)],
    policy: :match
  }

  For intentional divergence:

  %{
    id: "core/parse-long-div-001",
    namespace: "clojure.core",
    vars: ["parse-long"],
    form: ~S[(parse-long "abc")],
    policy: {:diverges, "DIV-xx"},
    ptc_expected: nil,
    reason: "Bad external input returns a signal value instead of raising."
  }

  For unsupported behavior:

  %{
    id: "core/lazy-range-unsupported-001",
    namespace: "clojure.core",
    vars: ["range"],
    form: ~S[(take 3 (range))],
    policy: :unsupported,
    reason: "Unbounded lazy sequences are outside PTC-Lisp."
  }

  Fields to support:

  id
  namespace
  vars
  form
  policy
  source
  reason
  ptc_expected
  clojure_expected
  tags

  Tags can include:

  :smoke
  :edge
  :error_semantics
  :destructuring
  :truthiness
  :ordering
  :numeric
  :string
  :collection
  :java
  :ptc_extension

  Phase 3: Oracle Runner

  Build a conformance runner that executes cases against both PTC-Lisp and Babashka/Clojure.

  Existing implementation to inspect:

  lib/ptc_runner/lisp/clojure_validator.ex
  test/ptc_runner/lisp/sci_conformance_test.exs

  Runner responsibilities:

  1. Run PTC-Lisp form.
  2. Run Babashka form.
  3. Normalize both outputs.
  4. Compare according to policy.
  5. Produce readable failures.
  6. Include skipped cases with reason.
  7. Record unknown mismatches for triage.

  Important normalization concerns:

  - map key representation
  - keyword/string/symbol formatting
  - sets and ordering
  - floating point precision
  - ##NaN, ##Inf, ##-Inf
  - error vs value
  - eager vs lazy sequence output
  - Babashka JSON limitations

  Do not force all cases through JSON if that loses important Clojure semantics. Use EDN/string rendering where needed.

  Suggested test module:

  test/ptc_runner/lisp/conformance_runner_test.exs

  Suggested helper:

  test/support/lisp_conformance_runner.ex

  Phase 4: Seed Manual Cases

  Start small but high-value.

  Seed around 80-100 cases:

  50 clojure.core
  20 clojure.string
  10 clojure.set / clojure.walk
  10 intentional divergences

  Prioritize:

  - and, or, truthiness
  - if, when, cond, case
  - let, fn, defn, closure behavior
  - destructuring
  - apply
  - map, filter, reduce
  - first, rest, next, seq
  - get, assoc, update, get-in, assoc-in
  - conj, into, empty
  - equality and comparison
  - numeric operations
  - string split/join/replace/blank?/includes?
  - set union/intersection/difference
  - walk/prewalk/postwalk if supported

  For each supported function, add at least:

  one smoke case
  one nil/empty/boundary case where relevant
  one error-semantics case if risky

  Phase 5: Boundary/Error Semantics Matrix

  Create dedicated cases for behavior most likely to reveal policy bugs.

  For each important function, test:

  wrong arity
  wrong type
  nil input
  empty collection
  missing key
  out-of-range index
  malformed string
  NaN / infinity
  large number
  large collection

  Classify using the spec policy:

  bad external input -> may return signal value
  bad program -> should raise
  Java method -> Java behavior
  sandbox risk -> bounded/eager divergence

  This phase should produce many DIV-* candidates. Add them to docs/clojure-conformance-gaps.md only after deciding they are intentional.

  Phase 6: Upstream Test Mining

  Use other Clojure implementations as test sources, but import conservatively.

  Potential sources:

  Clojure official tests
  Babashka tests
  SCI tests
  Joker tests
  Clojure docstring examples

  Process:

  1. Download or vendor references only if acceptable for licensing.
  2. Extract simple assertions first:
      - (is (= expected form))
      - (is (true? form))
      - (is (false? form))
      - (is (nil? form))
      - (is (thrown? ... form))
  3. Filter out unsupported constructs:
      - macros
      - metadata
      - vars
      - namespaces
      - dynamic binding
      - atoms/refs/agents
      - JVM arrays/classes unless Java audit covers them
      - lazy infinite sequences
      - file/network/I/O
  4. Convert accepted assertions into the local case format.
  5. Mark source and original location.

  Suggested script:

  scripts/extract_clojure_conformance_cases.exs

  Do not try to import arbitrary upstream test code at first. Start with pattern-based extraction.

  Phase 7: Documentation Example Extraction

  Extract executable examples from local docs first.

  Sources:

  docs/ptc-lisp-specification.md
  docs/function-reference.md
  docs/clojure-conformance-gaps.md

  Then later external Clojure docs/docstrings.

  Process:

  1. Extract fenced clojure blocks.
  2. Split into individual forms where possible.
  3. Classify:
      - Clojure-compatible
      - PTC extension
      - unsupported
      - documentation-only
  4. Add cases or spec tests.

  This catches doc drift: examples in docs should either execute or be explicitly illustrative.

  Phase 8: Differential Fuzzing

  Add only after the deterministic suite is useful.

  Generate small supported expressions:

  literals
  vectors/maps/sets
  if
  let
  fn
  map/filter/reduce
  get/assoc/update
  string functions
  numeric ops
  comparisons

  Run generated forms against PTC-Lisp and Babashka.

  Record:

  seed
  form
  PTC result/error
  Clojure result/error
  classification

  Useful constraints:

  - small depth
  - finite collections only
  - no division by zero unless testing numeric edge cases
  - no infinite/lazy constructs
  - no unsupported macros
  - deterministic forms only

  Initial goal is not a perfect fuzzer. It is a mismatch discovery tool.

  Phase 9: Documentation And Audit Updates

  When a mismatch is found:

  1. Decide BUG vs DIV vs UNSUPPORTED.
  2. If BUG, add or update GAP-* in docs/clojure-conformance-gaps.md.
  3. If DIV, add or update DIV-* with:
      - example Clojure behavior
      - example PTC behavior
      - rationale
      - linked test id
  4. If audit metadata is wrong, edit metadata source, not generated docs.
  5. Regenerate docs:

  mix ptc.gen_docs

  6. Run relevant tests.

  Generated docs not to edit manually:

  docs/conformance/index.md
  docs/conformance/*-audit.md

  Phase 10: Namespace Review Order

  Recommended order:

  1. clojure.core high-use subset
  2. clojure.string
  3. clojure.set
  4. clojure.walk
  5. Java string/math/number/time methods
  6. PTC-specific extensions
  7. remaining candidate functions

  Within clojure.core, review in clusters:

  syntax/special forms
  truthiness/control flow
  function invocation
  binding/destructuring
  collections
  maps
  sets
  sequences
  numbers
  strings/regex
  predicates
  ordering/comparison
  formatting/printing
  resource limits

  Suggested Milestones

  Milestone 1: Foundation

  - Add conformance case format.
  - Add runner.
  - Add 50 manual cases.
  - Add basic coverage report.
  - Verify Babashka availability or clear skip message.

  Milestone 2: Core Review

  - Cover high-use clojure.core.
  - Add mismatch triage workflow.
  - Document new BUG-* and DIV-*.

  Milestone 3: Namespace Review

  - Cover clojure.string, clojure.set, clojure.walk.
  - Add edge/error matrix.

  Milestone 4: Importers

  - Add simple upstream test extractor.
  - Add local doc example extractor.

  Milestone 5: Fuzzing

  - Add optional differential fuzzer.
  - Keep it separate from normal test suite unless deterministic and fast.

  Milestone 6: CI/Long-Running Mode

  - Fast conformance tests run in normal CI.
  - Large imported/fuzz tests run behind tag, for example:

  mix test --only conformance_slow

  Verification Commands

  Use repo conventions and usage rules. Start with:

  mix test test/ptc_runner/lisp

  Check available tasks:

  mix help

  For usage rules/docs when touching dependencies or Mix behavior:

  mix usage_rules.search_docs "mix test"
  mix usage_rules.docs Enum

  If Babashka is missing, inspect existing helper:

  mix ptc.install_babashka

  Then run targeted tests.

  Deliverables For The Other Codex Session

  Ask the other session to produce:

  1. A written implementation plan in docs/plans/ptc-lisp-conformance-review.md.
  2. Initial conformance case format.
  3. Initial runner using Babashka and PTC-Lisp.
  4. At least 50 seeded cases.
  5. Coverage report for supported audit entries without cases.
  6. Documentation update explaining the workflow.
  7. Tests proving the runner catches:
      - a matching case
      - an intentional divergence
      - a PTC error
      - a Clojure error
      - a mismatch failure

  Non-Goals For The First Pass

  Do not start by trying to fully import Clojure’s whole test suite.

  Avoid:

  - arbitrary upstream test execution
  - broad fuzzing before deterministic cases exist
  - editing generated docs directly
  - adding compatibility shims for intentional divergences
  - treating every Clojure difference as a bug
  - testing PTC extensions against Clojure

  The first pass should create the machinery and seed enough cases to make the review repeatable. Then the long-running work becomes namespace-by-namespace triage.

