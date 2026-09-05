# Connecting recovery to a repair

Current development record for the self-improvement example. All capture,
conversation, candidate, and outcome analysis uses PTC. Python only prepares
static configuration and launches PTC commands.

The original recorded investigator (`cmd-17033yrda5qey49sg31kvwm9mn`) stopped
at an unavailable relationship after six calls. `prepare.py` and `resume.clj`
restore its first five programs, execute the recorded sixth action, and allow
at most the original fourteen remaining calls. The unchanged library reproduces
`cannot follow an unavailable or filterless relationship` without a new model
call. The hand-authored recoverable candidate then completed in fourteen calls
($0.005207): `cmd-54xy1f9ccwr5sm8hem5ck0p41t` correctly identifies `page.stop`.

A repair agent receiving that diagnosis and the independent structural packet
first failed while copying source/hash text. With `repair.edit/propose`, the
same model instead proposes a small exact replacement; Lisp supplies the
captured source hash and unedited bytes. Run `cmd-2xva3n7jj04jn45v5k2h7s08ez`
completed in one call ($0.000612). `mix ptc.repair` materialized that proposal,
passed its compile/export/effect/dependency gates, and passed four host-owned
cases: observed interval, empty interval, singleton, and negative start.
These validation cases were not provided to the model.

The edit helper's deterministic PTC probe checks refusal of absent, repeated,
and identical fragments, exact hash preservation, and unchanged-source bytes.
No model writes the installed file. The proposed replacement still goes
through materialization and independent validation.

## Model-generated navigation improvement

The first improvement agent correctly distinguished the documented fail-fast
contract from an implementation bug and abstained. After an explicit request
to improve that contract, a full-file proposal claimed recovery but retained
the failing code; the deterministic probe rejected it. Neither is counted as
an improvement.

Using the exact-edit helper, run `cmd-49gscgc5mgcr92arg3wex08brt` proposed an
actual reusable change to `debug.nav/follow` and its docstring. Its unavailable
branch returns `{ok false, page nil, reason ..., relationship ...}`. Successful
reads remain byte-for-byte the same source path; malformed options still fail.
This took eleven Gemini 3.8 Flash calls, $0.047579.

The materialized model candidate passed a PTC probe using a different frozen
incident: unavailable-link recovery, no substitute page, exact successful page
identity, and unchanged option rejection. A full continuation with that exact
candidate is recorded separately under `tmp/nav-recovery-story/model-recovery`.
PTC inspection confirmed that continuation `cmd-0tv50gf8q2wh3w2fjgcwbpttvh`
completed and identified `page.stop` in fourteen calls ($0.005210). The earlier
application repair used the earlier completed diagnosis; these prototype runs
are separate pieces, not one uninterrupted chain.

The local runs are development evidence, not the intended operator interface.
A fresh runnable example must create its own failure capture rather than
require these old run identifiers. No shipped global prelude has been changed.
Review remains paused.


## Runnable example

`examples/debug-a-failed-run/run-self-improvement.sh` now creates fresh captures
and joins the stages. The full initialized-copy run under
`tmp/packaged-self-improvement-2` passed both helper checks, completed a new
investigation, and passed all three application validation inputs. It used
23 model calls with reported cost $0.096493. The helper proposal is
`cmd-4mztfy6s3n8d17xpv21r4vds2d`; it selects a complete referenced source instead
of assuming relationship order. The source files stay unchanged.

The fixture seeds a mismatch between the helper's contract and implementation.
The agent must find and edit it; its prompt does not include application names,
expected totals, or the replacement expression. Deterministic Lisp checks the
candidate on pricing and fulfillment captures before another agent investigates
the application. Exact-edit processing and diagnosis handoff are Lisp functions.

## Packaging friction

- `ptc init` omits empty directories. The script now creates the artifact parent
  directories before any model calls.
- Installed `ptc` 0.14.0 (ef72c0e9) returns exit 70 `internal/internal_error`
  when materializing this valid helper under `.ptc/self-improvement/helper`
  or `.self-improvement/helper`. An absolute hidden destination also fails.
  The same proposal and project succeed under `review-repro/helper-local`.
  Reproduction is retained under `tmp/packaged-self-improvement-final`: run
  `ptc materialize self-debugger.ptc-project.json --target-mission evidence
  --component debug.start --from-result
  .ptc/self-improvement/helper-proposal.private.json --result-pointer
  /candidate_source --out .self-improvement/helper` from that directory.
  No extra model calls are needed. The example uses the verified regular
  `self-improvement-results` directory. The runtime cause remains unresolved.
- Gemini 3.8 Flash works through OpenRouter but is uncataloged in this installed
  PTC version, which prints a warning. Costs above are reported provider usage.


### Final initialized-copy verification

The final script ran unmodified from `tmp/packaged-self-improvement-ready` and
exited 0. All private evidence was inspected through PTC:

| Stage | Run | Outcome |
| --- | --- | --- |
| Helper improvement | `cmd-5n109xa0q5z05wcsb0r044fnnc` | Exact filter edit; 8 calls, $0.031595 |
| Investigation | `cmd-48vvs94d1ekkgkqedme61hkyj2` | Diagnosed `pricing.rule`; 11 calls, $0.043801 |
| Application repair | `cmd-211nc7vc13g7yn0syhd876g0pk` | Adds the documented charge; 2 calls, $0.012243 |
| Observed input | `cmd-6xap0334qe1nem8ftnmd8323rk` | Total 120 |
| Smaller input | `cmd-1byh89xhmajxs9ngzz1rzamswa` | Total 70 |
| Zero input | `cmd-199576brds7p92dfh98hg27jzt` | Total 20 |

Both helper checks passed before investigation. Total reported cost was
$0.087639 for 21 calls. Byte comparisons confirmed that both original source
files remained unchanged. PTC inspection of generated programs shows the
investigator successfully followed the dependency relationships, then used `debug.nav/open`,
read activity and source collections, inspected failure values and execution
errors, and selected the faulty component's source. It did not receive the
final diagnosis as input. Subsequent model-exchange inspection confirms that
turn 2 reached `pricing.tax` and turn 3 reached both `pricing.base` and
`pricing.rule`. An earlier interpretation of keyword-key access as a failed
lookup was wrong: the next model requests contain successful pages. Issue
#1821 was corrected and closed. Broad output previews were truncated; turn 10
selected the relevant source explicitly before the final diagnosis.


Final checks passed: `mix precommit`, `mix nightly` (24 passed),
`MIX_ENV=dev mix docs --warnings-as-errors`, `mix ptc.verify_docs`, guide budget
(230 words, zero blockers/tics), and `git diff --check`. The focused example
file also passed with nightly cases included. Initialization used this
checkout's `mix ptc init`, because the installed binary embeds the older
example; the initialized script itself used PATH `ptc` throughout.
Independent review, commit, and publication remain deferred.
