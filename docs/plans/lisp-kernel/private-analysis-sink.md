# Non-interactive private inspection analysis

**Status:** design, fifth revision, 2026-08-01. No implementation started.
Addresses finding 6 of [`agent-developer-findings.md`](agent-developer-findings.md).

Earlier drafts designed a mechanism that split each evaluation result into a
safe stdout stream and a private sink stream. That generated the entire
complexity — a projection change inside `AnalysisSession`, new record schemas, a
buffered artifact with staging and atomic publication, and new close and halt
reporting seams. This revision moves the whole output stream instead of
splitting it, and most of that work disappears.

Recorded because each was a plausible sentence the code contradicted, and each
survived at least one review: the security justification (the Viewer already
provides validated non-interactive access); "route `error.message` to the sink"
(already redacted); "buffer records and write them as the session runs"
(buffering and streaming are different designs); "matches `InspectionArtifact`"
(it holds no append target open); "`session-closed` carries the state" (not
emitted when close fails).

## What already works

The Viewer serves a bounded `log-analysis-v2` REPL over HTTP with no terminal.
`ViewerReplSessionWorker.run/3` calls the same constructor the CLI uses, with no
options and no frontend authorization:

```elixir
AnalysisSessionBuilder.start(
  LogAnalysisProfile.id(),
  %{"traces" => trace_dir},
  {:directory, trace_dir}
)
```

It works because `log-analysis-v2` declares `private_terminal: :forbidden`.
Sessions, preludes, bounded queries, and pagination are therefore already
non-interactive. **Nothing in the analysis engine needs a terminal.**

## What is wrong

`log-analysis-v2` serves canonical traces through the CLI non-interactively.
`inspection-analysis-v2` refuses the same usage over private records, despite
sharing the builder, the analysis engine, and the prelude layering.

The Viewer's `/api/inspection/runs/:run_id` does return private records
non-interactively and fully validated — `ViewerAdapter.pin_inspection/2` runs
`InspectionArtifact.load/1` and `validate_correlations/2`. But it is a
whole-artifact dump: one `curl` returned 209,833 bytes for a five-turn run, with
no filtering, projection, or pagination. It is a browsing surface. The CLI REPL
is the query surface, and it is the one an agent should use.

**The defect is the asymmetry.** This change grants no access the Viewer does
not already grant.

## Where the gate lives

| Layer | Enforces | CLI | Viewer |
| --- | --- | --- | --- |
| `AnalysisSessionBuilder.authorize_private_profile/2` | `private_terminal: true` **and** `AnalysisTerminal.attached?()` when a profile declares `private_terminal: :required` | passes the flag | never passes it |
| `AnalysisProfileRegistry.authorize_frontend/2` | `input_modes`, `output_formats`, `continue_on_error`, terminal | calls it | **ignores it entirely** |

The builder layer is the real gate — it applies to every caller. The registry
layer is a CLI-only contract the Viewer does not participate in, which is why
the Viewer can serve a REPL the CLI's frontend table would reject.

## Design: a redirected output stream

`--private-output PATH` on `mix ptc.repl`, valid only with a private analysis
profile. The profile session's **entire output stream** — every record, in
whichever format — is written to an owner-only `0600` file. stdout receives the
path and nothing else.

The name is deliberate: `mix ptc.run --private-output PATH` already means
"private values go to this owner-only file instead of stdout", using the same
`PrivateDirectory` validation. Reusing it avoids a parallel vocabulary. The
shape differs — `run` writes one result value, the REPL writes a stream — and
that difference belongs in the docs, not in a second flag name.

Authorization becomes a **private destination** check: an attached terminal or a
private output, exactly one. Both is an error; neither keeps today's
`private_terminal_required`. A host that refuses unattended private extraction
registers no non-interactive destination.

### Why moving the stream is sufficient

The gate exists so private values do not reach a redirected pipe, a CI log, or a
transcript. A named `0600` file preserves that at least as well as an attached
terminal does.

Splitting the stream would additionally let an agent watch safe progress on
stdout while detail lands in the file. Nobody has asked for that, and it can be
added later as a projection increment without redoing this work.

### What is already safe

**stderr needs no change.** `InspectionAnalysisProfile.identity_extension/0`
sets `result_data_class => "private_inspection"`, so
`AnalysisSession.error_message/2` already returns the constant
`"private evaluation failed"` for this profile. `format_profile_error/1` is
therefore already redacted.

**Only two lines emit private content.** `ptc.repl.ex:718-719` writes
`result.prints` and `result.formatted`. Everything else the frontend prints is
profile metadata, the analysis-trace path, or frontend chrome.

## Changes

1. **`AnalysisSessionBuilder.authorize_private_profile/2`** — accept
   `private_output: true` as a second authorized destination beside
   `private_terminal: true`; add it to `@inspection_options`.
2. **`AnalysisProfileRegistry.authorize_frontend/2`** — take the selected
   destination and widen `input_modes` and `output_formats` accordingly.
3. **`lib/mix/tasks/ptc.repl.ex`** — the `--private-output` option; validation
   through the existing `PrivateDirectory` helpers; `O_EXCL` create with an
   explicit `0600` mode; an IO device threaded through the profile
   presentation call sites (`emit_jsonl/1` already funnels through one
   `IO.puts`); print the path on close.
4. **`inspection-analysis-v3`**, retaining `v2`.

Explicitly **not** required: any change to `project_result/2`, new record
schemas or discriminators, a buffered or staged artifact, close-failure or halt
reporting seams, or a format restriction. Both `clojure` and `jsonl` work,
because the destination is a redirect rather than a projection.

### Destination validation

Reuse `PrivateDirectory`'s parent checks. Reject an existing target, a symlinked
leaf, a FIFO, a socket, a device, a `/dev/fd`-style alias, and any path that
resolves to the same object as stdin, stdout, stderr, the captured trace
directory, the captured inspection artifact, or `--session-trace-dir`. Validate
on the opened object with `fstat`, not on the pathname alone.

Under the trust boundary below these are mistake-avoidance checks, not defences
against a racing adversary.

## Trust boundary

**Same-UID processes are trusted.** Confirmed by the maintainer, 2026-08-01.

An earlier draft grounded this by citing `stable-cli-contract.md`'s non-goal
"an adversarial same-user/same-VM security boundary". That was overstated: that
document is a disposable plan scoped to the standalone CLI. **Record the
decision in `InspectionAnalysisProfile`'s moduledoc**, which is durable, as part
of this work.

Consequently `PrivateDirectory`'s pathname preflight is adequate,
`openat2`-class descriptor discipline is unnecessary, and `0600` is documented
as protecting against other UIDs rather than same-UID processes.

## Relationship to `stable-cli-contract.md`

`mix ptc.repl` is outside that plan's command set — it delivers `help`,
`validate`, `run`, `doctor`, `models`, `init`, and `version`, and its own
verification preserves `mix ptc.repl --trace PATH` as a Mix-only spelling. So
there is no conformance requirement and no sequencing dependency.

The `run` envelope's `artifact_state` vocabulary (`recovery_written`,
`finalization_uncertain`) is a closed map over `trace`, `inspection`, and
`result` for a command the REPL does not produce. It does not transfer, and
under this design it is not needed: the private output is a stream, not a
published artifact with a recovery lifecycle.

## Versioning

`inspection-analysis-v3` — the result policy, admitted input modes, output
behaviour, and the published frontend discovery contract all change.

Retain `v2`. A terminal-only profile still serves hosts that refuse unattended
extraction; deleting it is a separate policy decision.

## Repository default

A caller-authored "this run is a fixture" bit is an assertion by the party
seeking the exemption, and credential-free does not imply public. A legitimate
public-fixture path would be a separate code-owned profile over immutable,
digest-pinned, publicly classified resources.

The default belongs in tooling: a helper that records `--trace` and `--inspect`
and opens the private profile with `--private-output` already wired, so the safe
invocation is the short one.

## Verification

Failing test first, per the repo's testing rule.

- **Authorization:** terminal alone succeeds; private output alone succeeds;
  both together fail; neither fails with `private_terminal_required`.
- **No leakage on stdout or stderr:** with a private output, neither carries
  `result.prints`, `result.formatted`, or an unredacted error message — across
  success, evaluation error, contract violation, halted session, close failure,
  and VM crash reports. Assert on captured output, not on intent.
- **Redirection completeness:** every record the session would have printed
  appears in the file, in both `clojure` and `jsonl` formats.
- **Destination safety:** each rejection in the validation list above, asserted
  on the opened object.
- **Correlation preserved:** malformed, replaced, uncorrelated, and oversized
  input reject through this path exactly as through the terminal path. This is
  the point of the change.
- **Viewer unchanged:** the existing Viewer REPL and inspection API keep working
  through the refactored authorization.
- **End-to-end:** reproduce the per-turn account of an incident-compiler run
  entirely through the CLI profile, with no direct artifact reads.

## Order

1. Record the trust decision in `InspectionAnalysisProfile`'s moduledoc.
2. Refactor `authorize_private_profile/2` into a destination check with the
   attached terminal as the only registered destination. **No behaviour
   change**; both frontends keep working. Lands independently.
3. Add `--private-output` with its validation and the redirected device.
4. Register it as a destination; widen the frontend contract; `v3`.
5. Leakage and destination tests.
6. Helper and documentation.

Step 2 is the refactor, and it is separable from everything after it.

## Open questions

- **Should `authorize_frontend/2` become shared rather than CLI-only?** The
  Viewer ignoring the frontend contract is the deeper inconsistency. Larger than
  this change and probably its own plan.
- **Does a redirected stream need a byte ceiling?** stdout has none. A long
  session writing to a file is bounded by disk rather than by policy, which may
  be acceptable or may want the analysis session's existing limits applied.

## Related documents

- [`agent-developer-findings.md`](agent-developer-findings.md) — finding 6.
- [`stable-cli-contract.md`](stable-cli-contract.md) — owns the standalone CLI
  surface; `mix ptc.repl` is outside it.
- [`../../trace-log-contract.md`](../../trace-log-contract.md) — normative for
  private record shapes, correlation, and validation.
- `ptc_viewer/`, `lib/ptc_runner/kernel/viewer_adapter.ex`, and
  `viewer_repl_session_worker.ex` — the existing non-interactive paths. Any
  claim that private records are unreachable, or that the session machinery
  needs a terminal, must be checked against these first.
