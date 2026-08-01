# Non-interactive private inspection analysis

**Status:** design, third revision, 2026-08-01. No implementation started.
Addresses finding 6 of [`agent-developer-findings.md`](agent-developer-findings.md).

Two earlier drafts were structured as a blocker list with proposed resolutions,
and both failed independent review the same way: each resolution was a plausible
sentence that the implementation contradicted. "Route `error.message` to the
sink" — already redacted before the frontend sees it. "Buffer records and write
them as the session runs" — buffering and streaming are different designs.
"Matches `InspectionArtifact`" — that module does not hold an append target
open. "`session-closed` carries the state" — it is not emitted when close fails.

This revision is organised around the three seams the change actually touches,
because that is where the previous drafts went wrong.

## Problem

`inspection-analysis-v2` is the only validated reader of private inspection
artifacts, and only a human at an attached terminal can drive it:

```elixir
# lib/ptc_runner/kernel/inspection_analysis_profile.ex:108
def frontend do
  %{
    input_modes: [:interactive],
    output_formats: [:clojure],
    continue_on_error: :forbidden,
    private_terminal: :required
  }
end
```

An agent investigating a run therefore cannot use the profile that validates
private records against the canonical trace. It reads the raw
`.inspection.jsonl` instead and gets the same bytes with no integrity guarantee.

Demonstrated: the profile refused a non-interactive invocation, the artifact was
read directly with Python, and every private fact was recovered anyway.

**That evidence is narrower than it looks.** It shows one process in one
development environment already had filesystem authority. It does not show the
gate is worthless — the gate still requires a conscious interactive action,
prevents unattended extraction, and keeps private values out of CI logs, pipes,
and transcripts. `--private-sink` does not restore "a destination the operator
chose" either; an automated caller can pass the flag itself.

**The justification is integrity and ergonomics only:** for callers already
trusted with direct read access, the terminal requirement pushes them onto an
unvalidated path. Adding a sink does not recover auditing as a security
property, because bypassing the profile stays possible. It makes the validated
route usable.

## Trust boundary

**Same-UID processes are trusted.** Confirmed by the maintainer, 2026-08-01.

The previous draft grounded this by citing `stable-cli-contract.md`'s non-goal
"an adversarial same-user/same-VM security boundary." That was overstated: that
document is itself a disposable plan and its non-goal is scoped to the
standalone CLI, so it is evidence of intent, not a durable contract for
`mix ptc.repl`. **This decision must be recorded in `InspectionAnalysisProfile`'s
moduledoc**, which is durable, as part of the work.

Consequences:

- `PrivateDirectory`'s pathname preflight is adequate; `openat2`-class
  descriptor discipline is not required. Post-open `fstat` checks stay as
  protection against operator mistakes — a path that is a FIFO, a device, or an
  alias for stdout — not against a racing adversary.
- `0600` protects against other UIDs, not against same-UID processes.
- A host needing to refuse unattended private extraction keeps a terminal-only
  profile. That is now the only remaining purpose of the gate, and the reason
  `v2` is retained rather than deleted.

## Seam A — the projection boundary

`AnalysisSession.project_result/2` (`analysis_session.ex:335`) turns a detailed
evaluation result into the public projection the frontend receives. Two facts
make this the correct split point, and both invalidate the earlier design that
split in the frontend:

1. `error_message/2` (`analysis_session.ex:485`) replaces the message with the
   constant `"private evaluation failed"` whenever
   `result_data_class != "normal"`. Splitting after projection would write that
   constant to the sink. The real bounded text is in `detailed.details.message`.
2. Splitting later means the frontend receives private content and is trusted
   not to print it. Under a sink the frontend is exactly the component that
   stopped being trustworthy for that.

**Design:** under a private destination, `project_result/2` returns
`{safe_projection, private_record}`. The private record is built from the
detailed result *before* redaction. The frontend never receives private content
for a sink session.

### The safe projection

Constructed explicitly and validated — **not** `json_projection/1` over a key
list. A generic pass-through turns a future producer change into a silent leak.

| Field | Source | Constraint |
| --- | --- | --- |
| `status` | result | closed enum |
| `outcome` | result | closed enum |
| `evaluation_id` | result | opaque id |
| `duration_ms` | result | integer |
| `continuation_effect` | result | closed enum: `committed_with_history`, `committed_without_history`, `preserved` (`evaluation.ex:340`) |
| `usage` | session | counts and byte totals only |
| `value_available` | derived | boolean |
| `formatted_truncated`, `prints_truncated` | derived | boolean |
| `error.kind`, `error.reason` | error projection | closed enums |
| `error.capability_activity?`, `error.capability_failure?`, `error.retryable?` | error projection | boolean |

The last row was missing from the previous draft, which silently dropped three
fields the projection already produces (`analysis_session.ex:471`).

Validation must reject an out-of-enum `kind`, `reason`, `outcome`, or
`continuation_effect` rather than passing it through.

### The private record

`evaluation_id`, `formatted`, `value`, `prints`, and the **unredacted** bounded
`details.message`. Joined to the safe stream on `evaluation_id`, which is
already present and is the same key that makes turn correlation work.

### Metadata that stays on stdout, deliberately

`value_available`, the truncation flags, `duration_ms`, and `usage` counters
disclose presence, size thresholds, timing, and activity. These are side
channels, not content, and they are **accepted** — they are what makes the safe
stream useful at all. `session-closed`'s `trace_path` is a host path and is
likewise accepted as intentional CLI metadata. Stating this explicitly is the
point; an unqualified "stdout contains nothing private" is the claim that failed
review twice.

## Seam B — the sink artifact

**Buffer in memory; build, validate, and publish one complete artifact at
close.** This is a choice between three coherent designs, and the previous draft
blended them:

1. buffer and publish at close;
2. integrate each write into the evaluation commit protocol;
3. accept post-commit write failure and report that exact state.

Choosing (1) removes per-evaluation disk I/O entirely, so there is no write that
can fail after continuation commit. The earlier "write to a staging file as the
session runs" was (2) or (3) wearing (1)'s claims.

This now genuinely matches `InspectionArtifact`, which constructs and validates a
complete encoded artifact, writes it to a temporary file, and links it
(`inspection_artifact.ex:579`). It does not hold an append target open, and
neither does this.

**Session start:** validate the final path and its parent — non-existent target,
safe parent per `PrivateDirectory`, physically distinct from the captured trace
directory, the captured inspection artifact, and `--session-trace-dir`. Do not
create anything. This catches deterministic setup problems; it does **not**
guarantee the later publication succeeds, and the plan no longer claims it does.

**During the session:** append records to a bounded in-memory buffer. Exceeding
the ceiling fails the session closed, consistent with capture being either
disabled or required/fail-closed.

**At close:** encode, validate, write a private temporary sibling in the target
directory, `fsync`, link no-clobber to the final name, sync the directory,
unlink the temporary.

**On crash before close:** nothing is published and no temporary survives in a
discoverable state. The session's private records are lost. This is the answer
to the question the previous draft left open in two contradictory places, and it
matches what `InspectionArtifact` already does.

Because no artifact persists before close, `recovery_written` does not apply.
The reachable states are `not_requested`, `written`, `failed`, and
`finalization_uncertain` — the last only when the link succeeded but the
directory sync or temporary unlink cannot be proven.

### Two-artifact ordering

The session trace and the private sink cannot be published atomically together.
Publish the **sink first, the session trace last**, so the canonical trace
remains the authoritative marker that a session completed. A sink without a
trace is possible and must be reportable; a trace implying a sink that was never
written is not.

## Seam C — close and halt reporting

Two gaps make the states above unobservable exactly when they matter.

**`session-closed` is not emitted on close failure.** `finish_profile_session/4`
(`ptc.repl.ex:668`) calls `present_profile_closed` only on `{:ok, info}`;
`close_profile_session/1` retries once and otherwise yields `{:error, reason}`,
which produces `command_error`. A declared `failed` or `finalization_uncertain`
sink state would never reach the caller.

**Required:** `AnalysisSession.close/1` returns structured information on
failure, and the frontend emits an error-status `session-closed` carrying both
artifact states *before* `command_error`.

**The session owner does not know the frontend halted.** With
`continue_on_error` forbidden, `run_profile_sources/5` halts on the first error,
but the session sees an ordinary evaluation followed by an ordinary close. There
is no seam through which "the session stopped at evaluation N" can reach the
artifact.

**Required:** the frontend passes a halt outcome into the session before close —
`AnalysisSession.close(session, halted_at: index)` or equivalent — and the sink
records it. Without this seam the halt state cannot be persisted at all.

`continue_on_error` itself stays `:forbidden`. Why the private profile forbids
it while `log-analysis` allows `:repeated_eval_only` is not recorded anywhere,
and relaxing an unexplained restriction is how the first draft went wrong.

## Frontend and authorization

`--private-sink PATH` on `mix ptc.repl`, valid only with a private analysis
profile. Authorization becomes "a private destination is authorized" — attached
terminal or sink, exactly one. Both is an error; neither keeps today's
`private_terminal_required`.

| Axis | Terminal | With `--private-sink` |
| --- | --- | --- |
| `input_modes` | `[:interactive]` | `[:eval, :load, :script, :stdin]` |
| `output_formats` | `[:clojure]` | `[:jsonl]` |
| `continue_on_error` | `:forbidden` | `:forbidden` |

`[:jsonl]` is unconditional. With the value suppressed, Clojure mode prints
almost nothing, and defining semantics for it invents a format with no users.
**Because `clojure` is the default format, `--private-sink` without
`--format jsonl` fails** — documented, not accidental. Rejection must occur
before path validation, source capture, and session construction.

### Record shape discrimination

`private_destination: "sink"` on `session-started` is not sufficient: a
line-oriented JSONL consumer reading one `evaluation` record cannot tell which
`result` variant it holds. Put a **record-local** discriminator —
`result_projection: "private-split-v1"` — on every evaluation record. Keep
`schema_version: 1`; no consumer has ever parsed a sink session, so nothing
regresses.

## Versioning

`inspection-analysis-v3`. The result policy changes, admitted input modes
change, output behaviour changes, the published frontend discovery contract
changes, and unattended private-query authority is added — all four triggers in
`kernel-maintainer.md`.

Retain `v2`. Deleting it is a separate policy decision; a terminal-only profile
still serves hosts that refuse unattended extraction.

## Repository default

Unchanged and independently confirmed: a caller-authored "this run is a fixture"
bit is an assertion by the party seeking the exemption, and credential-free does
not imply public. A legitimate public-fixture path would be a separate
code-owned profile over immutable, digest-pinned, publicly classified resources
— a different authority recipe, not an exemption.

The default belongs in tooling: a helper that records `--trace` and `--inspect`
and opens the private profile with `--private-sink` and `--format jsonl` already
wired, so the safe invocation is the short one. Documentation follows the
helper.

## Verification

Failing test first, per the repo's testing rule.

- **Projection:** the private record carries the unredacted
  `details.message` while the safe projection carries `"private evaluation
  failed"` — the specific defect that made the previous design useless.
- **Closed shapes:** an out-of-enum `kind`, `reason`, `outcome`, or
  `continuation_effect` is rejected, not passed through.
- **Leakage, asserted on captured output:** stdout and stderr contain no
  `formatted`, `value`, `prints`, or unredacted message — across success,
  evaluation error, contract violation, buffer overflow, halted session, close
  failure, and VM crash reports.
- **Format:** `--private-sink` without `--format jsonl` fails before staging,
  capture, or session construction.
- **Destination:** reject an existing final path, a symlinked leaf, a FIFO, a
  device, a `/dev/fd` alias, a path colliding with stdin/stdout/stderr, a path
  inside the captured input tree, and a path equal to `--session-trace-dir`.
  Assert on the opened object.
- **Close reporting:** a forced publication failure produces an error-status
  `session-closed` carrying `failed`, ahead of `command_error`.
- **Halt reporting:** a session halted at evaluation N records N in the sink.
- **Crash:** a kill before close leaves no final artifact and no discoverable
  temporary.
- **Ordering:** a sink written with a subsequent trace failure is reportable;
  the reverse is impossible.
- **Correlation preserved:** malformed, replaced, uncorrelated, and oversized
  input reject through the sink path exactly as through the terminal path. This
  is the point of the change.
- **End-to-end:** reproduce the per-turn account of an incident-compiler run
  entirely through the profile, with no direct artifact reads.

## Order

Schemas and lifecycle before implementation — the artifact's API depends on
both.

1. Record the trust decision in `InspectionAnalysisProfile`'s moduledoc.
2. Define the safe projection, private record, evaluation-record discriminator,
   and the closed set of sink states.
3. Define the full lifecycle: buffer admission, overflow, ordinary close,
   frontend halt, abort, deadline close, owner crash, link collision, sync
   uncertainty, idempotent close retry, temporary cleanup, and two-artifact
   ordering.
4. Implement the sink artifact with its tests, modelled on
   `InspectionArtifact`'s build-validate-write-link sequence.
5. Split the projection inside `AnalysisSession`; add the close and halt seams.
6. Destination-based authorization and `v3`, retaining `v2`.
7. CLI routing, format restriction, and end-to-end leakage tests.
8. Helper and documentation.

Tests accompany each step rather than a single pass at the end.

## Open questions

- **Should `AnalysisSession.close/1` grow an arity, or should halt metadata
  arrive through a separate call before close?** Both work; the former is fewer
  round trips, the latter avoids changing a public signature.
- **Does the sink need its own byte ceiling, or does the existing analysis
  result limit suffice?** The buffer holds every evaluation's private record,
  which is strictly larger than any single result.

## Related documents

- [`agent-developer-findings.md`](agent-developer-findings.md) — finding 6.
- [`stable-cli-contract.md`](stable-cli-contract.md) — owns the standalone CLI
  surface. `mix ptc.repl` is outside its command set, so this work has no
  sequencing dependency on it.
- [`../../trace-log-contract.md`](../../trace-log-contract.md) — normative for
  private record shapes, correlation, validation, and fail-closed capture.
- [`../../guides/kernel-repl.md`](../../guides/kernel-repl.md) — documents the
  current private-profile invocation.
