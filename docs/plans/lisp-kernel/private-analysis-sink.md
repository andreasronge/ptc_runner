# Non-interactive private inspection analysis

**Status:** plan, revised 2026-08-01 after an independent adversarial review and
a follow-up check against the CLI contract. The threat-model decision is
answered and all five blockers have recommended resolutions. No implementation
started. Addresses finding 6 of
[`agent-developer-findings.md`](agent-developer-findings.md).

The first draft argued that the interactive-terminal gate on
`inspection-analysis-v2` provides no confidentiality and could be replaced by an
owner-only sink file. That argument was overstated, its central invariant was
false against the current frontend, and two of its factual claims about existing
code were wrong. This revision narrows the justification and records what
remains.

All five blockers now carry a recommended resolution. Blocker 2 is reduced
rather than removed: staging plus an atomic final link moves the coupling from
per-evaluation to a single session-scope publication with a declared terminal
state. Blocker 3 is resolved by the threat-model answer. What remains is a
bounded implementation modelled on `InspectionArtifact`, plus the open questions
below.

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

## Decision 1: the threat model — ANSWERED

**Same-UID processes are inside the trust boundary.** Confirmed 2026-08-01, and
it was already repo policy rather than a new decision:
[`stable-cli-contract.md`](stable-cli-contract.md) lists

> an adversarial same-user/same-VM security boundary

among its explicit non-goals. The first draft treated this as open and was
incoherent as a result: it used same-UID filesystem access to dismiss the
terminal gate, then treated `0600` as protection against those same processes.

**Binding consequences:**

- The confidentiality justification for relaxing the gate is dropped. The change
  is justified as integrity and ergonomics only.
- `PrivateDirectory`'s pathname preflight is adequate; `openat2`-class
  descriptor discipline is not required. Post-open `fstat` identity checks stay
  as cheap defence against mistakes, not against an adversary.
- `0600` is documented as protecting against *other* UIDs, not against same-UID
  processes.
- Hosts that must refuse unattended private extraction keep a terminal-only
  profile — which is now the only remaining reason the gate exists, and the
  reason `v2` is retained.

The table below records what the alternative answer would have required, since
a host with a brokered-agent boundary may revisit it.

| | Same-UID trusted | Same-UID untrusted |
| --- | --- | --- |
| Sink implementation | ordinary create-exclusive plus `fstat` checks | descriptor-relative `openat`/`openat2`, `O_NOFOLLOW`, `O_CLOEXEC`, post-open identity validation |
| `PrivateDirectory` preflight | adequate | insufficient — see below |
| Confidentiality claim | the gate adds little against same-UID; ergonomics argument stands | the gate is load-bearing and a sink weakens it |
| Brokered-agent hosts | out of scope | in scope, and the sink is a private-data oracle for them |

The rationale for the answer: a same-UID process can already read the artifact,
attach to the VM, and read the terminal's own output. Defending against it while
handing it a CLI that prints private values is theatre.

Were the answer "untrusted," this plan would need a different sink
implementation and probably should not proceed at all — the same-UID reader it
is designed to serve would be the thing being defended against.

## Impact of `stable-cli-contract.md`

Checked directly. Three findings, one of which removes a dependency the first
draft asserted.

**`mix ptc.repl` is outside the standalone command set.** The delivered commands
are `help`, `validate`, `run`, `doctor`, `models`, `init`, and `version`. The
plan's own verification explicitly preserves `mix ptc.repl --trace PATH` as a
Mix-only spelling while removing `--trace PATH` from `ptc run`. So
`--private-sink` on the REPL does **not** need to conform to the standalone
argv/envelope contract, and does not need to wait for that work. The first
draft's "sequence accordingly" was too strong; the sequencing dependency is
removed.

**The artifact-state vocabulary does not transfer directly.** `recovery_written`
and `finalization_uncertain` are values in the `run` envelope's *closed* map over
`trace`, `inspection`, and `result`. `ptc.repl` emits a different schema —
`session-started`, `evaluation`, `session-closed` at `schema_version: 1`. Adding
a sink state to the run envelope would be a schema change to a closed map for a
command that does not produce it.

Reuse the **durability pattern**, not the state names: a durable recovery
artifact published first, a final link second, and an honest terminal state when
the link or directory sync cannot be proven. Define the state field inside the
REPL's own `session-closed` record.

**The same-UID non-goal** is cited under Decision 1 above.

## Blockers

Items 1-3 came from an independent adversarial review; 4-5 from
inspecting the frontend while answering Decision 1.

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

**Resolution: take the seam the record already has.** The evaluation result
pairs every private field with safe metadata about it — `value` with
`value_available`, `formatted` with `formatted_truncated`, `prints` with
`prints_truncated`. Split there rather than inventing a projection:

| Destination | Fields |
| --- | --- |
| stdout | `status`, `outcome`, `evaluation_id`, `duration_ms`, `continuation_effect`, `usage`, `value_available`, `formatted_truncated`, `prints_truncated`, `error.kind`, `error.reason` |
| sink | `evaluation_id`, `formatted`, `value`, `prints`, `error.message` |

The join key is `evaluation_id`, already present in the record and the same key
that makes turn correlation work. A reader takes the safe stream to learn what
happened and joins the sink for content.

`format_profile_error/1` prints `error.kind` and `error.message || error.reason`
to stderr, so `message` is the one field needing rerouting there; `kind` and
`reason` stay.

**Refuse `--format clojure` under a sink.** With the value suppressed, Clojure
mode prints almost nothing, and defining semantics for it invents a format with
no users — a sink session is machine-driven by definition. Restricting sink
sessions to `jsonl` deletes the question rather than answering it.

Still required: the safe projection must cover exceptions, Logger output, and
crash reports, not only the success and evaluation-error paths.

### 2. Fail-closed sink writes conflict with continuation commit

The frontend receives a result *after* evaluation and continuation processing.
If the sink write fails there and the evaluation is reported as failed, that is
dishonest: definitions and `*1`/`*2`/`*3` history have already committed.

**Resolution: reduce it to one declared failure point.** Write bounded private
records to an owner-only *staging* file as the session runs, and link that
staging file to the final sink path atomically at close.

This does not *dissolve* the problem — an earlier draft of this section claimed
it did, which was wrong. It relocates the coupling from per-evaluation to
session scope, where it becomes a single point with a declared terminal state
rather than a per-evaluation commit ordering. The residual case is real:
evaluations commit, and close-time publication then fails.

That case is exactly what `stable-cli-contract.md`'s `recovery_written` state
describes — the durable artifact exists under its recovery name, the final name
does not. Reuse that shape in the REPL's `session-closed` record so the outcome
is stated rather than inferred. Staging also fails fast: an unusable sink path
is rejected at session start, not after an hour of analysis.

This matches `InspectionArtifact`, which validates a complete batch and
publishes atomically with a no-clobber link. Consequences:

- a crash before close leaves only the staging file, never a final sink that a
  reader could mistake for a complete session;
- the buffer needs a byte ceiling; analysis sessions already carry them, and
  exceeding it fails the session closed, consistent with capture being either
  disabled or required/fail-closed;
- per-evaluation durability is lost on a long session. That is the trade, and
  it is the trade the existing artifact already makes.

If per-evaluation durability is later required, that is a separate decision with
its own state machine — not a prerequisite for this change.

### 3. `PrivateDirectory` does not reject symlinked parents (resolved)

The first draft claimed it did. It does not — `resolve_components/4` *follows*
symlinks that pass `safe_symlink(stat, uid)`, and its pathname walk is separate
from the later create and open, leaving a rename/retarget window.

**Resolved by Decision 1.** With same-UID processes trusted, the preflight is
adequate and the window is not an attack surface. The plan's description of what
`PrivateDirectory` does is corrected; no implementation change is required. Keep
the post-open `fstat` checks as protection against operator mistakes — a sink
path that is a FIFO, a device, or an alias for stdout — rather than against a
racing adversary.

### 4. `continue_on_error: :forbidden` halts the session on the first error

`run_profile_sources/5` reduces with `{:halt, put_failure(...)}` unless
`continue_on_error` is set, and the private profile forbids it. For an agent
running a multi-step `-e` analysis, one malformed form ends the session and
costs a full re-capture of both snapshots.

**Resolution: keep `:forbidden`; publish what was collected, with an explicit
halt state.** Why the private profile forbids continuation while `log-analysis`
allows `:repeated_eval_only` is not recorded anywhere, and relaxing a policy
whose rationale cannot be established is how the first draft went wrong.

On halt, publish the sink with the records collected so far plus a terminal
state naming the evaluation that stopped the session. Partial-but-declared is
not the silent partial state the contract forbids.

The re-capture cost stays. Revisit with evidence if it proves painful, and
record the rationale for `:forbidden` when someone establishes it.

### 5. The `evaluation` record schema is versioned

It is `schema_version: 1` with `result` carrying `json_projection(result)`.
Rerouting private values changes what that field means for sink sessions.

**Resolution: a discriminator, not a version bump.** Keep `schema_version: 1`,
put `"private_destination": "sink"` on the `session-started` record, and
document that a sink session's `evaluation` records omit the private fields
listed under blocker 1.

No consumer regression is possible: non-interactive private sessions do not
exist today, so nothing has ever parsed one. A discriminated closed shape is
also the idiom this repo already uses for tagged results. Bump the version only
when an existing mode's records change.

## Proposal

### `--private-sink PATH`

A new option on `mix ptc.repl`, valid only with a private analysis profile.

- **Reject every existing destination**, both the final path and the staging
  path. Create the *staging* file once with `O_EXCL` and an explicit `0600` mode
  in the open call — never create permissively and `chmod` after. Retain that
  descriptor for the whole session and set close-on-exec. The final path is not
  created until close.
- After opening, `fstat` and verify: regular file, expected owner and exact
  mode, expected device and inode, link count 1. Reject FIFOs, sockets, devices,
  and `/dev/fd`-style aliases based on the opened object, not string matching —
  a FIFO can block the VM or stream to a waiting reader.
- Compare the descriptor's identity against stdin, stdout, stderr, the captured
  trace directory, the captured inspection artifact, and `--session-trace-dir`.
  Refuse any collision.
- Fail-closed, and transactional per the blocker above.

Rejecting existing files removes most of the awkward cases at once: hard links
to unrelated files, another process holding the file open, stdout already
pointing at the same inode, interleaved sessions, and ambiguous ownership of
prior contents. Under Decision 1 these are correctness and mistake-avoidance
concerns rather than adversarial ones — but "create exclusively, never reuse" is
the cheaper rule either way, and it removes the need to reason about which is
which.

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

1. Record Decision 1 in the profile documentation, and confirm the crash-loss
   trade in Open questions. Everything below assumes it.
2. Specify the two record shapes from blocker 1 — the safe stdout/stderr
   projection and the sink record — plus the `private_destination`
   discriminator, buffer ceiling, and the halt state from blocker 4.
3. Implement the sink artifact on its own: create-exclusive with `O_EXCL` and
   explicit `0600`, post-open `fstat` checks, bounded buffer, atomic
   publication at close, modelled on `InspectionArtifact`.
4. Route the frontend through the two shapes and restrict sink sessions to
   `jsonl`.
5. Add destination-based authorization and introduce `v3`, retaining `v2`.
6. Full leakage test pass across stdout, stderr, errors, buffer overflow,
   halted sessions, and crash.
7. Only then the example helper and documentation.

## Open questions

- **Is losing a long session's private records on crash acceptable?** Everything
  above assumes yes, because `InspectionArtifact` already behaves that way. If
  not, per-evaluation durability needs its own state machine and this becomes a
  materially larger change.
- **Should a `recovery_written` staging file survive a failed close, or be
  removed?** Leaving it preserves the data at a path the caller did not ask for;
  removing it destroys evidence of a session that did commit evaluations. The
  `run` envelope answers this for `--private-output`; the REPL should follow the
  same answer rather than pick its own.
- **Why does the private profile forbid `continue_on_error`?** No rationale is
  recorded. Blocker 4 keeps the restriction rather than relaxing it on a guess;
  someone should establish and document the reason.

## Related documents

- [`agent-developer-findings.md`](agent-developer-findings.md) — finding 6.
- [`stable-cli-contract.md`](stable-cli-contract.md) — owns the CLI surface and
  the private-artifact state vocabulary.
- [`../../trace-log-contract.md`](../../trace-log-contract.md) — normative for
  private record shapes, correlation, validation, and fail-closed capture.
- [`../../guides/kernel-repl.md`](../../guides/kernel-repl.md) — documents the
  current private-profile invocation.
