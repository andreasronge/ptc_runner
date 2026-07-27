export const meta = {
  name: 'code-doc-audit',
  description:
    'Audit in-code documentation (@moduledoc/@doc/@typedoc/@shortdoc and doc comments in lib/**) for stale references to specs/plans that no longer exist, broken doc links, and drift from the implementation',
  phases: [
    { title: 'Audit', detail: 'one agent per file group' },
    { title: 'Verify', detail: 'adversarially verify each finding against source/docs' },
    { title: 'Synthesize', detail: 'systemic patterns and cross-file consistency' },
  ],
}

// Ground truth established by scouting before this run:
const CONTEXT = `Repository: PtcRunner — a BEAM-native Elixir runtime for Programmatic Tool Calling (PTC-Lisp). You run at the repo root.
You are auditing IN-CODE documentation: \`@moduledoc\`, \`@doc\`, \`@typedoc\`, \`@shortdoc\`, and doc/rationale \`#\` comments in \`lib/**/*.ex\`. (\`@spec\` typespecs are NOT doc prose — never flag them.)

Retained, authoritative references (verify claims against these, on disk):
- Implementation: \`lib/**\`, \`priv/preludes/**\`, \`priv/*.exs\`, \`mix.exs\`, \`examples/**\`.
- Language spec: \`docs/ptc-lisp-specification.md\`. Its ONLY top-level sections are 1–16:
  1 Overview, 2 Lexical Structure, 3 Data Types, 4 Truthiness, 5 Special Forms, 6 Threading Macros,
  7 Filtering Predicates, 8 Core Functions, 9 Namespaces/Context/Tools, 10 Complete Examples,
  11 Semantics and Edge Cases, 12 Error Handling, 13 Language Scope and Restrictions, 14 Grammar (EBNF),
  15 Implementation Notes, 16 Memory Model for Agentic Loops.
  There is NO JSON section and NO §4.2/§4.3/§4.4 subsections (§4 is "Truthiness", with no subsections).
  Always confirm a cited §number by grepping headings: \`rg -n '^#{1,4} [0-9]' docs/ptc-lisp-specification.md\`.
- Conformance IDs (\`DIV-*\`, \`GAP-*\`) live in \`docs/clojure-conformance-gaps.md\`; confirm each cited ID exists: \`rg -n '^### (DIV-13|GAP-S54):' docs/clojure-conformance-gaps.md\`.
- ExDoc \`:extras\` (the only .md files an ExDoc autolink like \`[x](foo.md)\` resolves to): README.md, LICENSE, docs/ptc-lisp-specification.md, docs/clojure-conformance-gaps.md, docs/function-reference.md, docs/java-interop.md, docs/trace-log-contract.md, docs/conformance/index.md, docs/conformance/*-audit.md, and docs/guides/{getting-started,manifests-and-capabilities,building-agents,running-and-debugging,kernel-repl,components-and-preludes,embedding-in-elixir,documentation-guidelines,kernel-maintainer}.md.

Documentation-guidelines rules that bind code docs (docs/guides/documentation-guidelines.md):
- Code documentation MUST NOT reference implementation plans or planning specifications (anything under docs/plans/). Durable contracts belong in module docs / guides / retained specs.
- ESTABLISHED FACT for this audit: the code carries ~35 "plan §N" citations (e.g. "(plan §12)", "plan §3 / §6A", "Capability Prelude V1, plan §5"). NO current plan document uses §-numbered sections (the prelude plan uses named "## ..." / "### Phase N" headings), and no retained doc defines "Capability Prelude V1". So every "plan §N" citation is a DANGLING reference to a superseded plan AND a guideline violation. Flag each as category "plan-reference"; the fix is to delete the "(plan §N)" citation while KEEPING the surrounding rationale prose intact and grammatical.
- Use real, current module/function/option/error names; verify before trusting the doc.
- No migration narratives or deprecated-alternative descriptions (git history holds removed 0.x designs).`

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
          file: { type: 'string' },
          line: { type: 'integer' },
          category: {
            type: 'string',
            enum: [
              'plan-reference',
              'stale-spec-reference',
              'broken-conformance-id',
              'broken-doc-link',
              'stale-content',
              'correctness',
            ],
          },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          summary: { type: 'string', description: 'one-sentence statement of the defect' },
          evidence: {
            type: 'string',
            description: 'the exact doc text + the source/heading you checked that proves it wrong or missing',
          },
          suggested_fix: {
            type: 'string',
            description: 'concrete replacement text; for plan-reference give the exact edited sentence',
          },
        },
        required: ['file', 'line', 'category', 'severity', 'summary', 'evidence', 'suggested_fix'],
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
    reasoning: { type: 'string' },
  },
  required: ['verdict', 'reasoning'],
}

const SYNTH_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    systemic_patterns: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          pattern: { type: 'string' },
          affected_files: { type: 'array', items: { type: 'string' } },
          recommendation: { type: 'string' },
        },
        required: ['pattern', 'affected_files', 'recommendation'],
      },
    },
    notes: { type: 'string' },
  },
  required: ['systemic_patterns', 'notes'],
}

const auditPrompt = (group) => `Audit the in-code documentation in this file group: **${group.name}**.

Files (audit the doc prose in each — read every one, in chunks if long):
${group.files.map((f) => '- ' + f).join('\n')}

${CONTEXT}

For every \`@moduledoc\`/\`@doc\`/\`@typedoc\`/\`@shortdoc\` string and every explanatory \`#\` comment in these files, check:
1. PLAN REFERENCES — any "plan §N", "(plan ...)", "plan acceptance", "Prelude V1 ... plan", or similar citation of a planning document. Flag each (category "plan-reference"); the suggested_fix is the sentence rewritten with the citation removed and prose kept.
2. STALE SPEC REFERENCES — any "§X", "§X.Y", "spec §…", "Section N", or paragraph pointer into the language spec. Grep the spec headings and confirm the number exists AND covers the cited topic. Flag mismatches (category "stale-spec-reference"). Note: "Section 13" (Language Scope) and "§3.5" (Character Literals) DO exist — confirm before flagging. The JSON \`§4.2/§4.3/§4.4\` citations do NOT resolve.
3. BROKEN CONFORMANCE IDS — any \`DIV-*\`/\`GAP-*\` citation; confirm the ID exists in docs/clojure-conformance-gaps.md (category "broken-conformance-id" if absent).
4. BROKEN DOC LINKS — any Markdown link or path to a .md/doc file; confirm the target exists on disk and (for ExDoc autolinks) is in :extras (category "broken-doc-link").
5. STALE CONTENT — references to removed/renamed modules, functions, options, or events; migration narratives; behavior descriptions that no longer match the code (category "stale-content").
6. CORRECTNESS — moduledoc/@doc claims contradicting the implementation: wrong option keys, error atoms, function names/arities, defaults, ownership, or return shapes (category "correctness"). Verify with grep against the module and its collaborators.

Rules:
- EVERY finding cites file + line + the exact doc text AND the source/heading you checked. No style nits, no speculation, no prose-polish suggestions.
- Only report what you verified against disk in this run. Do NOT edit files.
- If a file's docs are clean, say nothing about it. Return an empty findings array if the whole group is clean.

Return the structured findings object.`

const verifyPrompt = (f) => `Adversarially verify one in-code-documentation finding. Assume it is WRONG until source/docs prove it right; REJECT if you cannot independently substantiate it.

File: ${f.file}
Line: ${f.line}
Category: ${f.category}
Severity: ${f.severity}
Claim: ${f.summary}
Evidence given: ${f.evidence}
Suggested fix: ${f.suggested_fix}

${CONTEXT}

Re-check independently against disk (do not trust the evidence text):
- plan-reference: open the file at the line and confirm a plan citation is actually present in DOC prose (not a @spec, not unrelated). CONFIRM only if present.
- stale-spec-reference: grep the spec headings yourself; CONFIRM only if the cited section truly does not exist or does not cover the topic. Remember §3.5, §13, and §16 etc. DO exist.
- broken-conformance-id: grep docs/clojure-conformance-gaps.md for the exact ID; CONFIRM only if genuinely absent.
- broken-doc-link: test the target path / :extras membership yourself.
- stale-content / correctness: grep lib/**, priv/**, mix.exs to confirm the doc truly contradicts the code. A thing defined via macro/metaprogramming still exists.

Return CONFIRMED or REJECTED with reasoning stating exactly what you checked. Optionally set corrected_severity.`

const synthPrompt = (groups, confirmed) => `Synthesize the code-documentation audit. Per-file findings are done; identify systemic patterns and anything cross-file.

Groups audited: ${groups.map((g) => g.name).join(', ')}.

${CONTEXT}

Confirmed findings (for context):
${JSON.stringify(confirmed.map((f) => ({ file: f.file, line: f.line, category: f.category, summary: f.summary })), null, 2)}

Produce:
1. SYSTEMIC PATTERNS — issues that recur across many files and deserve one coordinated fix (e.g. the "plan §N" citation sweep, a spec section that was renumbered and is now cited wrong in several places, a repeated stale event/option name). For each, list the affected files and a single recommendation.
2. NOTES — anything the per-file pass may have missed (a whole module's moduledoc describing removed behavior; a doc contract with no retained home) and a short statement of what came back clean.

Only include patterns backed by the confirmed findings or by evidence you re-checked. Return the structured object.`

// Balanced file groups (~13 files each) covering every lib/**/*.ex. Override by
// passing an array of {name, files[]} as `args`.
const DEFAULT_GROUPS = [
  { name: 'mix/tasks', files: ['lib/mix/tasks/bench.check.ex', 'lib/mix/tasks/ptc.audit_upstream.ex', 'lib/mix/tasks/ptc.clojure_audit.ex', 'lib/mix/tasks/ptc.conformance_report.ex', 'lib/mix/tasks/ptc.gen_docs.ex', 'lib/mix/tasks/ptc.install_babashka.ex', 'lib/mix/tasks/ptc.repl.ex', 'lib/mix/tasks/ptc.run.ex', 'lib/mix/tasks/ptc.smoke.ex', 'lib/mix/tasks/ptc.update_spec_checksums.ex', 'lib/mix/tasks/ptc.validate_spec.ex'] },
  { name: 'root', files: ['lib/ptc_runner.ex'] },
  { name: 'ptc_runner', files: ['lib/ptc_runner/dotenv.ex', 'lib/ptc_runner/kernel.ex', 'lib/ptc_runner/lisp.ex', 'lib/ptc_runner/llm.ex', 'lib/ptc_runner/sandbox.ex'] },
  { name: 'kernel#1', files: ['lib/ptc_runner/kernel/bounded_worker.ex', 'lib/ptc_runner/kernel/bundle_compiler.ex', 'lib/ptc_runner/kernel/capability.ex', 'lib/ptc_runner/kernel/component.ex', 'lib/ptc_runner/kernel/deterministic_json.ex', 'lib/ptc_runner/kernel/dispatcher.ex', 'lib/ptc_runner/kernel/environment.ex', 'lib/ptc_runner/kernel/error.ex', 'lib/ptc_runner/kernel/evaluation.ex', 'lib/ptc_runner/kernel/event_sink.ex', 'lib/ptc_runner/kernel/event_sink_state.ex', 'lib/ptc_runner/kernel/events.ex', 'lib/ptc_runner/kernel/file_capability.ex'] },
  { name: 'kernel#2', files: ['lib/ptc_runner/kernel/frozen_bundle.ex', 'lib/ptc_runner/kernel/inspection_artifact.ex', 'lib/ptc_runner/kernel/inspection_sink.ex', 'lib/ptc_runner/kernel/json_schema.ex', 'lib/ptc_runner/kernel/json_value.ex', 'lib/ptc_runner/kernel/library.ex', 'lib/ptc_runner/kernel/limits.ex', 'lib/ptc_runner/kernel/llm_capability.ex', 'lib/ptc_runner/kernel/log_analysis_assembly.ex', 'lib/ptc_runner/kernel/log_analysis_profile.ex', 'lib/ptc_runner/kernel/log_analysis_session.ex', 'lib/ptc_runner/kernel/log_analysis_session_builder.ex', 'lib/ptc_runner/kernel/manifest.ex'] },
  { name: 'kernel#3', files: ['lib/ptc_runner/kernel/mcp_lease.ex', 'lib/ptc_runner/kernel/mcp_source.ex', 'lib/ptc_runner/kernel/mission_environment.ex', 'lib/ptc_runner/kernel/mission_inventory.ex', 'lib/ptc_runner/kernel/model_contract.ex', 'lib/ptc_runner/kernel/program.ex', 'lib/ptc_runner/kernel/provider_error.ex', 'lib/ptc_runner/kernel/provider_registry.ex', 'lib/ptc_runner/kernel/repl_session.ex', 'lib/ptc_runner/kernel/result.ex', 'lib/ptc_runner/kernel/run_builder.ex', 'lib/ptc_runner/kernel/run_config.ex', 'lib/ptc_runner/kernel/run_state.ex'] },
  { name: 'kernel#4', files: ['lib/ptc_runner/kernel/runner.ex', 'lib/ptc_runner/kernel/runtime_tools.ex', 'lib/ptc_runner/kernel/safe_metadata.ex', 'lib/ptc_runner/kernel/session_trace.ex', 'lib/ptc_runner/kernel/strict_json.ex', 'lib/ptc_runner/kernel/trace_capability.ex', 'lib/ptc_runner/kernel/trace_log.ex', 'lib/ptc_runner/kernel/trace_snapshot.ex', 'lib/ptc_runner/kernel/viewer_adapter.ex', 'lib/ptc_runner/kernel/viewer_repl_adapter.ex', 'lib/ptc_runner/kernel/viewer_repl_backend.ex', 'lib/ptc_runner/kernel/viewer_repl_session_worker.ex', 'lib/ptc_runner/kernel/workflow_environment.ex'] },
  { name: 'lisp#1', files: ['lib/ptc_runner/lisp/ambiguous_arguments.ex', 'lib/ptc_runner/lisp/analyze.ex', 'lib/ptc_runner/lisp/ast.ex', 'lib/ptc_runner/lisp/builtin_names.ex', 'lib/ptc_runner/lisp/child_result.ex', 'lib/ptc_runner/lisp/clojure_validator.ex', 'lib/ptc_runner/lisp/closure_capture.ex', 'lib/ptc_runner/lisp/context.ex', 'lib/ptc_runner/lisp/core_ast.ex', 'lib/ptc_runner/lisp/core_to_source.ex', 'lib/ptc_runner/lisp/data_keys.ex', 'lib/ptc_runner/lisp/env.ex', 'lib/ptc_runner/lisp/eval.ex'] },
  { name: 'lisp#2', files: ['lib/ptc_runner/lisp/externalized_map_key.ex', 'lib/ptc_runner/lisp/fast_parser.ex', 'lib/ptc_runner/lisp/format.ex', 'lib/ptc_runner/lisp/formatter.ex', 'lib/ptc_runner/lisp/key_normalizer.ex', 'lib/ptc_runner/lisp/keyword.ex', 'lib/ptc_runner/lisp/metadata.ex', 'lib/ptc_runner/lisp/parser.ex', 'lib/ptc_runner/lisp/prelude.ex', 'lib/ptc_runner/lisp/protected_namespaces.ex', 'lib/ptc_runner/lisp/registry.ex', 'lib/ptc_runner/lisp/result.ex', 'lib/ptc_runner/lisp/retained_size.ex'] },
  { name: 'lisp#3', files: ['lib/ptc_runner/lisp/runtime.ex', 'lib/ptc_runner/lisp/runtime_callable.ex', 'lib/ptc_runner/lisp/schema.ex', 'lib/ptc_runner/lisp/signature.ex', 'lib/ptc_runner/lisp/source_atoms.ex', 'lib/ptc_runner/lisp/spec_validator.ex', 'lib/ptc_runner/lisp/symbol_counter.ex', 'lib/ptc_runner/lisp/tool.ex', 'lib/ptc_runner/lisp/trusted_tool.ex', 'lib/ptc_runner/lisp/type_extractor.ex', 'lib/ptc_runner/lisp/type_vocabulary.ex', 'lib/ptc_runner/lisp/untrusted_renderer.ex'] },
  { name: 'lisp/analyze', files: ['lib/ptc_runner/lisp/analyze/conditionals.ex', 'lib/ptc_runner/lisp/analyze/definitions.ex', 'lib/ptc_runner/lisp/analyze/iteration.ex', 'lib/ptc_runner/lisp/analyze/patterns.ex', 'lib/ptc_runner/lisp/analyze/placeholder.ex', 'lib/ptc_runner/lisp/analyze/prelude_scope.ex', 'lib/ptc_runner/lisp/analyze/short_fn.ex'] },
  { name: 'lisp/env', files: ['lib/ptc_runner/lisp/env/builtin.ex'] },
  { name: 'lisp/eval', files: ['lib/ptc_runner/lisp/eval/abort.ex', 'lib/ptc_runner/lisp/eval/apply.ex', 'lib/ptc_runner/lisp/eval/capture.ex', 'lib/ptc_runner/lisp/eval/context.ex', 'lib/ptc_runner/lisp/eval/effects.ex', 'lib/ptc_runner/lisp/eval/helpers.ex', 'lib/ptc_runner/lisp/eval/host_context.ex', 'lib/ptc_runner/lisp/eval/outcome.ex', 'lib/ptc_runner/lisp/eval/parallel.ex', 'lib/ptc_runner/lisp/eval/parallel_budget.ex', 'lib/ptc_runner/lisp/eval/parallel_runner.ex', 'lib/ptc_runner/lisp/eval/patterns.ex', 'lib/ptc_runner/lisp/eval/parallel_runner/envelope.ex'] },
  { name: 'lisp/java', files: ['lib/ptc_runner/lisp/java/surface.ex', 'lib/ptc_runner/lisp/java/surface/validator.ex'] },
  { name: 'lisp/prelude', files: ['lib/ptc_runner/lisp/prelude/attach.ex', 'lib/ptc_runner/lisp/prelude/attach_context.ex', 'lib/ptc_runner/lisp/prelude/bundle.ex', 'lib/ptc_runner/lisp/prelude/compiler.ex', 'lib/ptc_runner/lisp/prelude/contract.ex', 'lib/ptc_runner/lisp/prelude/export.ex', 'lib/ptc_runner/lisp/prelude/form_scanner.ex', 'lib/ptc_runner/lisp/prelude/spec.ex', 'lib/ptc_runner/lisp/prelude/validation_error.ex'] },
  { name: 'lisp/runtime#1', files: ['lib/ptc_runner/lisp/runtime/args.ex', 'lib/ptc_runner/lisp/runtime/builtins.ex', 'lib/ptc_runner/lisp/runtime/callable.ex', 'lib/ptc_runner/lisp/runtime/collection.ex', 'lib/ptc_runner/lisp/runtime/describe.ex', 'lib/ptc_runner/lisp/runtime/flex_access.ex', 'lib/ptc_runner/lisp/runtime/interop.ex', 'lib/ptc_runner/lisp/runtime/json.ex', 'lib/ptc_runner/lisp/runtime/map_ops.ex', 'lib/ptc_runner/lisp/runtime/math.ex', 'lib/ptc_runner/lisp/runtime/predicates.ex', 'lib/ptc_runner/lisp/runtime/regex.ex', 'lib/ptc_runner/lisp/runtime/special_values.ex'] },
  { name: 'lisp/runtime#2', files: ['lib/ptc_runner/lisp/runtime/string.ex', 'lib/ptc_runner/lisp/runtime/collection/normalize.ex', 'lib/ptc_runner/lisp/runtime/collection/select.ex', 'lib/ptc_runner/lisp/runtime/collection/transform.ex'] },
  { name: 'lisp/signature', files: ['lib/ptc_runner/lisp/signature/coercion.ex', 'lib/ptc_runner/lisp/signature/parser.ex', 'lib/ptc_runner/lisp/signature/parser_helpers.ex', 'lib/ptc_runner/lisp/signature/renderer.ex', 'lib/ptc_runner/lisp/signature/type_resolver.ex', 'lib/ptc_runner/lisp/signature/validator.ex'] },
  { name: 'lisp/spec_validator', files: ['lib/ptc_runner/lisp/spec_validator/parser.ex'] },
  { name: 'llm', files: ['lib/ptc_runner/llm/default_registry.ex', 'lib/ptc_runner/llm/registry.ex', 'lib/ptc_runner/llm/req_llm_adapter.ex'] },
]

// ── Run ────────────────────────────────────────────────────────────────────
const groups = Array.isArray(args) && args.length ? args : DEFAULT_GROUPS
log(`Auditing in-code docs across ${groups.length} groups (${groups.reduce((n, g) => n + g.files.length, 0)} files).`)

phase('Audit')
const perGroup = await pipeline(
  groups,
  (g) =>
    agent(auditPrompt(g), { label: `audit:${g.name}`, phase: 'Audit', schema: FINDINGS_SCHEMA }).then((r) => ({
      group: g.name,
      findings: (r && r.findings) || [],
    })),
  (audit) =>
    parallel(
      audit.findings.map((f) => () =>
        agent(verifyPrompt(f), { label: `verify:${f.file.split('/').pop()}:${f.line}`, phase: 'Verify', schema: VERDICT_SCHEMA }).then((v) => ({
          ...f,
          verdict: v,
        }))
      )
    )
)

const verified = perGroup.flat().filter(Boolean)
const confirmed = verified.filter((f) => f.verdict && f.verdict.verdict === 'CONFIRMED')
const rejected = verified.filter((f) => f.verdict && f.verdict.verdict === 'REJECTED')
log(`${verified.length} findings raised, ${confirmed.length} confirmed, ${rejected.length} rejected.`)

phase('Synthesize')
const synthesis = await agent(synthPrompt(groups, confirmed), { label: 'synthesis', phase: 'Synthesize', schema: SYNTH_SCHEMA })

// Sort confirmed by file then line for easy application.
const bySeverity = { high: 0, medium: 1, low: 2 }
const sortedConfirmed = confirmed
  .map((f) => ({
    file: f.file,
    line: f.line,
    category: f.category,
    severity: (f.verdict && f.verdict.corrected_severity) || f.severity,
    summary: f.summary,
    evidence: f.evidence,
    suggested_fix: f.suggested_fix,
    verifier_reasoning: f.verdict && f.verdict.reasoning,
  }))
  .sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line))

const byCategory = {}
for (const f of sortedConfirmed) byCategory[f.category] = (byCategory[f.category] || 0) + 1

return {
  totals: { raised: verified.length, confirmed: confirmed.length, rejected: rejected.length, by_category: byCategory },
  confirmed: sortedConfirmed,
  rejected: rejected.map((f) => ({ file: f.file, line: f.line, summary: f.summary, why_rejected: f.verdict && f.verdict.reasoning })),
  synthesis,
}
