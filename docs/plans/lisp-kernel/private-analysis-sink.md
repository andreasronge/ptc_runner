# Non-interactive private inspection analysis

**Status:** design, fourth revision, 2026-08-01. No implementation started.
Addresses finding 6 of [`agent-developer-findings.md`](agent-developer-findings.md).

Three earlier drafts were wrong in ways worth recording, because each error was
a plausible sentence the code contradicted:

- the security justification — the Viewer already provides validated
  non-interactive access to the same records, so there was never an integrity
  gap;
- "route `error.message` to the sink" — already redacted before the frontend
  sees it;
- "buffer records and write them as the session runs" — buffering and streaming
  are different designs;
- "matches `InspectionArtifact`" — that module does not hold an append target
  open;
- "`session-closed` carries the state" — it is not emitted when close fails.

This revision starts from what already works rather than from what is missing.

## The session machinery already runs without a terminal

The Viewer serves a bounded `log-analysis-v2` REPL over HTTP with no terminal
anywhere. `ViewerReplSessionWorker.run/3` calls the same constructor the CLI
uses:

```elixir
AnalysisSessionBuilder.start(
  LogAnalysisProfile.id(),
  %{"traces" => trace_dir},
  {:directory, trace_dir}
)
```

No frontend authorization, no terminal check, no options. It works because
`log-analysis-v2` declares `private_terminal: :forbidden`, so the builder's
`authorize_private_profile/2` returns `:ok`.

So sessions, preludes, bounded queries, and pagination are all already
non-interactive. **Nothing in the analysis engine needs a terminal.** What is
missing is a private-capable frontend contract, not new session machinery.

## Where the gate actually lives

Two independent authorization layers, and only one is shared:

| Layer | Enforces | CLI | Viewer |
| --- | --- | --- | --- |
| `AnalysisSessionBuilder.authorize_private_profile/2` | `private_terminal: true` **and** `AnalysisTerminal.attached?()` for any profile declaring `private_terminal: :required` | passes the flag | never passes it |
| `AnalysisProfileRegistry.authorize_frontend/2` | `input_modes`, `output_formats`, `continue_on_error`, terminal | calls it | **ignores it entirely** |

The builder layer is the real gate: it applies to every caller. The registry
layer is a CLI-only contract that the Viewer does not participate in — which is
why the Viewer can serve a REPL that the CLI's own frontend table would reject.

That divergence is the thing to fix. The `frontend/0` contract claims to
describe how a profile may be driven, but one of the two frontends does not
consult it.

## What is actually wrong

The CLI is the intended analysis interface for an agent — it has the preludes,
bounded cursor-paginated queries, and `inspection.analysis/all-*` with explicit
page bounds. The Viewer's `/api/inspection/runs/:run_id` is a whole-artifact
dump: one `curl` returned 209,833 bytes for a five-turn run, with no filtering,
projection, or pagination. It is a browsing surface, not a query surface, and it
should not become the agent path by default.

`log-analysis-v2` already serves canonical traces through the CLI
non-interactively. `inspection-analysis-v2` refuses the same usage over private
records despite sharing the builder, the analysis engine, and the prelude
layering. **The defect is that asymmetry**, and the change grants no access the
Viewer does not already grant.

## Trust boundary

**Same-UID processes are trusted.** Confirmed by the maintainer, 2026-08-01.

An earlier draft grounded this by citing `stable-cli-contract.md`'s non-goal
"an adversarial same-user/same-VM security boundary." That was overstated — that
document is a disposable plan scoped to the standalone CLI. **Record the
decision in `InspectionAnalysisProfile`'s moduledoc**, which is durable, as part
of this work.

Consequences: `PrivateDirectory`'s pathname preflight is adequate and
`openat2`-class discipline is unnecessary; `0600` protects against other UIDs,
not same-UID processes; post-open `fstat` checks remain as protection against
operator mistakes, not adversaries.

## The refactoring: a private destination, not a terminal

Replace the builder's terminal requirement with a **private destination** the
builder validates, which each frontend implements in its own way.

```
authorize_private_profile(recipe, opts)
  :required -> exactly one authorized destination must be present
```

| Frontend | Destination |
| --- | --- |
| CLI, interactive | attached terminal (today's behaviour, unchanged) |
| CLI, non-interactive | `--private-sink PATH`, an owner-only file |
| Viewer | the pinned loopback response it already serves |

This makes `frontend/0` describe something both frontends can honour, and moves
the CLI's `input_modes`/`output_formats` from a CLI-private table into the
destination's declared capabilities. A host that wants to refuse unattended
private extraction declares no non-interactive destination.

The sink is one implementation of this abstraction, not the abstraction itself.
That framing matters: the previous drafts designed the sink first and then tried
to justify it.

## Seam A — the projection boundary (shared, not CLI-only)

`AnalysisSession.project_result/2` (`analysis_session.ex:335`) produces the
public projection every frontend receives. `error_message/2`
(`analysis_session.ex:485`) already replaces the message with the constant
`"private evaluation failed"` when `result_data_class != "normal"` — but
`formatted`, `value`, and `prints` are not redacted, and flow to whatever
frontend asked.

**This is not a CLI problem.** If the Viewer ever served a private profile it
would face it identically. Fix it once, in the session.

**Design:** under a private destination, `project_result/2` returns
`{safe_projection, private_record}`. The private record is built from the
detailed result *before* redaction; the frontend never receives private content.

### The safe projection

Constructed explicitly and validated — **not** a key filter over
`json_projection/1`, which turns a future producer change into a silent leak.

| Field | Constraint |
| --- | --- |
| `status`, `outcome` | closed enum |
| `evaluation_id` | opaque id |
| `duration_ms` | integer |
| `continuation_effect` | closed enum: `committed_with_history`, `committed_without_history`, `preserved` (`evaluation.ex:340`) |
| `usage` | counts and byte totals only |
| `value_available`, `formatted_truncated`, `prints_truncated` | boolean |
| `error.kind`, `error.reason` | closed enum |
| `error.capability_activity?`, `error.capability_failure?`, `error.retryable?` | boolean (`analysis_session.ex:471`) |

An out-of-enum value is rejected, not passed through.

### The private record

`evaluation_id`, `formatted`, `value`, `prints`, and the **unredacted** bounded
`details.message`. Joined to the safe stream on `evaluation_id`.

### Accepted side channels

`value_available`, truncation flags, `duration_ms`, and `usage` counters
disclose presence, size thresholds, timing, and activity. `session-closed`'s
`trace_path` is a host path. These are **accepted** and stated as such — an
unqualified "stdout contains nothing private" is the claim that failed review
twice.

## Seam B — the sink artifact

**Buffer in memory; build, validate, and publish one complete artifact at
close.** Chosen explicitly over per-evaluation writes and over accepting
post-commit write failure. Blending those is what left the earlier draft's
transactional coupling alive.

This matches `InspectionArtifact`, which constructs and validates a complete
encoded artifact, writes a temporary file, and links it
(`inspection_artifact.ex:579`) without holding an append target open.

- **Session start:** validate the final path and parent — non-existent target,
  safe parent per `PrivateDirectory`, physically distinct from the captured
  trace directory, the captured inspection artifact, and `--session-trace-dir`.
  Create nothing. This catches deterministic setup problems only; it does not
  guarantee publication succeeds.
- **During:** append to a bounded in-memory buffer; exceeding the ceiling fails
  the session closed.
- **At close:** encode, validate, write a private temporary sibling, `fsync`,
  link no-clobber, sync the directory, unlink the temporary.
- **On crash:** nothing published, no discoverable temporary, records lost —
  the same trade `InspectionArtifact` already makes.

Reachable states: `not_requested`, `written`, `failed`, and
`finalization_uncertain` (link succeeded, directory sync or unlink unproven).
`recovery_written` does not apply because no artifact persists before close.

Publish the **sink first, the session trace last**, so the canonical trace stays
the authoritative completion marker.

## Seam C — close and halt reporting

**`session-closed` is not emitted on close failure.** `finish_profile_session/4`
(`ptc.repl.ex:668`) presents it only on `{:ok, info}`; `close_profile_session/1`
retries once then yields `{:error, reason}` → `command_error`. A declared
`failed` or `finalization_uncertain` state would never reach the caller.
`AnalysisSession.close/1` must return structured failure information, and the
frontend must emit an error-status `session-closed` before `command_error`.

**The session owner never learns the frontend halted.** With `continue_on_error`
forbidden, `run_profile_sources/5` halts on the first error while the session
sees an ordinary close. Persisting "stopped at evaluation N" needs a seam that
does not exist — `AnalysisSession.close(session, halted_at: index)` or a
separate call before close.

`continue_on_error` stays `:forbidden`. Why the private profile forbids it while
`log-analysis` allows `:repeated_eval_only` is not recorded anywhere, and
relaxing an unexplained restriction is how the first draft went wrong.

## Frontend

`--private-sink PATH`, valid only with a private analysis profile.

| Axis | Terminal | Sink |
| --- | --- | --- |
| `input_modes` | `[:interactive]` | `[:eval, :load, :script, :stdin]` |
| `output_formats` | `[:clojure]` | `[:jsonl]` |
| `continue_on_error` | `:forbidden` | `:forbidden` |

`[:jsonl]` is unconditional — with the value suppressed, Clojure mode prints
almost nothing. **Because `clojure` is the default, `--private-sink` without
`--format jsonl` fails**; documented, not accidental. Rejection precedes path
validation, source capture, and session construction.

Put a **record-local** discriminator, `result_projection: "private-split-v1"`,
on every evaluation record. `private_destination` on `session-started` alone
leaves a line-oriented consumer unable to tell which `result` variant it holds.
Keep `schema_version: 1`; no consumer has parsed a sink session.

## Versioning

`inspection-analysis-v3` — result policy, input modes, output behaviour, and the
published frontend contract all change. Retain `v2`; a terminal-only profile
still serves hosts that refuse unattended extraction, and deleting it is a
separate policy decision.

## Repository default

A caller-authored "this run is a fixture" bit is an assertion by the party
seeking the exemption, and credential-free does not imply public. A legitimate
public-fixture path would be a separate code-owned profile over immutable,
digest-pinned, publicly classified resources.

The default belongs in tooling: a helper that records `--trace` and `--inspect`
and opens the private profile with `--private-sink` and `--format jsonl` already
wired, so the safe invocation is the short one.

## Verification

Failing test first.

- **Projection:** the private record carries the unredacted `details.message`
  while the safe projection carries `"private evaluation failed"`.
- **Closed shapes:** out-of-enum `kind`, `reason`, `outcome`, or
  `continuation_effect` is rejected.
- **Leakage, asserted on captured output:** stdout and stderr carry no
  `formatted`, `value`, `prints`, or unredacted message — across success,
  evaluation error, contract violation, buffer overflow, halted session, close
  failure, and crash reports.
- **Format:** `--private-sink` without `--format jsonl` fails before capture or
  session construction.
- **Destination:** reject an existing final path, symlinked leaf, FIFO, device,
  `/dev/fd` alias, collision with stdin/stdout/stderr, a path inside the
  captured input tree, and a path equal to `--session-trace-dir`.
- **Close and halt reporting:** forced publication failure yields an
  error-status `session-closed` carrying `failed`; a session halted at
  evaluation N records N.
- **Ordering:** a sink written with a later trace failure is reportable; the
  reverse is impossible.
- **Correlation preserved:** malformed, replaced, uncorrelated, and oversized
  input reject through the sink path exactly as through the terminal path.
- **Viewer unchanged:** the existing Viewer REPL and inspection API keep working
  through the refactored authorization.
- **End-to-end:** reproduce the per-turn account of an incident-compiler run
  entirely through the CLI profile.

## Order

1. Record the trust decision in `InspectionAnalysisProfile`'s moduledoc.
2. Refactor `authorize_private_profile/2` to a destination check with the
   terminal as the only initially-registered destination. **No behaviour
   change**; the Viewer and CLI both keep working. This is the refactoring step
   and it is independently verifiable.
3. Define the safe projection, private record, discriminator, and sink states.
4. Split the projection inside `AnalysisSession`; add the close and halt seams.
5. Implement the sink artifact with its tests, modelled on
   `InspectionArtifact`'s build-validate-write-link sequence.
6. Register the sink as a destination; `v3`, retaining `v2`.
7. CLI routing, format restriction, end-to-end leakage tests.
8. Helper and documentation.

Step 2 is the answer to "is refactoring needed first" — yes, and it is a
behaviour-preserving step that can land on its own.

## Open questions

- **Should `authorize_frontend/2` become shared rather than CLI-only?** The
  Viewer ignoring the frontend contract is the deeper inconsistency. Fixing it
  is larger than this change and may belong in its own plan.
- **`close/1` arity versus a separate halt call** for the halt seam.
- **Sink byte ceiling** — the buffer holds every evaluation's private record,
  strictly larger than any single result.

## Related documents

- [`agent-developer-findings.md`](agent-developer-findings.md) — finding 6.
- [`stable-cli-contract.md`](stable-cli-contract.md) — `mix ptc.repl` is outside
  its command set, so this work has no sequencing dependency on it.
- [`../../trace-log-contract.md`](../../trace-log-contract.md) — normative for
  private record shapes, correlation, validation, and fail-closed capture.
- `ptc_viewer/`, `lib/ptc_runner/kernel/viewer_adapter.ex`, and
  `viewer_repl_session_worker.ex` — the existing non-interactive paths. Any
  claim that private records are unreachable, or that the session machinery
  needs a terminal, must be checked against these first.
