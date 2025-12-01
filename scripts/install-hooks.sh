#!/bin/bash

echo "Installing git hooks..."

# Determine git hooks directory (handles worktrees)
if [ -f .git ]; then
  # This is a worktree, read the gitdir
  GITDIR=$(cat .git | sed 's/gitdir: //')
  HOOKS_DIR="$GITDIR/hooks"
else
  # Regular git repo
  HOOKS_DIR=".git/hooks"
fi

# Create hooks directory if it doesn't exist
mkdir -p "$HOOKS_DIR"

# Copy pre-commit hook
if [ -f scripts/pre-commit.template ]; then
  cp scripts/pre-commit.template "$HOOKS_DIR/pre-commit"
  chmod +x "$HOOKS_DIR/pre-commit"
  echo "✅ Pre-commit hook installed at $HOOKS_DIR/pre-commit"
else
  echo "❌ Template not found: scripts/pre-commit.template"
  exit 1
fi

echo ""
echo "Git hooks installed successfully!"
echo ""
echo "To bypass pre-commit checks (not recommended):"
echo "  git commit --no-verify"
