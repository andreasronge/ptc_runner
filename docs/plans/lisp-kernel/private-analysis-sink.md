# Non-interactive private inspection analysis

**Status:** plan, revised 2026-08-01 after an independent adversarial review that
found three blocking defects in the first draft. No implementation started.
Addresses finding 6 of [`agent-developer-findings.md`](agent-developer-findings.md).

The first draft argued that the interactive-terminal gate on
`inspection-analysis-v2` provides no confidentiality and could be replaced by an
owner-only sink file. That argument was overstated, its central invariant was
false against the current frontend, and two of its factual claims about existing
code were wrong. This revision narrows the justification, records the blockers,
and puts the threat-model decision first because everything else depends on it.

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

`AnalysisProfileRegistry.authorize_frontend/2` enforces it. Any non-interactive
invocation fails with `selected profile is interactive-only`.

The cost is that a coding agent investigating a run cannot use the profile that
validates private records against the canonical trace — correlation checks,
one-input-one-output per capability ID, one source per evaluation ID, and
rejection of malformed, replaced, uncorrelated, or oversized input. It reads the
raw `.inspection.jsonl` instead and gets the same bytes with no integrity
guarantee.

### What the evidence actually shows

Verified while reconstructing a per-turn account of an incident-compiler run:
the profile refused the non-interactive invocation, the artifact was read
directly with Python, and every private fact was recovered anyway.

**That proves less than the first draft claimed.** It shows that *one* process in
*one* development environment already had filesystem authority over the artifact.
It does not show that every caller authorized to invoke `ptc.repl` can read it.

The terminal requirement still provides real controls:

- it requires a conscious interactive action;
- it prevents unattended and large-scale extraction;
- it prevents a caller that can invoke a command but cannot read arbitrary host
  files from turning the profile into a private-data oracle;
- it reduces accidental propagation into CI logs, pipes, command capture, and
  agent transcripts.

Nor does `--private-sink` preserve "a destination the operator chose." An
automated caller can pass the flag itself; explicit syntax is not evidence of
human intent.

**The defensible argument is narrower:** for callers *already* trusted with
direct read access to both artifacts, the terminal requirement discourages
validated analysis and encourages unsafe parsing. This is an integrity and
ergonomics change, not proof that the gate is worthless. Adding a sink also does
not recover auditing as a security property — a caller can still bypass the
profile entirely. It only makes the validated route usable.

## Decision 1: the threat model (blocks everything else)

**Are same-UID processes inside the trust boundary?** The first draft never
asked, and was incoherent as a result: it used same-UID filesystem access to
dismiss the terminal gate, then treated `0600` as protection against those same
processes.

| | Same-UID trusted | Same-UID untrusted |
| --- | --- | --- |
| Sink implementation | ordinary create-exclusive plus `fstat` checks | descriptor-relative `openat`/`openat2`, `O_NOFOLLOW`, `O_CLOEXEC`, post-open identity validation |
| `PrivateDirectory` preflight | adequate | insufficient — see below |
| Confidentiality claim | the gate adds little against same-UID; ergonomics argument stands | the gate is load-bearing and a sink weakens it |
| Brokered-agent hosts | out of scope | in scope, and the sink is a private-data oracle for them |

**Recommendation: treat same-UID processes as trusted**, and state it explicitly
in the profile documentation. A same-UID process can already read the artifact,
attach to the VM, and read the terminal's own output. Defending against it while
handing it a CLI that prints private values is theatre.

**The consequence is binding:** with that answer, the confidentiality
justification for relaxing the gate is dropped entirely. The change is justified
only as integrity plus ergonomics, and hosts that need to refuse unattended
private extraction must retain a terminal-only profile (see versioning below).

If the answer is instead "untrusted," this plan needs a different sink
implementation than the one below, and probably should not proceed at all —
because the same-UID reader it is designed to serve is the thing being defended
against.

## Blockers found in review

### 1. The stdout invariant is false today

The first draft asserted stdout would carry "only safe analysis-trace records."
It would not. `present_profile_result/4` in `lib/mix/tasks/ptc.repl.ex`:

```elixir
if output_format(opts) == :jsonl do
  emit_jsonl(%{..., "result" => json_projection(result)})
else
  Enum.each(result.prints, fn print -> Mix.shell().info(print) end)
  if is_binary(result.formatted), do: Mix.shell().info(result.formatted)
  if result.status == :error, do: Mix.shell().error(format_profile_error(result))
end
```

Both formats put the evaluation result on stdout. Analysis sessions deliberately
use the *preserving* `:public` projection — `Evaluation`'s moduledoc: "Code-owned
analysis sessions opt into the preserving `:public` projection because their
trusted frontend formats an Elixir observation." The trusted frontend is exactly
what a sink would stop being.

"Analysis-trace records" was also an invented abstraction. The task emits CLI
lifecycle records (`session-started`, `evaluation`, `session-closed`).

**Required:** a private record schema for the sink *and* a separate safe
projection for stdout and stderr, covering errors, exceptions, Logger output,
and crash reports — not just the success path. `--format clojure` under a sink
needs defined semantics or must be refused, since suppressing private output
leaves almost nothing to print.

### 2. Fail-closed sink writes conflict with continuation commit

The frontend receives a result *after* evaluation and continuation processing.
If the sink write fails there and the evaluation is reported as failed, that is
dishonest: definitions and `*1`/`*2`/`*3` history have already committed.

**Required:** the private write participates in the evaluation transaction —
produce candidate result and continuation, durably stage the private record,
commit continuation and history only after the write is acknowledged, then
return the safe projection. Crash points between those steps need defined
recovery states. This is not CLI plumbing.

### 3. `PrivateDirectory` does not reject symlinked parents

The first draft claimed it did. It does not — `resolve_components/4` *follows*
symlinks that pass `safe_symlink(stat, uid)`, and its pathname walk is separate
from the later create and open, leaving a rename/retarget window.

Under the recommended trust model this is acceptable. Under "same-UID
untrusted" it is not, and pathname preflight cannot be the authorization
boundary.

## Proposal

### `--private-sink PATH`

A new option on `mix ptc.repl`, valid only with a private analysis profile.

- **Reject every existing destination.** Create once with `O_EXCL` and an
  explicit `0600` mode in the open call — never create permissively and `chmod`
  after. Retain the descriptor for the whole session. Set close-on-exec.
- After opening, `fstat` and verify: regular file, expected owner and exact
  mode, expected device and inode, link count 1. Reject FIFOs, sockets, devices,
  and `/dev/fd`-style aliases based on the opened object, not string matching —
  a FIFO can block the VM or stream to a waiting reader.
- Compare the descriptor's identity against stdin, stdout, stderr, the captured
  trace directory, the captured inspection artifact, and `--session-trace-dir`.
  Refuse any collision.
- Fail-closed, and transactional per the blocker above.

Rejecting existing files removes most of the dangerous cases at once: hard links
to unrelated sensitive files, another process holding the file open, stdout
already pointing at the same inode, interleaved sessions, and ambiguous
ownership of prior contents.

### Authorization becomes a destination check

Replace the terminal-only rule with "a private destination is authorized," of
which an attached terminal is one form and a sink is the other. Exactly one must
be present; supplying both is an error, since two destinations for private
values is precisely the ambiguity worth refusing. Neither keeps today's
`private_terminal_required`.

### Frontend widens only under a sink

| Axis | Terminal | With `--private-sink` |
| --- | --- | --- |
| `input_modes` | `[:interactive]` | `[:eval, :load, :script, :stdin]` |
| `output_formats` | `[:clojure]` | `[:jsonl]`, or `[:clojure, :jsonl]` if Clojure-under-sink gets defined semantics |
| `continue_on_error` | `:forbidden` | `:forbidden` (unchanged) |

### Durability: atomic publication, not append

The first draft left this open. It should not be. The existing inspection
artifact validates the complete batch and publishes atomically with a no-clobber
link, and the contract requires capture to be disabled or fail-closed with no
silent partial state. An appended sink admits a torn final record, a private
record whose continuation never committed, a committed evaluation whose record
was not durable, and a valid prefix mistaken for a complete session.

**Use bounded staging plus atomic final publication**, matching the existing
artifact. If per-evaluation crash recovery is later required, add explicit
incomplete/final states, record framing or checksums, file and directory
synchronization, and deterministic valid-prefix rules — as a separate decision.

Also specify: aggregate sink byte ceilings, short-write and disk-full behaviour,
retention and deletion policy, schema versioning, and session correlation IDs.

## Versioning

This is `inspection-analysis-v3`, not a digest move. Per the rule in
`kernel-maintainer.md`: the result policy changes, admitted input modes change,
output behaviour changes, the published frontend discovery contract changes, and
unattended private-query authority is added.

**Keep `v2` rather than deleting it.** The first draft folded deletion into the
bump on 0.x grounds. 0.x permits deletion; it does not make deletion desirable.
A terminal-only profile remains useful to hosts that intentionally refuse
unattended private extraction — which, under the recommended trust model, is the
only remaining reason the gate exists. Retiring it is a separate decision that
should not ride along on a mechanical version bump.

## Making it the default for this repository's examples

Unchanged from the first draft, and independently confirmed in review.

A manifest or host-config bit saying "this run is only a fixture" is not
provenance — it is an assertion by the party seeking the exemption. Repository
location is not provenance either. "Credential-free" does not imply public:
inputs, model output, local paths, generated source, and capability results can
all still be sensitive.

A legitimate public-fixture path would be a *separate code-owned profile* over
immutable, digest-pinned, publicly classified resources with a result policy
designed for public output — a different authority recipe, not an exemption from
this profile's private-data rule.

So the default belongs in tooling: a `scripts/analyze-example.sh` (or
`mix ptc.analyze_example`) that records `--trace` and `--inspect` and opens the
private profile with `--private-sink` already wired, making the safe invocation
shorter than the unsafe one. Documentation follows the helper; `AGENTS.md` gains
at most one clause on the existing debugging bullet.

## Verification

A failing test first, per the repo's testing rule. Then, beyond intent-level
cases:

- **Authorization:** sink alone succeeds; terminal alone succeeds; both together
  fail; neither fails.
- **Leakage, asserted on captured output rather than intent:** with a sink,
  stdout *and stderr* contain no evaluated source, returned private value,
  prints, or REPL history — across Clojure mode, JSONL mode, evaluation errors,
  contract violations, sink write failures, and VM crash reports.
- **Destination safety:** refuse an existing file, a symlink at the leaf, a
  FIFO, a device, a `/dev/fd` alias, a path colliding with stdin/stdout/stderr,
  a path inside the captured input tree, and a path equal to
  `--session-trace-dir`. Assert on the opened object, not the pathname.
- **Transactional commit:** a sink write failure leaves continuation and history
  unchanged, and the reported outcome matches what actually committed.
- **Crash states:** a kill between staging and publication leaves no
  partially-valid sink that a reader would mistake for a complete session.
- **Correlation preserved:** malformed, replaced, uncorrelated, and oversized
  input reject through the sink path exactly as through the terminal path. This
  is the point of the change and needs direct coverage.
- **End-to-end:** reproduce the per-turn account of an incident-compiler run
  entirely through the profile, with no direct artifact reads.

## Order

The first draft's "plumbing first; nothing observable changes" was wrong —
option parsing, path validation, help text, and error behaviour are all
observable.

1. **Answer Decision 1** and record it in the profile documentation.
2. Resolve the private-artifact state vocabulary against
   [`stable-cli-contract.md`](stable-cli-contract.md), which already defines
   `recovery_written` and `finalization_uncertain`. Adopt it rather than
   inventing a parallel one.
3. Specify the sink record schema, the safe stdout/stderr projection, bounds,
   correlation, the transactional commit point, and publication semantics.
4. Implement and adversarially test the sink artifact on its own.
5. Integrate the write into evaluation/continuation commit.
6. Add destination-based authorization and introduce `v3`, retaining `v2`.
7. Full leakage and race test pass.
8. Only then the example helper and documentation.

## Open questions

- **Clojure-under-sink semantics.** Either define what stdout shows when the
  formatted value is private, or restrict a sink session to `jsonl`. Leaving it
  undefined is how the first draft's stdout claim slipped through.
- **Per-evaluation recovery.** Atomic publication at session close is the
  starting position; whether a long session needs durable per-evaluation records
  is a real question with a real cost.

## Related documents

- [`agent-developer-findings.md`](agent-developer-findings.md) — finding 6.
- [`stable-cli-contract.md`](stable-cli-contract.md) — owns the CLI surface and
  the private-artifact state vocabulary.
- [`../../trace-log-contract.md`](../../trace-log-contract.md) — normative for
  private record shapes, correlation, validation, and fail-closed capture.
- [`../../guides/kernel-repl.md`](../../guides/kernel-repl.md) — documents the
  current private-profile invocation.
