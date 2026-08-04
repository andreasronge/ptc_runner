# Private-session diagnostics, definition-only forms, and empty resource captures

**Status:** implemented. Reviewed in two codex rounds — one on this plan (one
[P1] on the result-limit error constructor, four [P2]s) and one on the
implementation (no [P1]; three [P2]s: an improper `unbound_names` list could
raise instead of failing closed, a partially rebuilt message did not say so in
its own text, and three claimed regression tests were missing). All are folded
in. Closes
[#1172](https://github.com/andreasronge/ptc_runner/issues/1172).

Three defects on the private analysis path, all with the shape #1166 named:
the runtime holds the answer and returns something that does not carry it.

1. A private session replaces every evaluator diagnostic with
   `"private evaluation failed"`, including diagnostics built entirely from the
   operator's own submitted source.
2. `defn-` in dynamic source fails as `Undefined variables: defn-, g, x`, which
   describes the symptom (three names) rather than the cause (the first one is
   not a dynamic form).
3. A profile resource directory whose artifacts sit one level down captures
   zero files, succeeds, and answers queries with an empty page —
   indistinguishable from a capture that genuinely holds no runs.

## Verified basis

Facts checked against the source at the commit this plan was written on, so
review need not re-derive them.

| Fact | Location |
| --- | --- |
| Every private-session error message collapses to a fixed string whenever `result_data_class != "normal"`; nothing else about the diagnostic is dropped | `analysis_session.ex:485-487` |
| That redaction was added deliberately by `0c486ff8` — "sanitize private evaluator failures before terminal and analysis sinks" | `git show 0c486ff8` |
| The canonical analysis events carry `source_hash`, `source_bytes`, `status`, `duration_ms`, and continuation summaries — **never** the failure message | `evaluation.ex:221-252` |
| The failure message therefore reaches only the terminal projection returned by `AnalysisSession.evaluate/2` | `analysis_session.ex:335-357`, `analysis_session.ex:468-489` |
| That same projection already returns the private `value`, `formatted`, and `prints` unredacted; the profile's whole contract is that exact private records may appear on the authorized terminal | `analysis_session.ex:359-386`, `docs/guides/kernel-repl.md` "Private inspection mission sessions" |
| The undefined-variable diagnostic is built pre-execution from AST symbol candidates, with an empty `details` map — the names exist only inside the message string | `lisp.ex:2104-2113` |
| `PtcRunner.Lisp.validate/2` recovers those names by string-splitting that message, so appending any hint text to it silently corrupts the returned name list | `lisp.ex:884-887` |
| Compile-stage `Step` failures keep their `details` map all the way into the session projection (`release_failure` merges `message` into `step.fail.details`) | `evaluation.ex:493-509`, `evaluation.ex:346-350` |
| `def`, `defonce`, and `defn` are analyzer special forms; `defn-` and `ns` are not, so `(defn- g …)` parses as a call to an undefined `defn-` | `analyze.ex:130-137`, `analyze.ex:397-406` |
| `defn-` and `ns` are prelude/component compiler heads only | `prelude/compiler.ex:387-390`, `prelude/form_scanner.ex:155` |
| An unbound-variable hint vocabulary already exists for the runtime path (special forms, unavailable Clojure functions), keyed by name | `lisp/eval/helpers.ex:181-245` |
| `InspectionSnapshot` info already reports `file_count`; `TraceSnapshot` info reports `run_count` but no file count | `inspection_snapshot.ex:288-297`, `inspection_snapshot.ex:536-546`, `trace_snapshot.ex:344-355` |
| Directory capture admits supported names at the directory's own level only — no recursion into subdirectories | `trace_log.ex:1547-1554`, `inspection_snapshot.ex:319-336` |
| A directory with no supported files is captured successfully as zero events; `run_count` is then 0 and every query returns an empty page | `trace_log.ex:1520-1545`, `trace_snapshot.ex:344-355` |
| Profile capture is the single funnel both profiles use to acquire their directory resources | `log_analysis_profile.ex:133-155`, `inspection_analysis_profile.ex:165-235` |
| `mix ptc.repl` prints nothing at session start in the default clojure format, and maps atom setup failures through one generic string | `ptc.repl.ex:695-706`, `ptc.repl.ex:463-476` |
| The session info projection already carries `snapshot`, which is exactly the capture summary the operator needs | `analysis_session.ex:536-551` |

Two facts about the issue text itself:

- `--private-unattended` does not exist. The private frontend is
  interactive-only and gated on `--private-terminal`; the reported behaviour
  reproduces there. This plan does not add the flag.
- Finding 1's `check-source` example returns the same message through
  `kernel/check-source`, which is not part of the private profile's capability
  set. The fix is in the shared diagnostic, so both surfaces improve.

## Decisions

### D1 — Private diagnostics are reconstructed from the operator's source, never echoed

The redaction is not defending the canonical trace (which never sees the
message) and it is not defending the terminal from private bytes (which
already receives private values, prints, and formatted records). What it
actually defends is a weaker, real property: no evaluator-produced text — text
that may quote a private record — reaches the operator *inside a diagnostic*,
where a host that forwards diagnostics separately from results would carry it
somewhere the result never goes.

Keep that property. Restore the diagnostic by rebuilding it instead of
forwarding it:

- A private session admits a diagnostic message only for **allowlisted kinds
  that carry structured, source-derived detail**. The allowlist starts with
  `:unbound_var`, whose names come from the submitted AST.
- Each admitted name must additionally appear **verbatim in the submitted
  source**. Names that do not are dropped. This makes the invariant mechanical:
  every byte of a private diagnostic is either a fixed literal in our source or
  a substring of the operator's own input.
- Everything else keeps the fixed message. `("SECRET" 1)` is a runtime "not
  callable" fault whose message is evaluator-produced, so it stays redacted —
  the existing regression test for that continues to hold unchanged.

### D2 — A redacted diagnostic says that it was redacted

`error.message_redacted?` is added to the projection: `true` when the private
policy withheld or trimmed the message, `false` otherwise (always `false` for
`log-analysis-v2`). The fixed string becomes
`"private evaluation failed; diagnostic withheld by the private result policy"`
so the terminal answers "why" without a doc lookup. A partially reconstructed
message (one name dropped by the verbatim check) also sets the flag, so a
short list is never mistaken for the whole cause.

`result_exceeded_projection/2` builds its own error map rather than going
through `error_projection/2` (`analysis_session.ex:504-522`), so it sets the
key explicitly — its message is a fixed profile literal, so `false` — and a
test covers that path. Every error map the session can emit carries the key.

### D2a — The reconstruction is its own module

The policy lives in `PtcRunner.Kernel.PrivateDiagnostic` with one public
function taking the diagnostic kind, the details map, the submitted source, and
the result data class. That keeps `AnalysisSession` a lifecycle owner, and it
makes the "name that is not in the source is dropped" case directly testable —
there is no way to inject such a diagnostic through a real session, since the
names always come from the submitted AST.

The module treats `details` as untrusted evaluator output: names are used only
when `unbound_names` is a list of valid binaries, each within a small length
bound, and the list itself is bounded before rendering. Structure carried in
`details` is a hint, never a provenance claim.

### D3 — The undefined-variable diagnostic names the definition-only cause

`check_undefined_var_candidates/2` gains two things:

- `details.unbound_names` — the offending names as a list, so consumers stop
  parsing prose. `PtcRunner.Lisp.validate/2` switches to it, which is what
  makes D1's structured reconstruction possible and removes the string-split
  in `validate_error/1`.
- A hint clause for names that are definition-only heads (`defn-`, `ns`):

  ```
  Undefined variables: defn-, g, x. Hint: 'defn-' defines a private helper in
  component source only; use defn in dynamic source
  ```

  The full name list is kept: `g` and `x` really are unbound, and truncating
  the list would trade one incomplete answer for another. The hint names the
  cause first-class, which is what the issue asks for.

`ns` gets the same treatment in the same table, since it is the other head a
component author carries into a REPL expression.

### D4 — A profile resource directory with no artifacts is refused

Fail closed with a stable error rather than capturing nothing successfully:

- `TraceSnapshot` info gains `file_count`, reaching parity with
  `InspectionSnapshot` and giving the profile the number it needs.
- `LogAnalysisProfile.capture/2` and `InspectionAnalysisProfile.capture/2`
  refuse a capture whose `file_count` is zero, stop the snapshots they started,
  and return `:empty_traces_resource` / `:empty_inspection_resource`.
- `mix ptc.repl` maps both atoms to a message that states the rule and the
  expected artifact suffix, e.g.

  ```
  ptc.repl profile setup failed: the traces resource directory contains no
  *.jsonl trace files at its own level (artifacts in subdirectories are not
  captured)
  ```

The refusal lives in profile capture, not in the snapshot primitives:
host-installation acquisition, `TraceLog`, and both snapshot modules keep
their current contract, so the blast radius is the two REPL profiles that
declare directory resources. Recursive capture is explicitly **not** added —
the boundary that makes a capture immutable and bounded is one directory level.

### D5 — The REPL states what it captured

`present_profile_started/2` prints one summary line per captured resource in
the default clojure format, and adds `snapshot` to the jsonl `session-started`
event. The two profiles report `snapshot` in different shapes — the log profile
returns the trace info map directly, the inspection profile returns
`%{traces: …, inspection: …}` (`analysis_resources.ex:79-91`) — so the summary
matches both shapes explicitly rather than assuming one:

```
Captured traces: 12 files, 12 runs
Captured inspection: 12 files, 12 runs
```

D4 makes zero impossible; D5 makes *near*-zero visible — one stray artifact at
the top level with the real runs one level down would otherwise still read as a
successful capture.

## Non-goals

- No recursion into resource subdirectories (D4).
- No change to what the canonical analysis trace records.
- No relaxation of the private `value`/`prints`/`formatted` projection; they
  are already unredacted by contract.
- No `--private-unattended` flag.

## Implementation

1. **`lisp.ex`** — `check_undefined_var_candidates/2` builds
   `details.unbound_names` and appends the definition-only hint; `validate_error/1`
   reads the names from details. Hint table lives beside the existing
   unbound-variable vocabulary in `lisp/eval/helpers.ex` and is used by both the
   pre-execution check and `format_closure_error/1`.
2. **`private_diagnostic.ex`** (new) — the allowlist, the verbatim check, the
   details validation, and the fixed strings.
3. **`analysis_session.ex`** — thread the submitted `source` into
   `project_result/3`; call `PrivateDiagnostic` from `error_projection/2`; set
   `message_redacted?` in both error constructors.
4. **`trace_snapshot.ex` / `trace_log.ex`** — carry the admitted file count out
   of the inventory into the capture map and the info projection.
5. **`log_analysis_profile.ex` / `inspection_analysis_profile.ex`** — refuse an
   empty capture and stop what was started.
6. **`ptc.repl.ex`** — setup-error clauses for the two new atoms; capture
   summary at session start.
7. **Docs** — `docs/guides/kernel-repl.md` (private diagnostics, empty resource
   refusal, capture summary), CHANGELOG `Unreleased/Fixed`, and the touched
   moduledocs.

## Test plan

Bug-first: each test below fails on `main` before its fix lands.

| Test | Asserts |
| --- | --- |
| `inspection_analysis_profile_test.exs` | `(defn- g [x] (* x 3)) (return (g 14))` in a private session reports the names and the `defn-` hint, with `message_redacted?: false` |
| `inspection_analysis_profile_test.exs` (existing) | `("PRIVATE_ANALYSIS_NOT_CALLABLE" 1)` still redacts, now with `message_redacted?: true`, and the secret appears nowhere in the result |
| `private_diagnostic_test.exs` (new) | a name that is not verbatim in the source is dropped, the message says so, and `message_redacted?` is true; malformed `unbound_names` details (including an improper list) fall back to the fixed message |
| `analysis_session_test.exs` | the separate result-limit error constructor carries `message_redacted?: false` and the profile literal (both profiles share the constructor; the private profile's heap ceiling trips before its result ceiling, so it is covered on the public profile) |
| `inspection_analysis_profile_test.exs` (existing trace assertions) | the canonical trace still contains no diagnostic text |
| `lisp_test.exs` / eval error tests | `defn-` and `ns` hints in dynamic source; `unbound_names` in details; `Lisp.validate/2` returns the same names it did before |
| `analysis_profile_test.exs`, `inspection_analysis_profile_test.exs` | capture of a directory whose artifacts are one level down is refused with the stable atom, and no snapshot process survives the refusal |
| `inspection_analysis_profile_test.exs` | a directory holding one artifact with zero runs is still captured (`file_count: 1`, `run_count: 0`), so the refusal keys on admitted files and not on runs |
| `ptc_repl_test.exs` | the empty-resource message names the directory rule; the capture summary is printed; the jsonl `session-started` record carries `capture` |

Gates: `mix precommit`, then `git push` hooks (root tests, `mix prepush`,
dialyzer, docs).

## Risks

| Risk | Mitigation |
| --- | --- |
| Relaxing the private message re-opens the leak `0c486ff8` closed | Reconstruction from a fixed literal plus verbatim source substrings; kind allowlist; the existing secret-in-result regression test is kept and strengthened |
| Appending hint text breaks message-parsing consumers | `validate_error/1` moves to structured names in the same change; grep confirms no other consumer parses the string |
| Refusing empty captures breaks an existing caller | Refusal is scoped to the two profile capture functions; snapshot primitives, `TraceLog`, and host-installation acquisition are untouched; full suite is the check |
| `file_count` in info changes a public projection | Additive; `InspectionSnapshot` already carries the key, and host installation projects trace acquisition explicitly field by field |
