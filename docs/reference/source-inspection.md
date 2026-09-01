# Source-inspection reference

This page says where each kind of source can be retrieved, and which surface
owns the details.

An application's own attached prelude is not a separate retrieval mechanism:
local and shipped components use the same active `component` shape. Direct Lisp
evaluation without a Kernel environment has no component graph, so
`(components)` returns `[]` and `(component id)` returns `nil`. Active
inspection exposes direct component IDs for recursive lookup. Completed-run
inspection follows recorded typed relationships. Neither path reconstructs
dependencies from host log text.

## Where to retrieve source

| Lifetime | Surface | Exact bytes? | Channel | Limits |
| --- | --- | --- | --- | --- |
| Installed contracts | `ptc docs`, `(doc)`, `(export-meta)` | No; contracts and docstrings | Print or data | Print budget for `doc` |
| One attached defining form | `(source ref)` | The reachable defining form | Print | Print budget; no registry or filesystem fallback |
| Active workflow or mission graph | `(components)`, `(component id)` | Yes; interned effective source | Data | `terminal_result_bytes`; per-environment catalog |
| Credential-free preparation | `ptc repl --inspect-only` | Same catalog as a live session | REPL | No providers, input, traces, or private-session authority |
| Admitted nested-loop programs | `agent.core/run-outcome` with `retain_programs` | Yes, after admission | Outcome data | Count 1–128 and a 2,000,000-byte newest-whole-entry ring |
| Completed recorded run | `analysis/read` on private inspection | Yes; recorded programs and prelude sources | Private inspection | Private artifact authorization |

Public traces carry identities, hashes, dependency projections, and outcomes.
They do not carry source. Host logs and telemetry are not export surfaces.

## Active components

`(components)` returns attached IDs in frozen dependency order for the selected
workflow or mission environment. `(component id)` returns `nil` when the ID is
absent, otherwise:

| Key | Meaning |
| --- | --- |
| `:id` | Exact component ID |
| `:dependencies` | Direct edges only |
| `:namespaces` | Declared namespaces |
| `:source-hash` | Qualified `sha256:` of the exact source bytes |
| `:source` | Complete effective source, including private helpers and an active override |

`:origin` is omitted. There is no shipped-library or filesystem fallback for an
unattached ID. A workflow evaluation cannot read a mission component, and a
mission cannot read the workflow graph. Returning a component map or its
`:source` is charged to the ordinary evaluation result limit; bind the value
and slice `:source` when it is large.

The catalog is not prelude metadata and is never copied into result stamps,
traces, telemetry, or host logs. Only an explicit `component` call moves
attached source into ordinary workflow data. Component files must not contain
credentials.

`ptc repl --inspect-only` compiles the selected project or manifest environment
and attaches that catalog without a host document, environment file, input,
provider, or capability. Pure attached functions may run; Kernel, provider, and
capability routes fail closed. See the [REPL reference](repl.md#inspect-without-providers).

## Admitted programs

`retain_programs` exists only on `agent.core/run-outcome`. Omitted or `nil`
keeps the historical outcome shape. When set, every returned outcome includes
`:programs` and `:programs-omitted`. Entries keep `:turn`, `:mission`, and
exact `:source` for programs admitted to subordinate evaluation. Protocol
errors and source refused before admission are excluded. See the
[agent library reference](../agent-library-reference.md).

## Export and candidate files

`ptc materialize` has two exclusive modes. `--source-out` writes interned
installed bytes for later editing. `--source`/`--out` then hashes those edited
bytes into `{candidate.clj, descriptor.json}`. Candidate mode keeps the existing 1 MiB replacement bound; a larger installed component can still be inspected or exported. See the
[component reference](component-contracts.md#export-installed-source-or-publish-a-candidate).

## Completed runs

Private inspection retains exact generated programs, component sources, turns,
and typed relationships. `ptc transcript` is one private conversation, not a
general source export. See the
[debug-navigation reference](debug-navigation.md).
