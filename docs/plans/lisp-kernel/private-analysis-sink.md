# Non-interactive private inspection analysis

**Status:** plan; written 2026-08-01 on branch
`worktree-incident-evidence-compiler`. No implementation started. Resolves
finding 6 of [`agent-developer-findings.md`](agent-developer-findings.md).

## Problem

`inspection-analysis-v2` is the only validated reader of private inspection
artifacts, and it can only be driven by a human at an attached terminal:

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

`AnalysisProfileRegistry.authorize_frontend/2` enforces it: `authorize_input/2`
rejects `-e`, `--load`, a script, and stdin; `authorize_output/2` rejects
`--format jsonl`; and `authorize_terminal/3` requires both the explicit
`--private-terminal` flag and a genuinely attached terminal. Any non-interactive
invocation fails with `selected profile is interactive-only`.

### The gate does not contain the access

This was verified this session while producing a per-turn account of an
incident-compiler run. The sanctioned path refused:

```console
$ mix ptc.repl --profile inspection-analysis-v2 \
    --resource traces=tmp/demo \
    --resource inspection=tmp/demo/run.inspection.jsonl \
    -e '(inspection/runs {})'
** (Mix) selected profile is interactive-only
```

So the artifact was read directly with a Python one-liner instead, and every
private fact — model prose, generated programs, capability arguments and
results — was recovered anyway. The file is `0600`, and the reader already owns
it.

**What the gate actually costs is validation, not secrecy.** The profile
validates private records against the corresponding canonical run before
exposing them: malformed, replaced, uncorrelated, or oversized input rejects the
whole source, and there is at most one input and one output per capability ID
and one source per evaluation ID. Reading the raw file skips all of that. An
agent that cannot use the profile does not get less private data — it gets the
same data with no integrity guarantee, and the runtime loses its record that the
read happened.

This is the inverse of the intended property, and it is the whole argument for
the change.

## What the terminal requirement is really protecting

Not "a human must see this." An attached interactive terminal is a proxy for
**the destination of private values is a place the operator chose and can see,
rather than a redirected pipe, a CI log, or a file a background process picked.**

That property is preservable without a terminal. Name the destination
explicitly, make it owner-only, and keep private values out of stdout.

## Proposal

### 1. `--private-sink PATH`

A new option on `mix ptc.repl`, valid only with a private analysis profile.

- The path must not exist, or must already be a regular owner-only file.
  Creation uses `O_EXCL` with mode `0600`, reusing the `PrivateDirectory`
  parent-safety checks that `--private-output` already applies (no symlinked
  parents, no world-writable ancestors).
- It must be physically distinct from the captured trace directory, the captured
  inspection artifact, and `--session-trace-dir`, under the same
  ancestor/descendant/symlink rules those already enforce.
- Every private value — evaluation results, prints, REPL history — is appended
  there as one JSON object per evaluation.
- **stdout carries only the safe analysis-trace records the profile already
  emits.** These never include evaluated source, returned private values,
  prints, or REPL history.
- Capture is fail-closed, matching `InspectionSink`: if a private value cannot
  be written, the evaluation fails rather than falling back to stdout.

### 2. Authorization becomes a destination check

Replace the terminal-only rule with "a private destination is authorized," of
which an attached terminal is one form and a sink is the other.

```elixir
# authorize_terminal/3 becomes authorize_private_destination/2
%{private_terminal: true, terminal_attached: true, private_sink: nil}   # today
%{private_terminal: false, terminal_attached: false, private_sink: path} # new
```

Exactly one must be present. Supplying both is an error — two destinations for
private values is precisely the ambiguity worth refusing. Supplying neither
keeps today's `private_terminal_required`.

### 3. Frontend widens only under a sink

`frontend/0` stops being a flat map and gains a sink-conditional shape:

| Axis | Terminal | With `--private-sink` |
| --- | --- | --- |
| `input_modes` | `[:interactive]` | `[:eval, :load, :script, :stdin]` |
| `output_formats` | `[:clojure]` | `[:clojure, :jsonl]` |
| `continue_on_error` | `:forbidden` | `:forbidden` (unchanged) |

`continue_on_error` stays forbidden under both. A private session that continues
past an error is a separate decision and is not required by this problem.

### 4. This is `inspection-analysis-v3`

`@result_policy "private-terminal-v1"` describes where results go, and results
can now go somewhere else. By the versioning rule recorded in
`kernel-maintainer.md` — bump the ID when the declared callable surface,
authority, limits, or published behavioral contract changes — this is a profile
ID change, not merely a digest move:

- `result_policy` becomes `private-destination-v1`, which is inside `identity/4`
  and therefore moves the digest regardless;
- `frontend/0` is published through `description/0` and `--describe-profile`, so
  the discovery contract changes;
- the input and output modes a caller may use change.

Rename to `inspection-analysis-v3` and delete `v2`, consistent with the repo's
0.x stance. Note the cost, since #1162 just moved these IDs: every documented
private-analysis command line changes again. That argues for landing this
before more documentation accumulates on `v2`, not after.

## Making it the default for this repository's examples

The requirement is that analyzing this repo's own example programs uses the
non-interactive private path by default.

**It must not be a runtime exemption.** A "this run is only a fixture" bit
carried in a manifest or host config would be caller-authored, and the day it
appears on a real run the gate silently disappears. The runtime should keep one
rule — an authorized private destination exists — with no provenance-based
exceptions and no special-casing of repository paths.

The default belongs in this repository's tooling instead:

1. **A recording-and-analysis helper.** The examples under `examples/`
   (`kernel-tutorial`, `kernel-inspection-lab`, `mcp`, `viewer-demo`) and
   `incident_compiler/` all run credential-free. A `scripts/analyze-example.sh`
   (or a `mix ptc.analyze_example` task) records `--trace` and `--inspect` into
   a scratch directory, then opens the private profile with `--private-sink`
   already wired to a sibling path — so the safe invocation is shorter than the
   unsafe one.
2. **Documentation follows the helper.** `running-and-debugging.md`'s
   "Analyze what the model received and generated" section currently sends
   readers to the Viewer or the interactive REPL. It should show the helper as
   the ordinary path, with the interactive REPL as the alternative for
   exploratory work.
3. **`AGENTS.md` gains at most one clause** on the existing debugging bullet,
   pointing at the same guide section. The file is loaded every session and this
   is rarely needed.

The result is that in this repository the non-interactive path is the default
because it is the documented, scripted, shortest path — while the runtime rule
stays uniform for every host.

## Verification

- A failing test first, per the repo's testing rule: the private profile
  currently refuses `-e` with a sink present.
- Frontend authorization: sink alone succeeds; terminal alone succeeds; both
  together fail; neither fails.
- Sink safety: refuses an existing non-owner-only file, a symlinked parent, a
  path inside the captured input tree, and a path equal to
  `--session-trace-dir`.
- No leakage: with a sink, stdout contains no evaluated source, no returned
  private value, no prints, and no REPL history. Assert on captured stdout
  rather than on intent.
- Fail-closed: a sink write failure fails the evaluation.
- Correlation preserved: the same malformed/replaced/uncorrelated/oversized
  rejections apply through the sink path as through the terminal path — the
  validation is the point of the change.
- End-to-end: reproduce this session's per-turn account of an incident-compiler
  run entirely through the profile, with no direct artifact reads.

## Suggested order

1. `--private-sink` plumbing and safety checks, with the profile still
   interactive-only. Nothing observable changes yet.
2. Destination-based authorization and the conditional frontend; rename to
   `inspection-analysis-v3`.
3. The example helper, the guide rewrite, and the `AGENTS.md` clause.

## Open questions

- **Sink format.** One JSON object per evaluation is the obvious shape, but the
  analysis trace uses atomic publication rather than append. Appending is
  simpler and matches `InspectionSink`; confirm that a partially written sink on
  a crash is acceptable, or reuse atomic publication per evaluation.
- **Sink reuse across sessions.** Appending to an existing owner-only sink from
  a second session mixes two sessions' private values in one file. Refusing an
  existing file is stricter and probably right; it costs a caller one `rm`.
- **Interaction with `stable-cli-contract.md`.** That plan owns the command
  surface and already specifies private-result artifact states
  (`recovery_written`, `finalization_uncertain`). `--private-sink` should adopt
  the same vocabulary rather than inventing a parallel one; sequence
  accordingly.

## Related documents

- [`agent-developer-findings.md`](agent-developer-findings.md) — finding 6 and
  the evidence that the private plane holds the answers.
- [`stable-cli-contract.md`](stable-cli-contract.md) — owns the CLI surface and
  the private-artifact state vocabulary.
- [`../../trace-log-contract.md`](../../trace-log-contract.md) — normative for
  private record shapes, correlation, and validation.
- [`../../guides/kernel-repl.md`](../../guides/kernel-repl.md) — documents the
  current private-profile invocation.
