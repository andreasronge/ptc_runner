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

## Step 3: Check usage-rules.md is current

1. Read `usage-rules.md` and check the public API surface it documents
2. Check if any of these have changed since the last release tag:
   - `lib/ptc_runner/sub_agent.ex` (SubAgent.new/1 options, run/2 options)
   - `lib/ptc_runner/tool.ex` (tool definition formats)
   - `lib/ptc_runner/lisp/` (new built-in functions or changed behavior)
   - `docs/signature-syntax.md` (signature type system)
3. If there are significant API changes not reflected in usage-rules.md, stop and tell the user what needs updating
4. Also run `mix usage_rules.sync AGENTS.md --all --yes` to ensure consumer rules are current

## Step 4: Quality checks

Run each and fix issues before proceeding:

1. `mix format --check-formatted` - fix with `mix format` if needed
2. `mix compile --warnings-as-errors`
3. `mix credo --strict`
4. `mix test`
5. `cd demo && mix test` (demo tests)
6. `mix docs` - verify no warnings in output
7. `mix hex.build` - verify package builds

## Step 5: Version bump

1. Read current version from `mix.exs`
2. If it differs from $ARGUMENTS, update the `version:` field in `mix.exs` to `"$ARGUMENTS"`

## Step 6: Commit, tag, and push

Ask the user for confirmation before proceeding. Show:
- Version: $ARGUMENTS
- Tag: v$ARGUMENTS
- Files that will be committed (`git status --short`)

After confirmation:

1. Stage all changed files: `git add mix.exs CHANGELOG.md AGENTS.md` (and any other modified files)
2. Commit with message: `chore: prepare release $ARGUMENTS`
3. Create annotated tag: `git tag -a "v$ARGUMENTS" -m "Release $ARGUMENTS"`
4. Push: `git push && git push --tags`

## Step 7: Done

Report success and remind the user:
- The GitHub Action will verify the tag, run tests, publish to Hex.pm, and publish docs to HexDocs
- Monitor at: https://github.com/andreasronge/ptc_runner/actions

## Version Guidelines

Follow Semantic Versioning:
- **MAJOR** (1.0.0): Breaking API changes
- **MINOR** (0.2.0): New features, backwards compatible
- **PATCH** (0.1.1): Bug fixes, backwards compatible
