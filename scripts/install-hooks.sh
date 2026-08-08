#!/bin/bash

# Register the merge driver named by `.gitattributes` first, and independently
# of hook installation. Merge drivers live in local config and cannot be
# committed, and this must still land when hook installation is skipped or
# fails -- a clone that sets `core.hooksPath` elsewhere resolves the hooks
# directory to a path this script cannot write.
#
# `true` leaves Git's staged side in place rather than writing conflict markers
# into a generated file whose hashes cannot be merged textually. Regenerating
# here instead would recompile the project once per conflicting commit during a
# rebase; `mix precommit` already runs `ptc.gen_semantic_revision --check`, so
# staleness is caught regardless. Finish with `mix regen`.
git config merge.ptc-generated.name \
  "keep one side of a generated projection; regenerate with mix regen"
git config merge.ptc-generated.driver true
echo "✅ Generated-file merge driver registered (merge.ptc-generated)"
echo ""

echo "Installing git hooks..."

# Resolve the effective hooks directory through Git so linked worktrees and a
# configured core.hooksPath use the same location Git itself will execute.
HOOKS_DIR=$(git rev-parse --git-path hooks)

# Create hooks directory if it doesn't exist
mkdir -p "$HOOKS_DIR"

# Install a stable wrapper; the implementation remains tracked in .githooks/.
if [ -f scripts/pre-commit.template ]; then
  cp scripts/pre-commit.template "$HOOKS_DIR/pre-commit"
  chmod +x "$HOOKS_DIR/pre-commit"
  echo "✅ Pre-commit hook installed at $HOOKS_DIR/pre-commit"
else
  echo "❌ Template not found: scripts/pre-commit.template"
  exit 1
fi

# Install a stable wrapper; the implementation remains tracked in .githooks/.
if [ -f scripts/pre-push ]; then
  cp scripts/pre-push "$HOOKS_DIR/pre-push"
  chmod +x "$HOOKS_DIR/pre-push"
  echo "✅ Pre-push hook installed at $HOOKS_DIR/pre-push"
else
  echo "⚠️  Pre-push hook not found: scripts/pre-push (skipping)"
fi

echo ""
echo "Git hooks installed successfully!"
echo ""
echo "Do not bypass failed hooks. Re-run the reported command to diagnose them."
echo "For scheduler pressure during pre-push tests, retry with:"
echo "  PTC_PRE_PUSH_MAX_CASES=2 git push"
