export const meta = {
  name: 'conformance-batch',
  description:
    'Fix a batch of Clojure-conformance gaps in parallel git worktrees (one gap per subagent: bb-verify, implement, convert conformance case, drop audit clause, flip gaps-doc, codex-review-to-clean, one clean commit). The orchestrator integrates the side-branches serially afterward.',
  whenToUse:
    'Closing open BUGs from docs/clojure-conformance-gaps.md (tracking issue #1030). Pass args as an array of gap ids to override the default 5-gap batch (e.g. ["GAP-S136"]). The per-gap workflow is inlined in the prompt below — it is fully self-contained.',
  phases: [{ title: 'Fix', detail: 'one worktree agent per gap, capped 3 concurrent' }],
}

const REPO = '/Users/andreasronge/projects/ptc_runner'
const BB = REPO + '/_build/tools/bb'

// Default batch: 5 gaps, 5 distinct primary modules (no code-level collisions).
const ALL_GAPS = [
  {
    id: 'GAP-S09',
    pri: 'P1',
    branch: 'ptc-gap-s09',
    file: 'lib/ptc_runner/lisp/runtime/collection/select.ex',
    title: '`find` uses predicate-search semantics instead of Clojure map/vector lookup',
    docLine: 1488,
    auditFile: 'priv/function_audit.exs',
    cases: [
      'core/find-bug-001',
      'core/find-missing-key-bug-001',
      'core/find-present-nil-value-bug-001',
      'core/find-nil-bug-001',
      'core/find-vector-index-bug-001',
      'core/find-vector-present-nil-bug-001',
      'core/find-vector-out-of-range-bug-001',
      'core/find-vector-negative-index-bug-001',
      'core/find-set-nil-bug-001',
    ],
    nuance:
      'Clojure find is (find coll key) -> entry or nil, NOT predicate-first. The registry marks find as clojure.core/find but the current impl signature is (find pred coll). bb ground-truth: (find {:a 1} :a)=>[:a 1], (find {:a 1} :b)=>nil, (find {:a nil} :a)=>[:a nil] (present nil yields an entry), (find nil :a)=>nil, (find [10 20] 1)=>[1 20] (vectors are associative by index), (find [nil :b] 0)=>[0 nil], (find [10 20] 2)=>nil, (find [nil :b] -1)=>nil. (find #{nil} nil) RAISES in Clojure (sets are NOT associative) -> under the PTC value-model policy return a recoverable :type_error signal (do NOT raise), so core/find-set-nil-001 becomes a div_case, the rest become regression_case (policy :match). Make sure the new impl no longer treats the first arg as a predicate.',
  },
  {
    id: 'GAP-S22',
    pri: 'P1',
    branch: 'ptc-gap-s22',
    file: 'lib/ptc_runner/lisp/runtime/flex_access.ex',
    title: '`get-in` returns the supplied default for an explicitly-present nil value',
    docLine: 2158,
    auditFile: 'priv/function_audit.exs',
    cases: [
      'core/get-in-default-present-nil-bug-001',
      'core/get-in-default-nested-present-nil-bug-001',
      'core/get-in-default-vector-present-nil-bug-001',
    ],
    nuance:
      'bb ground-truth: (get-in {:a nil} [:a] :missing)=>nil, (get-in {:a {:b nil}} [:a :b] :missing)=>nil, (get-in [nil :b] [0] :missing)=>nil. get-in must distinguish a present key whose value is nil from a missing key when a default is supplied — get already does this (it can use contains?/associative membership). All three become regression_case (policy :match). IMPORTANT: the audit note in priv/function_audit.exs (around line 1292) is SHARED across GAP-S19/S22/S12/S36 — delete ONLY the "BUG GAP-S22: ..." sentence and keep the other clauses verbatim.',
  },
  {
    id: 'GAP-S136',
    pri: 'P1',
    branch: 'ptc-gap-s136',
    file: 'lib/ptc_runner/lisp/runtime/predicates.ex',
    title: '`map-entry?` does not recognize explicit seq map entries',
    docLine: 1790,
    auditFile: 'priv/function_audit.exs',
    cases: ['core/map-entry-predicate-seq-map-bug-001'],
    nuance:
      'bb ground-truth: (map-entry? (first (seq {:a 1})))=>true. PTC-Lisp has a distinct explicit seq map-entry view that `key` and `val` already understand; find that detection and make `map-entry?` recognize the same values. Becomes a regression_case (policy :match). The audit note (around line 1722) looks single-clause — confirm before editing and drop only the GAP-S136 clause.',
  },
  {
    id: 'GAP-S74',
    pri: 'P2',
    branch: 'ptc-gap-s74',
    file: 'lib/ptc_runner/lisp/runtime/string.ex',
    title: '`clojure.string/split` accepts a plain-string delimiter (Clojure requires a regex)',
    docLine: 2332,
    auditFile: 'priv/function_audit.exs',
    cases: ['string/split-string-delimiter-bug-001'],
    nuance:
      'Clojure (clojure.string/split "a.b.c" ".") RAISES ClassCastException — split takes a regex/Pattern, not a plain string. PTC currently silently splits => ["a" "b" "c"]. Under the value-model policy, do NOT silently accept a plain string: return a recoverable :type_error signal instead. Because Clojure raises, this is a div_case (pick the next free DIV-NN). CRITICAL: a real regex/pattern delimiter MUST keep working, and a single CHARACTER delimiter is a separate by-design DIV (char === one-char-string, GAP-S116) — do not regress those. Only a plain multi/non-pattern STRING delimiter should signal. The audit note (around line 3320) is SHARED across GAP-S15/S25/S74/S95/S116 — drop ONLY the "BUG GAP-S74: ..." clause.',
  },
  {
    id: 'GAP-J14',
    pri: 'P2',
    branch: 'ptc-gap-j14',
    file: 'lib/ptc_runner/lisp/runtime/interop.ex',
    title: 'Java `String.substring` rejects finite numeric (float) indexes instead of coercing',
    docLine: 951,
    auditFile: 'priv/java_compat_audit.exs',
    cases: [
      'java/string-substring-float-start-bug-001',
      'java/string-substring-float-start-end-bug-001',
    ],
    nuance:
      'GROUND TRUTH FOR THIS GAP IS JVM clojure (/opt/homebrew/bin/clojure -M -e ...), NOT bb — .substring is Java interop and bb/SCI may not replicate JVM coercion. The gap doc claims (.substring "abcd" 1.0)=>"bcd" and (.substring "abcd" 1.0 3.0)=>"bc" (Clojure coerces finite numeric args to the Java int param). VERIFY this against JVM clojure FIRST; if JVM actually raises, the doc is wrong — reclassify (div_case) and say so. .substring is a Java-shaped dot-method so it keeps JAVA semantics (coerce finite numerics, truncate toward zero) — this is separate from PTC grapheme indexing for the Clojure-named subs. If JVM confirms the doc, both become regression_case (policy :match — but note policy :match compares against bb; if bb cannot evaluate Java interop these may instead need div_case with an explicit ptc_expected. Decide based on what the conformance runner actually does for java/* cases — inspect a passing existing java/* regression_case to see whether they use :match against bb or div_case). The audit note in priv/java_compat_audit.exs (around line 214) is SHARED across GAP-J09/J14/DIV-41 — drop ONLY the "BUG GAP-J14: ..." clause.',
  },
]

const RESULT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['gapId', 'status', 'notes'],
  properties: {
    gapId: { type: 'string' },
    status: {
      type: 'string',
      enum: ['committed', 'blocked'],
      description: 'committed = one clean commit on the side branch; blocked = could not reach a clean codex round or hit an unresolved problem',
    },
    commitSha: { type: ['string', 'null'] },
    branch: { type: ['string', 'null'] },
    caseChanges: {
      type: 'string',
      description: 'the manual.ex case ids you changed and how (which became regression_case vs div_case)',
    },
    classification: {
      type: 'string',
      description: 'fixed (matches Clojure) or DIV-NN (intentional divergence) — list the DIV id(s) if any',
    },
    bbVerified: {
      type: 'string',
      description: 'what bb (or JVM clojure for J14) actually returned for the key forms vs what the gap doc claimed',
    },
    codexRounds: { type: 'integer' },
    codexGate: { type: 'string', enum: ['PASS', 'FAIL'] },
    declinedFindings: {
      type: 'string',
      description: 'codex findings you DECLINED and the value-model rationale, or "none"',
    },
    notes: { type: 'string', description: 'integration hazards, shared-helper touches, anything the orchestrator must know' },
  },
}

const PROMPT = (g) => `You are an expert Elixir engineer fixing exactly ONE Clojure-conformance gap in the PtcRunner repo (a 0.x BEAM library for Programmatic Tool Calling). Read CLAUDE.md conventions; delete-don't-deprecate; minimal, idiomatic changes.

GAP: ${g.id} (${g.pri}) — ${g.title}
Primary implementation file: ${g.file}
Gap-doc section: docs/clojure-conformance-gaps.md starting near line ${g.docLine}
Audit note file: ${g.auditFile}
Conformance cases (currently bug_case entries in test/support/lisp_conformance_cases/manual.ex):
${g.cases.map((c) => '  - ' + c).join('\n')}

GAP-SPECIFIC NOTES (decisive): ${g.nuance}

=== ENVIRONMENT — YOU ARE IN AN ISOLATED GIT WORKTREE ===
- Your CWD is a fresh worktree of the repo; its _build/ is EMPTY.
- Babashka (bb) is the ground-truth Clojure runner. It is NOT on PATH and your
  worktree has no _build/tools/bb. The real binary lives in the main checkout.
  BEFORE any bb call or conformance test, provision it (idempotent):
    mkdir -p _build/tools && ln -sf ${BB} _build/tools/bb && _build/tools/bb --version
  Without this, PtcRunner.Lisp.ClojureValidator.available? returns false and the
  :clojure conformance tests SILENTLY SKIP — a false pass. Never trust a clojure
  test run you have not confirmed actually executed your case.
- JVM clojure is at /opt/homebrew/bin/clojure (use: clojure -M -e '(prn (read-string "..."))').
  Prefer JVM clojure for reader/form-equality AND for Java-interop semantics; bb is
  ground-truth for ordinary runtime VALUES. (bb/SCI diverges from JVM on some cases.)

=== PTC VALUE-MODEL POLICY (decides regression_case vs div_case) ===
Clojure compatibility is the default, BUT sandbox safety and recoverable signal
values take precedence for Clojure-named functions WHERE CLOJURE WOULD RAISE.
Java-named dot-methods keep Java semantics. Practical rule:
  - Clojure returns a normal value  -> PTC must match it -> regression_case (policy :match).
  - Clojure RAISES on finite in-domain data -> PTC returns a recoverable signal
    value (e.g. a :type_error value), it does NOT raise -> div_case (policy {:diverges, DIV-NN}).

=== WORKFLOW (per-gap steps 1-5, 7, 8; SKIP step 6 regen — orchestrator owns it) ===
STEP 1 — VERIFY THE GAP DOC AGAINST GROUND TRUTH FIRST. The doc's "Clojure" and
  "PTC-Lisp current behavior" values are sometimes WRONG. Run every form through bb
  (or JVM clojure where noted) and record the real output. Example:
    _build/tools/bb -e '(prn (get-in {:a nil} [:a] :missing))'
  If a form makes Clojure raise, that implies a div_case under the policy above.

STEP 2 — IMPLEMENT the fix in ${g.file}. Read the whole module first; match its
  naming, error/signal idioms, and altitude. Keep it minimal. For shared helpers
  (flex_access / map_ops / callable dispatch / numeric) expect real edge cases.

STEP 3 — CONVERT the conformance case(s) in test/support/lisp_conformance_cases/manual.ex.
  Macros (defined at the bottom of that file):
    bug_case(id, ns, vars, form, gap_id, reason)                 -- OPEN bug (replace these)
    regression_case(id, ns, vars, form, regression_ids, tags)    -- FIXED, policy :match vs bb
    div_case(id, ns, vars, form, div_id, ptc_expected, reason)   -- reclassified DIV
  For each of this gap's cases: drop the "-bug" segment from the id. A fixed-to-match
  form becomes regression_case(<id>, ns, vars, form, ["${g.id}"], [<tags eg :edge>]).
  A form where Clojure raises becomes div_case(<id>, ns, vars, form, "DIV-NN", <ptc_expected>, "<reason>").
  For a new DIV id, grep manual.ex AND the gaps doc for the highest DIV-NN currently
  used and take the next number. Wrap any NaN/Inf/special-value ptc_expected in (str ...).

STEP 4 — DROP ONLY THIS GAP'S CLAUSE from the audit note in ${g.auditFile}. The note
  may be SHARED with other gaps — delete only the "BUG ${g.id}: ..." sentence/clause
  and keep every other clause in the same note byte-for-byte.

STEP 5 — FLIP STATUS in docs/clojure-conformance-gaps.md for ${g.id}: Status -> **fixed**,
  OR if reclassified, tombstone the header as "### ~~${g.id}~~: Reclassified as DIV-NN"
  and ADD a new "### DIV-NN:" section (table + ;; blocks + rationale). Replace the
  ";; PTC-Lisp current behavior" block with the FIXED outputs, fix Source ids if you
  renamed cases, and add a short "**Fix:**" paragraph.

STEP 7 — VERIFY (after provisioning bb):
    mix format
    mix compile --warnings-as-errors
    mix test test/ptc_runner/lisp --include clojure --seed 0
  CONFIRM your converted case(s) actually RAN and PASSED — grep the output for your
  case ids and for "skip". A fully skipped clojure suite means bb was not provisioned;
  fix and rerun. Do NOT create stray untracked files; delete any scratch test before step 8.
  DO NOT run 'mix ptc.gen_docs' or 'mix ptc.conformance_report' — the orchestrator runs
  the regen + N/N coverage gate ONCE after integrating all gaps.

STEP 8 — CODEX REVIEW (mandatory) on your UNCOMMITTED diff. Loop until clean:
    codex review --uncommitted -c 'model_reasoning_effort="high"' --enable web_search_cached 2>/dev/null
  (5-minute budget per call.) Gate: any line containing [P1] = FAIL. Fix real [P1] and
  in-scope [P2] correctness issues, then re-run. DECLINE findings that demand diverging
  from the PTC value-model policy above — document the rationale in the moduledoc and/or
  the gaps-doc **Fix** paragraph, then re-run codex (the recorded rationale usually
  clears it). Cap at 6 rounds. If still [P1] after 6 rounds: STOP, do NOT commit, report
  status "blocked" with the outstanding [P1] text.

COMMIT — only after a clean codex round (no [P1]). Stage ONLY your changed source files,
  nothing under _build/:
    git add -- ${g.file} test/support/lisp_conformance_cases/manual.ex ${g.auditFile} docs/clojure-conformance-gaps.md
    git status --porcelain   # confirm nothing stray is staged
    git commit -m "fix(lisp): <concise subject> (${g.id})"
  Then create a durable branch ref so the orchestrator can find your commit after the
  worktree is cleaned up, and capture the SHA:
    git branch ${g.branch} HEAD
    git rev-parse HEAD

Report via the structured-output tool: gapId, status, commitSha, branch, caseChanges,
classification (fixed or DIV-NN), bbVerified (real outputs vs doc claims), codexRounds,
codexGate, declinedFindings (with rationale, or "none"), and notes (integration hazards,
shared-helper touches).`

const wanted = Array.isArray(args) && args.length ? new Set(args) : null
const GAPS = wanted ? ALL_GAPS.filter((g) => wanted.has(g.id)) : ALL_GAPS

log(`Conformance batch: ${GAPS.map((g) => g.id).join(', ')} — one worktree agent each, max 3 concurrent.`)

phase('Fix')
const LIMIT = 3
const results = []
for (let i = 0; i < GAPS.length; i += LIMIT) {
  const wave = GAPS.slice(i, i + LIMIT)
  log(`Wave ${i / LIMIT + 1}: ${wave.map((g) => g.id).join(', ')}`)
  const waveResults = await parallel(
    wave.map((g) => () =>
      agent(PROMPT(g), {
        label: g.id,
        phase: 'Fix',
        isolation: 'worktree',
        schema: RESULT_SCHEMA,
      }),
    ),
  )
  results.push(...waveResults)
}

const clean = results.filter(Boolean)
const committed = clean.filter((r) => r.status === 'committed')
log(`Done: ${committed.length}/${GAPS.length} committed. Branches: ${committed.map((r) => r.branch).filter(Boolean).join(', ')}`)
return clean
