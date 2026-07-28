#!/bin/bash

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
echo "To bypass pre-commit checks (not recommended):"
echo "  git commit --no-verify"
echo ""
echo "To bypass pre-push checks (not recommended):"
echo "  git push --no-verify"
