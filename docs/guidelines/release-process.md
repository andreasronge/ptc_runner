# Release Process

## Prerequisites

- `git-cliff` installed: `brew install git-cliff`
- `HEX_API_KEY` secret configured in GitHub repo settings

## Release Steps

### 1. Update Changelog

```bash
# Preview unreleased changes
git-cliff --unreleased

# Generate full changelog
git-cliff --tag vX.Y.Z --output CHANGELOG.md

# Review and edit as needed
```

### 2. Update Version

Edit `mix.exs`:
```elixir
version: "X.Y.Z",
```

### 3. Commit and Tag

```bash
git add -A
git commit -m "chore: prepare release X.Y.Z"
git tag -a vX.Y.Z -m "Release X.Y.Z"
git push && git push --tags
```

### 4. Automated Publishing

The `release.yml` workflow automatically:
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
