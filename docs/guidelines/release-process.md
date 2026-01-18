# Release Process

## Prerequisites

- `HEX_API_KEY` secret configured in GitHub repo settings

## Quick Release (Recommended)

```bash
# Step 1: Update CHANGELOG.md manually with changes since last tag
# Use: git log v0.5.0..HEAD --oneline | grep -E "^[a-f0-9]+ (feat|fix):"

# Step 2: Run release script (validates, bumps version, commits, tags, pushes)
./scripts/release.sh 0.5.1
```

## What the Script Does

### `release.sh`
Runs these checks before releasing:
1. ✓ On main branch
2. ✓ In sync with remote
3. ✓ Working directory clean (except CHANGELOG.md)
4. ✓ CHANGELOG.md modified with correct version
5. ✓ Tag doesn't already exist
6. ✓ Code formatted (`mix format --check-formatted`)
7. ✓ No compiler warnings (`mix compile --warnings-as-errors`)
8. ✓ Tests pass (`mix test`)
9. ✓ Credo passes (if installed)
10. ✓ Docs build without warnings (`mix docs`)
11. ✓ Hex package builds (`mix hex.build`)

Then:
- Updates version in `mix.exs`
- Commits with release message
- Creates annotated tag
- Pushes to origin

## Automated Publishing

The `release.yml` GitHub Action automatically:
1. Verifies tag matches `mix.exs` version
2. Runs tests
3. Publishes package to Hex.pm
4. Publishes docs to HexDocs

## Manual Publishing (if needed)

```bash
mix hex.publish
mix hex.publish docs
```

## Version Guidelines

Follow [Semantic Versioning](https://semver.org/):
- **MAJOR** (1.0.0): Breaking API changes
- **MINOR** (0.2.0): New features, backwards compatible
- **PATCH** (0.1.1): Bug fixes, backwards compatible
