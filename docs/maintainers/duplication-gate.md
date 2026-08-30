# Duplication gate

> **Audience:** people changing PtcRunner itself.

This gate runs over this repository's own source; it is not part of the runtime
an application uses.

`mix precommit` and CI run `scripts/duplication_gate.sh check`. It compares an
[ExDNA](https://github.com/elixir-vibe/ex_dna) report with
`.duplication-baseline.json`.

The gate is a ratchet: known baseline clones pass, new clones fail. Removing a
baseline clone also passes and prompts you to update the baseline.

## What it detects

The gate finds exact copies and copies with renamed variables (clone types I
and II) in the root project's `lib/` and `test/`. `.ex_dna.exs` sets the
minimum fragment mass to 30 AST nodes and excludes alias/import/require/use
boilerplate. Viewer and launcher code are outside this baseline.

It does not detect equivalent logic written with different AST structure.

## When the gate fails

Choose one of three responses.

### Extract the shared logic

Extract when copies encode one rule or policy, such as validation, encoding,
or a security primitive. Put the shared behavior in one owner; do not copy a
helper into another module to avoid an import.

### Suppress it, with a reason

Suppress when independent contracts happen to look alike and extraction would
couple them. Put a reason above one copy:

```elixir
# ex_dna:disable-for-next-line — owner-specific lifecycle fallback
def handle_cast(_request, state), do: {:noreply, state}
```

Suppressing one occurrence removes the clone from the report. Common examples
are per-module OTP callbacks, independently owned external-contract adapters,
and test setup intentionally kept local.

### Re-bless the baseline

```bash
scripts/duplication_gate.sh bless
```

Bless only real duplication accepted as debt. A baseline entry records no
reason, so deliberate repetition should use a suppression comment instead.

After removing duplication, `check` prints `resolved` and passes. Run `bless`
to lock in the smaller baseline.

## Fingerprints and churn

A clone key covers its type, file paths, and AST-rendered bodies, not line
numbers. Moving unrelated lines does not re-key it. Comments are invisible;
literal string and sigil content remains significant.

Editing a known clone re-keys it. The gate reports `shrunk` only when it can
pair the result one-to-one with old debt and prove that no file, occurrence,
mass, or exactness was added. Ambiguous changes fail as new duplication.

## Running it directly

```bash
scripts/duplication_gate.sh check    # what CI runs
scripts/duplication_gate.sh bless    # record the current set

mix ex_dna lib/ test/                # full human-readable report
mix ex_dna.explain 3 lib/ test/      # extraction breakdown for one clone
```

Configuration lives in `.ex_dna.exs`. ExDNA cache files are machine-local and
ignored.

## Testing an unreleased ExDNA checkout

Normal development and package builds resolve ExDNA from Hex. To test an
unreleased checkout without changing `mix.lock`, point the complete build at
that checkout:

```bash
mix deps.get
export PTC_EX_DNA_PATH=/absolute/path/to/ex_dna
mix deps.compile ex_dna --force
scripts/duplication_gate.sh check
```

The override also enables ExDNA's opt-in result cache. Fetch the locked graph
before setting it: `mix deps.get` with the override active may re-resolve the
candidate's development dependencies. Keep the variable set for every Mix
command in that build. To return to Hex:

```bash
unset PTC_EX_DNA_PATH
mix deps.compile ex_dna --force
```

CI separately tests a pinned candidate checkout cold and warm and verifies that
the warm run does not rewrite either cache file. Ordinary jobs remain on Hex.
