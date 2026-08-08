# Duplication gate

`mix precommit` and CI run `scripts/duplication_gate.sh check`, which detects
copy-pasted code with [ExDNA](https://github.com/elixir-vibe/ex_dna) and
compares the result against `.duplication-baseline.json`.

The gate is a ratchet, not a threshold. Duplication already recorded in the
baseline never fails a build; duplication that is not recorded does. That keeps
the existing backlog out of everybody's way while stopping new copies from
entering unnoticed.

## What it detects

Exact copies and copies with renamed variables (clone types I and II), over the
root project's `lib/` and `test/`, for fragments of at least 30 AST nodes.
Viewer and launcher code are outside this baseline and are not covered by this
gate. Consecutive clauses of the same function are analysed as one unit, so a
duplicated multi-clause function is reported once rather than as several
forgettable fragments.

It does **not** detect code that does the same thing written a different way.
Two implementations that diverged during editing will fall out of the report.

## When the gate fails

```
NEW  8b6747b7f283  type_i mass=86  lib/…/gate_probe_alpha.ex:4 <-> lib/…/gate_probe_beta.ex:4
duplication: baseline=82 current=83 new=1 shrunk=0 resolved=0
```

Choose deliberately between three responses.

### Extract the shared logic

Correct whenever the copies encode **one piece of knowledge**: a validation
rule, an encoding, a lattice, a security primitive. Drift between such copies is
a defect, because a fix applied to one silently leaves the others wrong.

### Suppress it, with a reason

Correct when the repetition is **two independent decisions that happen to look
alike**. Coupling those creates a false dependency, and the next change to one
has to fight the abstraction. Put the comment above one copy:

```elixir
# ex_dna:disable-for-next-line — GenServer callback, intentionally per-module
def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]
```

Suppressing one copy removes the whole clone from the report. Other forms are
`disable-for-this-file`, `disable-for-previous-line`, and `disable-for-lines:N`.

Cases that usually belong here: per-module OTP callbacks, helpers that mirror an
external contract each module must satisfy independently, and test setup kept
explicit so a failure points at one test rather than a shared helper.

### Re-bless the baseline

```bash
scripts/duplication_gate.sh bless
```

Reserved for duplication you are **accepting as debt** — real, worth fixing, not
now. It records no reason, so prefer a suppression comment for anything
deliberate. Keeping the two apart is what makes a shrinking baseline meaningful:
permanently-acceptable repetition leaves the ledger entirely.

Re-blessing is also how you lock in an improvement. Removing duplication prints
`resolved` and passes; bless to make the removal permanent.

## Fingerprints and churn

A clone is keyed by its type, file paths, and exact AST-rendered bodies, never by
line numbers, so edits elsewhere in a file do not re-key it. Comments are
invisible because the detector works on the AST; whitespace inside strings and
sigils remains significant.

Editing inside a known clone re-keys it. The gate reports `shrunk` only when it
can pair the result one-to-one with prior debt, at least one exact occurrence
remains, and the clone added no occurrence or file, gained no AST mass, and did
not become more exact. Ambiguous changes fail as new duplication and require an
explicit decision; this is intentionally conservative.

## Running it directly

```bash
scripts/duplication_gate.sh check    # what CI runs
scripts/duplication_gate.sh bless    # record the current set

mix ex_dna lib/ test/                # full human-readable report
mix ex_dna.explain 3 lib/ test/      # extraction breakdown for one clone
```

Detection takes roughly fifteen seconds over `lib/` and `test/`. Configuration
lives in `.ex_dna.exs`; `.ex_dna_cache` is a machine-local artefact and is
ignored.
