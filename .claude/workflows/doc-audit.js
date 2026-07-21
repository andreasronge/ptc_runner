export const meta = {
  name: 'doc-audit',
  description:
    'Audit public-facing docs for correctness, broken references, stale/legacy material, and documentation-guideline compliance (excludes docs/plans/** and all conformance docs)',
  phases: [
    { title: 'Audit', detail: 'one agent per public doc' },
    { title: 'Verify', detail: 'adversarially verify each finding against source' },
    { title: 'Generated', detail: 'freshness of generated reference docs' },
    { title: 'Synthesize', detail: 'cross-doc inconsistencies and orphaned docs' },
  ],
}

// Public-facing, hand-written docs. Excludes docs/plans/** (plans + future
// specs) and all conformance docs (docs/conformance/**,
// clojure-conformance-gaps.md, conformance-classification-log.md) per request.
// Override by passing an array of paths as `args`.
const DEFAULT_DOCS = [
  'README.md',
  'AGENTS.md',
  'CHANGELOG.md',
  'docs/RELEASING.md',
  'docs/ptc-lisp-specification.md',
  'docs/signature-syntax.md',
  'docs/trace-log-contract.md',
  'docs/guides/building-agents.md',
  'docs/guides/capability-prelude.md',
  'docs/guides/documentation-guidelines.md',
  'docs/guides/embedding-in-elixir.md',
  'docs/guides/getting-started.md',
  'docs/guides/kernel-maintainer.md',
  'docs/guides/kernel-repl.md',
  'docs/guides/kernel-tutorial.md',
  'docs/guides/large-change-guidelines.md',
  'docs/guides/manifests-and-capabilities.md',
  'docs/guides/running-and-debugging.md',
  'ptc_viewer/README.md',
]

// Generated reference docs. Content is machine-derived and CI-gated by
// `mix ptc.gen_docs --check`; we check freshness, not prose.
const GENERATED_DOCS = ['docs/function-reference.md', 'docs/java-interop.md']

const GUIDELINES = `Documentation rules (docs/guides/documentation-guidelines.md) — the audit standard:
- Doc layers: Module docs describe the implemented public API; Guides explain implemented architecture/workflows; Specifications define normative language/runtime behavior; Plans (OUT OF SCOPE) describe unimplemented direction.
- Keep ONE canonical explanation and link to it; do not copy contracts between files.
- Do NOT present speculative/planned APIs as current behavior. Planned behavior MUST be explicitly labeled as planned (future tense).
- Code/guide/spec docs MUST NOT link to docs/plans/ (disposable planning records). A link into docs/plans/ from any in-scope doc is a guideline violation.
- Use real, current module/function/option/error/task names — verify them against the implementation before trusting the doc.
- Use present tense for implemented behavior; 'must' for normative requirements, 'may' for permitted choices, explicit future tense for plans.
- Git history records removed 0.x designs; current docs must NOT carry migration narratives or deprecated-alternative descriptions.
- State security, bounds, side effects, ownership, and failure behavior where users need them.`

const CONTEXT = `Repository: PtcRunner — a BEAM-native Elixir runtime for Programmatic Tool Calling (PTC-Lisp).
You run at the repo root. Source of truth for claims: lib/**, priv/preludes/**, priv/*.exs, mix.exs, examples/**, and the mix tasks under lib/mix/tasks/**.
OUT OF SCOPE as audit targets (do not audit their content): docs/plans/** and all conformance docs (docs/conformance/**, docs/clojure-conformance-gaps.md, docs/conformance-classification-log.md).
Generated docs (docs/function-reference.md, docs/java-interop.md, docs/conformance/*.md) are produced by 'mix ptc.gen_docs' from priv/*.exs — never propose hand-edits to them; links pointing INTO them still must resolve.`

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          category: {
            type: 'string',
            enum: [
              'broken-reference',
              'correctness',
              'legacy-stale',
              'completeness',
              'guideline-violation',
            ],
          },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          location: {
            type: 'string',
            description: 'line number, line range, or heading/anchor within the doc',
          },
          summary: { type: 'string', description: 'one-sentence statement of the defect' },
          evidence: {
            type: 'string',
            description:
              'the exact doc text at fault AND the concrete source location/path that contradicts it or is missing',
          },
          suggested_fix: { type: 'string' },
        },
        required: ['category', 'severity', 'location', 'summary', 'evidence', 'suggested_fix'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    verdict: { type: 'string', enum: ['CONFIRMED', 'REJECTED'] },
    corrected_severity: { type: 'string', enum: ['high', 'medium', 'low'] },
    reasoning: {
      type: 'string',
      description: 'what you independently checked in the source and what you found',
    },
  },
  required: ['verdict', 'reasoning'],
}

const SYNTH_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    cross_cutting: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          category: { type: 'string' },
          summary: { type: 'string' },
          evidence: { type: 'string' },
          suggested_fix: { type: 'string' },
        },
        required: ['category', 'summary', 'evidence', 'suggested_fix'],
      },
    },
    orphaned_docs: {
      type: 'array',
      items: { type: 'string' },
      description: 'in-scope docs not reachable from README/AGENTS or any other in-scope doc',
    },
    notes: { type: 'string' },
  },
  required: ['cross_cutting', 'orphaned_docs', 'notes'],
}

const FRESH_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    passed: { type: 'boolean' },
    summary: { type: 'string' },
    issues: { type: 'array', items: { type: 'string' } },
  },
  required: ['passed', 'summary', 'issues'],
}

const base = (p) => p.split('/').pop()

const auditPrompt = (doc) => `You are auditing ONE documentation file for correctness and hygiene: \`${doc}\`.

${CONTEXT}

${GUIDELINES}

Do this:
1. Read the ENTIRE file \`${doc}\` (read in chunks if it is long — do not skim).
2. Identify its layer (README / repo-instructions / guide / specification / generated-reference) and hold it to the matching rules above.
3. BROKEN REFERENCES — for every relative Markdown link \`[text](target)\` and image, resolve the target relative to this doc's directory and confirm it exists on disk with Bash (\`test -e\`, \`ls\`). For inline repository paths (including example paths like \`examples/...\` in code fences and \`mix ptc.run <path>\` commands), use the working directory stated by the surrounding documentation; if none is stated, test the intended repository-root or source-relative context before reporting a dangling target. For anchor links (\`#heading\` or \`file.md#heading\`), confirm the heading actually exists in the target file. Report every dangling target.
4. GUIDELINE VIOLATIONS — flag any link into \`docs/plans/\` from this doc; any planned/speculative API described as if it already exists (verify against lib/**); any migration/deprecation narrative; any duplicated contract that should be a link.
5. CORRECTNESS — verify concrete claims against the implementation with Bash/grep: mix task names (\`mix ptc.run\`, \`mix ptc.repl\`, \`mix ptc.gen_docs\`, \`mix precommit\`, \`mix prepush\`), module names (e.g. \`PtcRunner.Kernel\`), function names/arities, option keys, error atoms, config/manifest keys, prelude names and namespaces (e.g. \`log.core\`, \`log/runs\`), CLI flags, and quoted code snippets. If the doc names something that does not exist or contradicts the source, report it with the source location.
6. LEGACY / STALE — status tables that mislabel shipped vs planned, obsolete counts, renamed/removed modules, dead feature references, outdated version/availability claims.
7. COMPLETENESS — only clear, important omissions for this doc's layer (a missing security/bounds/failure note, an undocumented required step). Be conservative; do NOT invent nice-to-haves or prose polish.

Rules for findings:
- EVERY finding must cite concrete evidence: the exact doc text, its line/anchor, and the specific source path/line (or the missing target path) you checked. No vague "could be clearer" nits, no style preferences, no speculation.
- Only report defects you actually verified against disk/source in this run.
- If the file is clean, return an empty findings array. Do NOT edit any file — report only.

Return the structured findings object.`

const verifyPrompt = (doc, f) => `Adversarially verify a single documentation finding. Assume it is WRONG until the source proves it right; REJECT if you cannot independently substantiate it.

Doc: \`${doc}\`
Category: ${f.category}
Severity: ${f.severity}
Location: ${f.location}
Claim: ${f.summary}
Evidence given: ${f.evidence}
Suggested fix: ${f.suggested_fix}

${CONTEXT}

Independently re-check against disk/source (do not trust the evidence text):
- broken-reference: for Markdown links and images, resolve the target relative to \`${doc}\`'s directory and test existence yourself (\`test -e\`, \`ls\`); for inline repository paths and command arguments, use the working directory stated by the doc rather than treating a repository-root path as doc-relative. For anchors, grep the target file for the heading. CONFIRMED only if it is genuinely missing.
- correctness / legacy-stale: grep lib/**, priv/**, mix.exs, examples/** to confirm the doc truly contradicts the implementation. A thing defined via macro/metaprogramming still exists — check before rejecting.
- guideline-violation: confirm the rule is actually broken (e.g. an actual \`docs/plans/\` link, or planned behavior stated as current).
- completeness: CONFIRM only if the omission is real and important for this doc's layer.

Return CONFIRMED or REJECTED with reasoning describing exactly what you checked and found. Optionally set corrected_severity if the real severity differs.`

const freshPrompt = `Check whether the generated reference docs are fresh and internally consistent.

${CONTEXT}

Steps:
1. Run \`mix ptc.gen_docs --check\` from the repo root and capture the result. If it fails, the checked-in generated docs are stale — record the exact failing paths from the output.
2. For each of ${GENERATED_DOCS.map((d) => '`' + d + '`').join(' and ')}, verify its "See also:" links and any other relative links resolve to files that exist on disk (resolve relative to \`docs/\`).

Return passed=true only if the --check succeeds AND all links resolve. List every concrete issue in \`issues\`. Do not edit files.`

const synthPrompt = (docs, confirmed) => `Cross-document synthesis over the in-scope public docs. Individual per-file audits are done; now find issues that only appear across files.

In-scope docs (audited):
${docs.map((d) => '- ' + d).join('\n')}
Also present but OUT OF SCOPE: docs/plans/** and all conformance docs.

${CONTEXT}

Confirmed per-file findings so far (for context; do not repeat these):
${JSON.stringify(confirmed.map((f) => ({ doc: f.doc, category: f.category, summary: f.summary })), null, 2)}

Find, verifying against disk where needed:
1. ORPHANED DOCS — in-scope docs not linked from README.md, AGENTS.md, or any other in-scope doc (a reader could never navigate to them). Build the link graph with grep to decide.
2. CROSS-DOC INCONSISTENCY — the same contract/limit/task/name described differently across two docs (cite both). Prefer the one matching the implementation.
3. COVERAGE GAPS — an implemented, user-facing capability with no home in any in-scope doc, or a doc referenced as canonical that does not exist.

Only report items backed by concrete evidence (cite the files/lines). Return the structured object.`

// ── Run ────────────────────────────────────────────────────────────────────
const docs = Array.isArray(args) && args.length ? args : DEFAULT_DOCS
log(`Auditing ${docs.length} public docs (plans + conformance excluded).`)

phase('Audit')
// Kick off generated-doc freshness concurrently; awaited at the end.
const freshnessPromise = agent(freshPrompt, {
  label: 'generated-freshness',
  phase: 'Generated',
  schema: FRESH_SCHEMA,
})

const perDoc = await pipeline(
  docs,
  (doc) =>
    agent(auditPrompt(doc), { label: `audit:${base(doc)}`, phase: 'Audit', schema: FINDINGS_SCHEMA })
      .then((r) => ({ doc, findings: (r && r.findings) || [] })),
  (audit) =>
    parallel(
      audit.findings.map((f) => () =>
        agent(verifyPrompt(audit.doc, f), {
          label: `verify:${base(audit.doc)}`,
          phase: 'Verify',
          schema: VERDICT_SCHEMA,
        }).then((v) => ({ ...f, doc: audit.doc, verdict: v }))
      )
    ),
)

const verified = perDoc.flat().filter(Boolean)
const confirmed = verified.filter((f) => f.verdict && f.verdict.verdict === 'CONFIRMED')
const rejected = verified.filter((f) => f.verdict && f.verdict.verdict === 'REJECTED')
log(`Per-file: ${verified.length} findings raised, ${confirmed.length} confirmed, ${rejected.length} rejected.`)

phase('Synthesize')
const synthesis = await agent(synthPrompt(docs, confirmed), {
  label: 'synthesis',
  phase: 'Synthesize',
  schema: SYNTH_SCHEMA,
})

const freshness = await freshnessPromise

return {
  docs_audited: docs,
  totals: { raised: verified.length, confirmed: confirmed.length, rejected: rejected.length },
  confirmed: confirmed.map((f) => ({
    doc: f.doc,
    category: f.category,
    severity: (f.verdict && f.verdict.corrected_severity) || f.severity,
    location: f.location,
    summary: f.summary,
    evidence: f.evidence,
    suggested_fix: f.suggested_fix,
    verifier_reasoning: f.verdict && f.verdict.reasoning,
  })),
  rejected: rejected.map((f) => ({ doc: f.doc, summary: f.summary, why_rejected: f.verdict && f.verdict.reasoning })),
  generated_freshness: freshness,
  synthesis,
}
