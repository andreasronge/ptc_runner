---
name: release
description: Run the full release process for PtcRunner - validates, bumps version, commits, tags, and pushes
disable-model-invocation: true
argument-hint: [version e.g. 0.7.0]
allowed-tools: Bash, Read, Edit, Grep, Glob
---

# PtcRunner Release Process

Release version **$ARGUMENTS** of PtcRunner. Follow every step in order. Stop and report if any step fails.

## Prerequisites

- This skill releases the **root `ptc_runner`** Hex package (`v*` tags). For the
  MCP server (`ptc_runner_mcp`), use `mcp_server/RELEASING.md` (`mcp-v*` tags).
  `docs/RELEASING.md` is the authoritative root release checklist.
- `HEX_API_KEY` secret must be configured in GitHub repo settings
- The `release.yml` GitHub Action handles publishing after push

## Step 1: Pre-flight checks

Run these checks and stop on first failure:

1. Confirm on `main` branch
2. `git fetch origin main` and confirm local is not behind remote
3. Confirm working directory is clean (except CHANGELOG.md is allowed)
4. Confirm tag `v$ARGUMENTS` does not already exist

## Step 2: Validate CHANGELOG.md

1. Check that CHANGELOG.md has been modified (unstaged or staged changes)
2. Check it contains a heading `## [$ARGUMENTS]`
3. If either check fails, tell the user to update CHANGELOG.md first:
   - Show recent commits since last tag: `git log $(git describe --tags --abbrev=0)..HEAD --oneline`
   - Stop and wait for the user to update CHANGELOG.md

## Step 3: Quality checks

Run the authoritative local release gate from `docs/RELEASING.md` (the source of
truth, together with `.github/workflows/release.yml`). Run each in order and fix
all issues before proceeding:

1. `mix precommit` - format, compile (warnings-as-errors), credo, schema, spec, tests
2. `mix prepush` - dialyzer, unused-deps
3. `mix release.smoke` - deterministic root release checks, root + MCP soak,
   `mix hex.build` package-content verification, schema/spec/bench baselines,
   `mix docs --warnings-as-errors`, and the sibling `mcp_server` release smoke

`mix release.smoke` publishes nothing and supersedes the standalone `mix docs` /
`mix hex.build` steps (set `PTC_SOAK_ITERATIONS` to tune soak duration; default
`3000`). After the release commit lands on `main`, run the `Release` workflow
manually with `skip_llm: true` as a CI dry run before tagging - see
`docs/RELEASING.md`.

## Step 4: Version bump

1. Read current version from `mix.exs`
2. If it differs from $ARGUMENTS, update the `version:` field in `mix.exs` to `"$ARGUMENTS"`
3. Search for the old version string in docs and livebooks: `grep -r 'OLD_VERSION' README.md livebooks/ docs/`
4. Update any `{:ptc_runner, "~> OLD_VERSION"}` references to `"~> $ARGUMENTS"` in README.md and livebooks

## Step 5: Commit, tag, and push

Ask the user for confirmation before proceeding. Show:
- Version: $ARGUMENTS
- Tag: v$ARGUMENTS
- Files that will be committed (`git status --short`)

After confirmation:

1. Stage all changed files: `git add mix.exs CHANGELOG.md` (and any other modified files)
2. Commit with message: `chore: prepare release $ARGUMENTS`
3. Create annotated tag: `git tag -a "v$ARGUMENTS" -m "Release $ARGUMENTS"`
4. Push: `git push && git push --tags`

## Step 6: Done

Report success and remind the user:
- The GitHub Action will verify the tag, run tests, publish to Hex.pm, and publish docs to HexDocs
- Monitor at: https://github.com/andreasronge/ptc_runner/actions

## Version Guidelines

Follow Semantic Versioning:
- **MAJOR** (1.0.0): Breaking API changes
- **MINOR** (0.2.0): New features, backwards compatible
- **PATCH** (0.1.1): Bug fixes, backwards compatible
