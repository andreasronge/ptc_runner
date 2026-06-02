# Releasing `ptc_runner`

`ptc_runner` is the root Hex package. Stable root releases use `v*` tags and
are published to Hex.pm and HexDocs by `.github/workflows/release.yml`.

The sibling MCP server has a separate release path and tag namespace. Use
`mcp_server/RELEASING.md` for `ptc_runner_mcp` releases.

## Release Gate

Prepare releases from a clean branch merged to `main`. Before creating a tag,
update:

- `mix.exs` `version:`
- `CHANGELOG.md` with a `## [X.Y.Z]` section

Then run the local gates:

```bash
mix precommit
mix prepush
mix release.smoke
```

`mix release.smoke` does not publish anything. It runs the deterministic root
release checks, root and MCP soak tests, verifies generated artifacts and Hex
package contents, checks the deterministic performance baseline, builds the
sibling `mcp_server` release, and smoke-tests the MCP release binary.

Set `PTC_SOAK_ITERATIONS` only when intentionally shortening or lengthening the
soak pass:

```bash
PTC_SOAK_ITERATIONS=3000 mix release.smoke
```

The default is `3000`, matching the release workflow.

## CI Dry Run

After the release commit is on `main`, manually run the `Release` workflow from
GitHub Actions before tagging.

First run the deterministic release gate:

```text
workflow_dispatch
skip_llm: true
llm_runs: 1
```

Confirm these jobs pass:

- `test`
- `soak`
- `integrity`
- `docs`
- `perf`

Confirm `publish` is skipped on manual dispatch and that the
`release-checks-report` artifact was uploaded.

Optionally run the same workflow again with `skip_llm: false` and `llm_runs: 1`
when `OPENROUTER_API_KEY` is configured. The `llm-smoke` job is informational
and does not gate publishing.

## Publish

Create the root release tag only after the local gates and CI dry run are green:

```bash
git checkout main
git pull --ff-only
git tag vX.Y.Z
git push origin vX.Y.Z
```

Pushing `vX.Y.Z` triggers `.github/workflows/release.yml`. The `publish` job
runs only for tag pushes whose ref starts with `refs/tags/v`, and it depends on:

- `test`
- `soak`
- `integrity`
- `docs`
- `perf`

The publish job runs:

```bash
mix hex.build
mix hex.publish --yes
mix hex.publish docs --yes
```

It requires `HEX_API_KEY` in GitHub Actions secrets.

## Post-Publish Checks

After the tag workflow completes, verify:

- The `publish` job succeeded.
- The `release-checks-report` artifact exists.
- `https://hex.pm/packages/ptc_runner` shows version `X.Y.Z`.
- `https://hexdocs.pm/ptc_runner` has the updated docs.
- The `CHANGELOG.md` entry is correct on `main`.

## Manual Fallback

Prefer the GitHub Actions publish path. If Actions publishing is unavailable,
run the same local gates, then publish from a clean checkout on the tagged
commit:

```bash
mix hex.build
mix hex.publish --yes
mix hex.publish docs --yes
```

Manual publishing still requires a valid Hex API key and should only be done
after the release workflow has been run manually with publishing skipped.

## Notes For Agents

Do not create or push a release tag without explicit user confirmation. Report
the exact version, current commit SHA, local gate results, and CI dry-run status
before asking for tag approval.

Do not use `mcp-v*` tags for root `ptc_runner` releases. Do not use `v*` tags
for `ptc_runner_mcp` releases.
