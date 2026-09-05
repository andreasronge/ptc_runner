# Navigation interface comparison

This follow-up tests two interface changes suggested by the previous failed
prompt-improvement experiment. They are isolated, hash-checked component
replacements; no shipped prelude or global agent prompt is edited.

## Results (2026-09-04)

All 27 runs completed and were inspected through PTC. A supported answer names
`sheet.area` for the arithmetic defect, `main` for the double subtraction,
or abstains on the unspecified metadata precedence. Successful process exit
alone does not count as a supported diagnosis.

| Arm | Sheet | Meter | Record abstention | Supported | Unsupported diagnosis | Turn limit | Calls | Reported USD |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Control | 3/3 | 1/3 | 0/3 | 4/9 | 2 | 3 | 168 | $0.040476 |
| Docs | 2/3 | 1/3 | 0/3 | 3/9 | 1 | 5 | 166 | $0.040352 |
| Recovery | 2/3 | 3/3 | 0/3 | 5/9 | 2 | 2 | 178 | $0.041476 |

The live comparison cost $0.122304 in reported model usage. Every run's turn
page was complete. Runs took 65–453 seconds; the fixed budget was 20 calls.
All unsupported diagnoses blame `record.combine`: they explain the overwrite
but do not establish which label should win. The remaining ambiguous trials
exhausted their turn budgets. None returned the required abstention.

**Neither targeted failure recurred in this batch.** No generated program
mentioned the old example identifier, and no recovery feedback contained the
new refusal. Some runs followed valid relationships. Consequently, the
recovery arm's higher observed score cannot be attributed to rescuing failed
navigation. Its changed documentation and ordinary model variation remain
possible explanations. Three repetitions per incident do not establish a
reliability difference.

The controlled probe establishes that recovery works at the API boundary;
the live comparison does not establish that it improves agent success. The
docs change also has no demonstrated performance benefit. Keep both as lab
candidates, with no shipped prelude change. Before considering recovery for
adoption, audit callers of the existing fail-fast contract and test agents
from a controlled unavailable-link starting state. Separately, the ambiguous
case needs evaluation of whether the agent distinguishes an observed mismatch
from an established behavioral requirement.

Observed PTC friction remains large previews and exhausted navigation budgets:
every run encountered at least one truncated-preview warning, despite several
successful source walks. The proposed recovery is a change to an intentional
API contract, not evidence of an undocumented runtime bug. All capture and
model-output analysis used PTC; Python only prepared static files and launched
commands.

## Fixed experiment

Three arms use the unchanged debugging task and installed DeepSeek V4 Flash:

1. **Control:** installed `debug.nav`.
2. **Docs:** change only the `debug.nav/read` docstring. Its example obtains an
   evaluation identifier from a returned generated-source item rather than
   supplying the fixed example `mission-evaluation-9`. Behavior is unchanged.
3. **Recovery:** keep the original read documentation, but return an explicit
   `navigation_error` and `page: nil` when a relationship cannot be followed.
   The original relationship is preserved. No fallback source is fetched.
   The follow docstring describes this changed return behavior. Valid reads
   and invalid-option rejection are unchanged.

There is no combined arm and no candidate selection after observing results.
The model has 20 calls, 2,048-character observations, 4,096 output tokens,
1,024 retained events, temperature zero, and no consolidation reminder or
coaching addendum. The host disables connector caching. Three repetitions of
three new incidents in each arm produce 27 runs. The scheduler runs at most six
at once, never overlaps a cell with itself, and requeues completed cells behind
other waiting cells. All failures are retained without whole-run retries.

The new incidents are incorrect rectangle-area arithmetic, a workflow that
subtracts a measurement offset twice, and two conflicting proposed metadata
labels with no precedence policy. Expected diagnoses are `sheet.area`, `main`,
and abstention respectively. The oracle is fixed outside the model's snapshot
authority. These are new source/capture fixtures but still small constructed
problems with related debugging structure; transfer to real applications is
not established by this test.

## Deterministic boundary checks

The recovery probe was written and run against the installed library before
creating the replacement. It failed as expected. The same probe passes with
the recovery override:

- an unavailable `producing_turn` relationship returns no page and a clear
  recoverable error;
- the program continues and follows a different complete relationship;
- that successful page is exactly equal to a direct read, including source,
  hashes, relationships, cursor, and completeness metadata;
- invalid follow options remain rejected;
- the captured probe has exactly three `debug.nav.read` calls: listing
  generated source, following the valid relationship, and comparing a direct
  read. The unavailable link makes no provider read.

The documentation-only override still fails that recovery probe, confirming
that it has not introduced recovery behavior. Correcting the sheet and meter
fixtures produces successful runs. Changing the record fixture's expected
label to the implemented output also succeeds; this proves execution, not
which precedence policy should apply.

## Reproduce

The dated scripts use `tmp/nav-interface-testing` under the checkout. Start
with a new directory; captures and comparison records must not be overwritten.
The existing refreshed example supplies the unchanged debugger manifest and
host template. The environment file stays outside the experiment directory.

```sh
mkdir -p tmp/nav-interface-testing
ptc materialize examples/debug-a-failed-run/debugger-agent/ptc.json \
  --target-mission evidence --component debug.nav \
  --source-out tmp/nav-interface-testing/original.clj
python3 -B scripts/labs/debug-repair-showcase/interface-testing/prepare.py
```

Capture each generated `sheet`, `meter`, and `record` project with
`ptc run tmp/nav-interface-testing/CASE.ptc-project.json`; each deliberately
exits 5. Use `ptc repl --project ... --profile private-run-analysis-v2
--private-unattended -e '(analysis/runs {})'` to inspect captures and obtain the
sheet run ID. Then run the following checks. The baseline and docs probes are
expected to exit 5; recovery must exit 0.

```sh
python3 -B scripts/labs/debug-repair-showcase/interface-testing/prepare-checks.py \
  --sheet-run "$SHEET_RUN_ID"
ptc run tmp/nav-interface-testing/probe-baseline.ptc-project.json
python3 -B scripts/labs/debug-repair-showcase/interface-testing/make-candidates.py
ptc run tmp/nav-interface-testing/probe-recovery.ptc-project.json \
  --component-override-descriptor tmp/nav-interface-testing/recovery-override/descriptor.json
ptc run tmp/nav-interface-testing/probe-docs.ptc-project.json \
  --component-override-descriptor tmp/nav-interface-testing/docs-override/descriptor.json
python3 -B scripts/labs/debug-repair-showcase/interface-testing/run-comparison.py \
  --env-file "$ENV_FILE"
ptc repl --project tmp/nav-interface-testing/recovery-sheet.ptc-project.json \
  --profile private-run-analysis-v2 --private-unattended --preview-chars 16000 \
  --load scripts/labs/debug-repair-showcase/analyze-navigation.clj \
  scripts/labs/debug-repair-showcase/score-navigation.clj
```

`ptc materialize` exports installed source and authors the descriptors; it
validates the base hash, source hash, exports, dependencies, and effects. The
comparison records source-byte hashes before starting. Python prepares static
configuration and launches commands; it never interprets a trace, conversation,
or model result. All capture analysis uses PTC.

## Scope of the recovery change

This changes a deliberate fail-fast contract for invalid relationships, rather
than repairing an undocumented runtime bug. A refusal is a value, not evidence:
its page remains nil and it carries no invented record or replacement link.
The agent must still choose another legitimate link or explain missing
evidence. Repeated bad choices can still exhaust its existing budget. The
experiment does not widen provider authority or automatically diagnose a fault.

## Mechanism checks

`mechanisms.clj` queries each cell through PTC. It checks that the intended
new docstring was visible in the first model request, counts generated programs
mentioning the old example ID, and counts feedback containing the recoverable
error. It also counts programs mentioning `debug.nav/follow`. These textual
counters guide inspection; they do not independently establish correct
navigation or causal benefit. A successful recovery-arm run that never calls
`follow` cannot demonstrate rescue by the changed error behavior.

The documentation-only requests contain the new read example and the
original follow documentation. Recovery requests contain the new follow
contract and the original read documentation. Check the refusal counters
before attributing any outcome difference to recovery: successful runs that
never encountered a refused link cannot demonstrate rescue by this behavior.

## Adoption considerations

Existing `debug.nav` tests explicitly require unavailable relationships to
fail. This prototype therefore needs a deliberate contract change before
shipping, not merely a changed test expectation. Consumers that assume every
returned map contains a valid page need to handle the refusal branch explicitly.
The example walkers already check relationship state, but this lab does not
claim a full downstream-consumer audit. No production adoption is made during
the fixed comparison.

The initial metadata-label recovery report completed but blamed
`record.combine` without establishing a precedence policy. It is scored as
unsupported rather than successful: showing how the overwrite happened does
not determine which source should win or whether the caller's expectation was
correct. Navigation safety and diagnostic judgment are separate measurements.

## Frozen source identities

Runtime: `ptc 0.14.0 (ef72c0e9, clean)`. The SHA-256 hashes recorded before the
model comparison are:

- Control: `1df02d4efce250afbc1099119e2c725e33c1bf5f3a008057f858423e39eeca34`
- Docs: `3c1c44af301b5fdf14caceb07cbc843e4856c85204ada6047e937fed0c947194`
- Recovery: `a079604274c2b6a01f114d7124428afe1cc173aa04bdd4b457162f42f36936d8`

The run IDs for the new frozen incidents are:

- Sheet: `cmd-13wagxx7b8ffp4ng943q6fw9bb`
- Meter: `cmd-4rvech62g80c9e8p52d2jdz81m`
- Record: `cmd-2ghy7m9q5fg949rjyjakt59zwb`

One documentation-arm sheet trial (`cmd-69mc2cwh3szddyy1g8fbaj3bfd`)
completed in 10 calls and 65 seconds. Its trace lists and opens the failure,
reads the error and generated program, follows the referenced component,
follows its dependency, then reads both dependency branches before naming the
arithmetic contract violation. This is a concrete successful navigation walk,
not an overall reliability claim: another run of that same cell exhausted its
turn budget. The full cell has two supported diagnoses out of three.
