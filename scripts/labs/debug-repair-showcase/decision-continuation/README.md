# One final turn after decision replay

This follow-up retains all six ambiguity trials from the one-decision lab and
allows each unfinished trial one final model call. It does not select a new
prompt, restart an investigation, or retry an unfavorable result. The already
terminal unsupported diagnosis receives no new call and remains unsupported.
Five additional calls use DeepSeek V4 Flash, temperature zero, a 4,096-token
output ceiling, and no connector response caching.

## Results

All five additional model calls finished. The eighteen prefix programs
continued successfully in each of the six trial replays, and each new model
exchange was complete. The original terminal trial was executed with zero new
model calls and retained as an unsupported diagnosis.

| Parent arm | Supported abstention | Unsupported diagnosis | No usable final action |
| --- | --- | --- | --- |
| Unchanged request | 1/3 | 2/3 | 0/3 |
| Requirement reminder | 0/3 | 1/3 | 2/3 |

These are the same three sampled trajectories per arm from the previous lab,
continued to their two-turn boundary, not a fresh independent sample.

- `control-incomplete` received the actual parse-error feedback, repaired its
  incomplete program, and returned a valid `insufficient-evidence` report.
  It explicitly explains that the contract does not specify which source wins.
- `control-inspect` inspected the generic kernel source and then again blamed
  `record.combine` without establishing a precedence requirement.
- `control-diagnose` was already terminal and remains unsupported.
- `reminder-inspect-1` acknowledged the missing contract, but invented a naming
  convention that left means primary and right means secondary. Neither that
  rule nor its supposed authority is established by the capture.
- `reminder-metadata` returned empty content without a tool call, with provider
  finish reason `stop`. No executable next action or verdict was supplied.
- `reminder-inspect-2` returned empty content without a tool call at its
  4,096-token output ceiling, with finish reason `length`.

The five new calls cost **$0.002858** in reported usage and took 9.6–96.9 seconds
per continuation run, including local replay. The twelve-call decision lab and
this continuation together cost $0.010013. A successful wrapper process is not
a successful diagnosis; the table uses executed mission results and observed
protocol failures.

The reminder has no demonstrated benefit and is not adopted. The positive
result is narrower: PTC's existing parse-error feedback enabled one invalid
abstention program to become an executable, grounded answer. A one-action test
would have missed that recovery. Navigation recovery remains the stronger
candidate from the previous lab, while ambiguity judgment still needs a better
intervention or model comparison.

## Verification and limits

The wrapper manifest validated, all six state replays completed, all final
programs that were supplied were executed, and outcomes were inspected through
PTC. Python syntax checks and `git diff --check` passed. No shipped runtime,
prelude, or agent task prompt changed; review remains paused.

This restores state by re-executing recorded programs against an immutable,
read-only snapshot. Do not use this recipe to replay arbitrary programs with
external side effects. The harness and exported transcripts are local lab
artifacts; the production agent still owns its ordinary budgets, protocol
handling, and contract enforcement. Five calls on one known ambiguity do not
establish a general success rate.

## Preserved state and feedback

PTC reads the original capture `cmd-62ttx8bbg3dwsvkw6g6jnx6c1p` and all six
sampled responses. It exports the original eighteen programs and each sampled
request/response pair without a conversation summary. A small workflow replays
those eighteen programs against the same frozen incident snapshot, restoring
mission definitions and result history. No model call is needed to replay them.
It then executes the sampled nineteenth program.

If that program returns, the trial ends. Otherwise the workflow uses the
installed `agent.feedback/success` or `agent.feedback/evaluation-error` to
format its actual execution result. Observations retain the original
2,048-character limit. It appends the correlated assistant/tool messages and
`agent.feedback/turn-budget` with one turn remaining. The sampled request's
system, tools, and earlier conversation remain intact, including the extra
user reminder only in that arm. Exactly one final model call is permitted.
The final generated program is executed in the same restored mission state.

This is a bounded continuation harness, not a claim of reproducing every
branch of `agent.core`: it accepts one `run_ptc_lisp` call, preserves successful
state, and records invalid final actions without a further correction call.
Its wrapper result has a different shape from the application report, so
process success is not diagnostic success. Results must be scored from the
actual mission outcome and verdict. The model's system still contains the
original application result contract from the captured request.

## Reproduction

This lab requires the earlier local captures. Start with no
`tmp/nav-decision-continuation` directory. `prepare.py` copies exact named
artifacts into an isolated snapshot and invokes PTC to transform them; it does
not interpret their contents. Python also writes static configuration and
launches commands. Every capture query and generated-program evaluation uses
PTC.

```sh
python3 -B scripts/labs/debug-repair-showcase/decision-continuation/prepare.py
ptc validate tmp/nav-decision-continuation/control-diagnose.ptc-project.json
ptc run tmp/nav-decision-continuation/control-diagnose.ptc-project.json \
  --private-input tmp/nav-decision-continuation/inputs/control-diagnose.json \
  --env-file "$ENV_FILE" \
  --private-output tmp/nav-decision-continuation/control-diagnose/result.private.json
python3 -B scripts/labs/debug-repair-showcase/decision-continuation/run.py --env-file "$ENV_FILE"
ptc repl --project tmp/nav-decision-continuation/control-inspect.ptc-project.json \
  --profile private-run-analysis-v2 --private-unattended --preview-chars 16000 \
  scripts/labs/debug-repair-showcase/decision-continuation/analyze.clj
```

Repeat the analysis command for all six projects. Frozen input hashes and the
fixed run list are retained in local `plan.json`; the original trial IDs are
in `trials.json`. Neither file contains credentials.
