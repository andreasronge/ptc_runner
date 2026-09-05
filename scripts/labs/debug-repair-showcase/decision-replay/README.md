# One-decision conversation replay

This 2026-09-04 follow-up tests a cheap alternative to repeating whole
navigation investigations. It samples the next action from an exact recorded
request, or from an explicitly described counterfactual continuation. No
summary replaces the conversation and no expected answer is given to the model.
The model remains DeepSeek V4 Flash, temperature zero, 4,096 output tokens,
connector caching disabled. Four cells have three single-call samples each;
all outcomes are retained. This is twelve decisions from two selected failure
points, not twelve independent incidents.

## Results

| Decision point | Variant | Next-action outcome | Reported USD |
| --- | --- | --- | --- |
| Unavailable link | Terse recoverable error | 3/3 choose the available source link; all execute successfully | $0.000761 |
| Unavailable link | Actionable recoverable error | 3/3 choose the available source link; all execute successfully | $0.000768 |
| Ambiguous requirement | Original request | One more inspection, one unsupported diagnosis, one incomplete abstention program | $0.002911 |
| Ambiguous requirement | Requirement reminder | 3/3 choose further inspection; no verdict | $0.002715 |

Total: **12 model calls, $0.007155** in reported usage. Recovery calls took
4.7–6.9 seconds; ambiguity calls took 30.6–96.8 seconds. All twelve retained
exactly one complete exchange. Process success is not the scoring criterion.

The recovery continuation works at this specific decision point with either
message. It supports investigating a recoverable API contract; it does not
show that longer error guidance helps, nor that complete investigations become
more reliable. These are six repeats from one snapshot, with synthetic error
feedback. Successful next actions were subsequently executed, not merely read.

The ambiguity reminder has no demonstrated verdict improvement. Continued
inspection might eventually help or just consume the last two turns. Two
reminder trials request the generic `kernel` source and one reopens run
metadata; none immediately identifies the missing precedence requirement.

The third control trial began a well-grounded `insufficient-evidence` answer
but ended mid-string. Its reported output usage was exactly 4,096 tokens, yet
`finish_reason` was `tool_calls`. PTC's nonexecuting `kernel/check-source`
confirmed `parse_error`: unclosed string at column 1321. This is an invalid
proposed action, not a successful abstention. All other ambiguity actions
compiled. The next-action harness itself returns raw provider responses and
does not implement the full agent's protocol repair loop.

Practical conclusion: use decision replay to screen local changes cheaply,
then run a small end-to-end test only when the local behavior improves. Keep
successful navigation, valid syntax, grounded decisions, and unfinished
investigations as separate outcomes. No global prompt or prelude change is
adopted from this sample.

## Frozen decision points

### Unavailable relationship

Source: `cmd-17033yrda5qey49sg31kvwm9mn`, turn 6, from the previous coached
navigation experiment. The recorded agent selected the first relationship of a
generated-source item. That relationship is unavailable; the second is a
complete link to `page.index`. The original library deliberately failed and
ended the run, so there is no real seventh request to replay.

Both trial variants keep the full last request, append the exact recorded
assistant tool call, and append a synthetic successful evaluation containing
an error value. Its original relationship, `page: nil`, error kind, recoverable
flag, and next-turn budget are identical. Both replace the original follow
docstring's fail-fast phrase with its recoverable counterpart. The only
between-variant difference is the refusal message:

- Terse: “Cannot follow an unavailable relationship.”
- Actionable: “No evidence was read. Select another complete relationship with
  filters, or report the missing evidence.”

The relationship object is taken from the PTC-inspected original observation;
it is not a fabricated alternative source. The synthetic feedback uses the
normal success wrapper, labels its output as untrusted, and carries the next
turn budget of 14. This measures reaction after recovery, not a comparison of
live fail-fast and recovery implementations. The earlier deterministic probe
established that a recovery implementation can supply this kind of result.

### Ambiguous requirement

Source: `cmd-62ttx8bbg3dwsvkw6g6jnx6c1p`, request 19, from the previous
interface comparison. The original next action blamed `record.combine` despite
no independent metadata precedence requirement. Two turns remain in the
recorded request; this is deliberately not relabeled as a final turn.

Control resends the complete request unchanged, including system, messages,
and tool definitions. The other arm appends one domain-blind user instruction:

> Before naming a faulty component, identify the independent requirement that
> its implementation violates. Distinguish an observed assertion or caller
> expectation from an authoritative requirement. If the captured evidence does
> not establish which behavior is required, report the missing requirement
> rather than selecting a repair target.

This is a targeted instruction authored after inspecting the failure, not a
held-out test of a generally improved prompt. A request to inspect more evidence
is recorded as continued investigation, not as successful abstention or as an
unsupported diagnosis.

## Execution and provenance

`export.py` asks PTC to read and validate the complete exchange page and publish
the trial input. Python never deserializes captured requests, logs, responses,
or model actions. `run.py` sends each input through one `llm/request` inside a
small PTC workflow. The wrapper does not execute generated programs. Provider
results and request evidence are retained as normal PTC private captures.

The replayed ambiguity control request hash matches the original:
`sha256:47cf29f6385f87a68583777fe43ecf65bdf9d1d2561bb349c8b668efb6ee35ea`.
The local `plan.json` also pins each input file's byte hash before model calls.
Exact repeated requests may still yield different actions at temperature zero.

`verify-actions.py` subsequently exports all six recovery actions through PTC
and executes them on the original read-only incident snapshot, without model
calls. These actions are self-contained reads, so no conversation continuation
state needs to be reconstructed. All six return a complete source page for
`page.index`. They select the second relationship by position rather than
checking its state; this proves the chosen action works on this snapshot,
not general robust relationship selection. Ambiguity actions are inspected as
proposals and checked with `kernel/check-source`; they are not executed in this
experiment.

## Reproduce

Use a fresh `tmp/nav-decision-replay` directory with the source captures from
the two preceding labs still present. Never overwrite a started comparison.

```sh
mkdir -p tmp/nav-decision-replay/inputs
python3 -B scripts/labs/debug-repair-showcase/decision-replay/prepare.py
python3 -B scripts/labs/debug-repair-showcase/decision-replay/export.py
python3 -B scripts/labs/debug-repair-showcase/decision-replay/run.py --env-file "$ENV_FILE"
python3 -B scripts/labs/debug-repair-showcase/decision-replay/verify-actions.py
python3 -B scripts/labs/debug-repair-showcase/decision-replay/verify-actions.py --case ambiguity
ptc repl --project tmp/nav-decision-replay/recovery-terse.ptc-project.json \
  --profile private-run-analysis-v2 --private-unattended --preview-chars 16000 \
  scripts/labs/debug-repair-showcase/decision-replay/analyze.clj
```

Repeat the final query for each cell. Capture analysis uses PTC exclusively.
The installed runtime is 0.14.0 (`ef72c0e9`). No shipped library or agent prompt
is changed, and independent review remains paused.

## Friction and verification

PTC supplied the required inspection and source-checking APIs; no raw log
parser was needed. There is no claimed missing replay command: this lab uses a
small workflow to send the recorded provider-neutral request once. Building the
counterfactual requires explicitly preserving assistant/tool-call correlation,
feedback format, and budget; a conversation summary would not be equivalent.
The model's incomplete program despite a tool-call finish reason shows why
source validation remains necessary even for this small test.

The wrapper manifest validated, all twelve live calls were captured and read
through PTC, all six recovery programs executed against the original snapshot,
and all six ambiguity programs received nonexecuting source checks. Python
syntax checks and `git diff --check` passed. No production runtime was edited.

The subsequent [one-final-turn continuation](../decision-continuation/README.md)
restored the recorded mission state and finished all six ambiguity trajectories
with five additional calls. The incomplete abstention was repaired successfully;
the reminder arm still produced no supported verdict.
