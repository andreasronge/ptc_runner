#!/bin/bash
# Update CHANGELOG.md using Claude to intelligently summarize changes
# Usage: ./scripts/update-changelog.sh [version]
# Example: ./scripts/update-changelog.sh 0.3.3

set -e

VERSION="${1:-}"
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

if [ -z "$LAST_TAG" ]; then
  echo "Error: No previous tag found"
  exit 1
fi

echo "Generating changelog from $LAST_TAG to HEAD..."

# Get feat and fix commits only, with full message (first line)
COMMITS=$(git log "$LAST_TAG"..HEAD --oneline --no-merges | grep -E "^[a-f0-9]+ (feat|fix):" || true)

if [ -z "$COMMITS" ]; then
  echo "No feat/fix commits found since $LAST_TAG"
  exit 0
fi

echo "Found commits:"
echo "$COMMITS"
echo ""

TODAY=$(date +%Y-%m-%d)

# Create prompt file for Claude (avoids shell escaping issues)
PROMPT_FILE=$(mktemp)
trap "rm -f $PROMPT_FILE" EXIT

cat > "$PROMPT_FILE" << EOF
Update CHANGELOG.md to add version ${VERSION:-Unreleased}.

## Commits since $LAST_TAG:
$COMMITS

## Instructions:
1. Add a new section at the TOP (after the header, before previous releases)
2. Use format: ## [${VERSION:-Unreleased}] - $TODAY
3. Group into 'Added' (feat:) and 'Fixed' (fix:) sections
4. Write USER-FACING descriptions only - skip anything about:
   - CI/workflows, GitHub actions, demo code, internal tooling
   - Test infrastructure, benchmarks, pre-commit hooks
5. Group related small fixes into single descriptive bullet points
6. Remove commit hashes and prefixes (feat:, fix:)
7. Be concise - this is for library users, not contributors
8. If ALL changes are internal, just add a short note like 'Internal improvements'

Edit CHANGELOG.md now.
EOF

echo "Running Claude (Haiku) to update CHANGELOG..."
cat "$PROMPT_FILE" | claude -p --model haiku --allowedTools "Read,Edit"

echo ""
echo "Done! Review CHANGELOG.md and commit when ready."
