#!/bin/bash
# Release script for PtcRunner
# Usage: ./scripts/release.sh 0.3.3
#        ./scripts/release.sh 0.3.3 --dry-run
#
# Prerequisites: Run ./scripts/update-changelog.sh first

set -e

VERSION="${1:-}"
DRY_RUN="${2:-}"

if [ -z "$VERSION" ]; then
  echo "Usage: ./scripts/release.sh <version> [--dry-run]"
  echo "Example: ./scripts/release.sh 0.3.3"
  echo "         ./scripts/release.sh 0.3.3 --dry-run"
  exit 1
fi

# Validate version format (semver)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Version must be in semver format (e.g., 0.3.3)"
  exit 1
fi

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "=== PtcRunner Release $VERSION (DRY RUN) ==="
else
  echo "=== PtcRunner Release $VERSION ==="
fi
echo ""

# 1. Check we're on main branch
echo "Checking branch..."
BRANCH=$(git branch --show-current)
if [ "$BRANCH" != "main" ]; then
  echo "Error: Must be on main branch (currently on: $BRANCH)"
  exit 1
fi
echo "✓ On main branch"

# 2. Check local is not behind remote
echo "Checking remote sync..."
git fetch origin main --quiet
BEHIND=$(git rev-list --count HEAD..origin/main)
if [ "$BEHIND" -gt 0 ]; then
  echo "Error: Local branch is behind origin/main by $BEHIND commits"
  echo "Run: git pull origin main"
  exit 1
fi
AHEAD=$(git rev-list --count origin/main..HEAD)
if [ "$AHEAD" -gt 0 ]; then
  echo "✓ Local is $AHEAD commits ahead of remote (will be pushed)"
else
  echo "✓ In sync with remote"
fi

# 3. Check working directory is clean except CHANGELOG.md
echo "Checking working directory..."
DIRTY_FILES=$(git status --porcelain | grep -v "^ M CHANGELOG.md" | grep -v "^M  CHANGELOG.md" || true)
if [ -n "$DIRTY_FILES" ]; then
  if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "⚠ Working directory has uncommitted changes (skipped in dry-run):"
    echo "$DIRTY_FILES"
  else
    echo "Error: Working directory has uncommitted changes (other than CHANGELOG.md):"
    echo "$DIRTY_FILES"
    exit 1
  fi
else
  echo "✓ Working directory clean"
fi

# 4. Check CHANGELOG.md has been modified
echo "Checking CHANGELOG.md..."
if ! git status --porcelain | grep -q "CHANGELOG.md"; then
  echo "Error: CHANGELOG.md has not been modified"
  echo "Run: ./scripts/update-changelog.sh $VERSION"
  exit 1
fi
echo "✓ CHANGELOG.md modified"

# 5. Check CHANGELOG.md contains the version
if ! grep -q "## \[$VERSION\]" CHANGELOG.md; then
  echo "Error: CHANGELOG.md does not contain version $VERSION"
  echo "Expected to find: ## [$VERSION]"
  exit 1
fi
echo "✓ CHANGELOG.md contains version $VERSION"

# 6. Check tag doesn't already exist
if git tag -l | grep -q "^v$VERSION$"; then
  echo "Error: Tag v$VERSION already exists"
  exit 1
fi
echo "✓ Tag v$VERSION is available"

# 7. Run format check
echo ""
echo "Running format check..."
if ! mix format --check-formatted; then
  echo "Error: Code is not formatted. Run: mix format"
  exit 1
fi
echo "✓ Code formatted"

# 8. Run compiler with warnings as errors
echo ""
echo "Running compiler..."
if ! mix compile --warnings-as-errors; then
  echo "Error: Compilation failed or has warnings"
  exit 1
fi
echo "✓ Compilation successful"

# 9. Run tests
echo ""
echo "Running tests..."
if ! mix test; then
  echo "Error: Tests failed"
  exit 1
fi
echo "✓ Tests passed"

# 10. Run credo (if available)
echo ""
echo "Running credo..."
if mix help credo > /dev/null 2>&1; then
  if ! mix credo --strict; then
    echo "Error: Credo found issues"
    exit 1
  fi
  echo "✓ Credo passed"
else
  echo "⊘ Credo not installed, skipping"
fi

# 11. Check docs build without warnings
echo ""
echo "Building docs..."
DOC_OUTPUT=$(mix docs 2>&1)
if echo "$DOC_OUTPUT" | grep -qi "warning"; then
  echo "Error: Documentation has warnings:"
  echo "$DOC_OUTPUT" | grep -i "warning"
  exit 1
fi
echo "✓ Docs build clean"

# 12. Verify hex package builds
echo ""
echo "Building hex package..."
if ! mix hex.build; then
  echo "Error: Hex package build failed"
  exit 1
fi
echo "✓ Hex package builds"

# 13. Update version in mix.exs
echo ""
echo "Checking version in mix.exs..."
CURRENT_VERSION=$(grep -E '^\s+version:' mix.exs | sed 's/.*"\([^"]*\)".*/\1/')
if [ "$CURRENT_VERSION" = "$VERSION" ]; then
  echo "✓ Version already set to $VERSION"
elif [ "$DRY_RUN" = "--dry-run" ]; then
  echo "⊘ Would update version: $CURRENT_VERSION → $VERSION (skipped in dry-run)"
else
  sed -i '' "s/version: \"$CURRENT_VERSION\"/version: \"$VERSION\"/" mix.exs
  echo "✓ Updated version: $CURRENT_VERSION → $VERSION"
fi

# 14. Show summary and confirm
echo ""
echo "=== Release Summary ==="
echo "Version: $VERSION"
echo "Tag: v$VERSION"
echo ""
echo "Files to commit:"
git status --short
echo ""

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "=== DRY RUN COMPLETE ==="
  echo "All validation checks passed. Run without --dry-run to release."
  exit 0
fi

read -p "Proceed with commit, tag, and push? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted. Changes remain staged."
  exit 1
fi

# 15. Commit, tag, and push
echo ""
echo "Committing..."
git add -A
git commit -m "$(cat <<EOF
chore: prepare release $VERSION

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"

echo "Tagging..."
git tag -a "v$VERSION" -m "Release $VERSION"

echo "Pushing..."
git push && git push --tags

echo ""
echo "=== Release $VERSION complete! ==="
echo ""
echo "The GitHub Action will now:"
echo "  1. Verify tag matches mix.exs version"
echo "  2. Run tests"
echo "  3. Publish to Hex.pm"
echo "  4. Publish docs to HexDocs"
echo ""
echo "Monitor at: https://github.com/andreasronge/ptc_runner/actions"
