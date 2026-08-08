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
# rebase.
#
# This is only a fallback now: ordinary branches no longer regenerate the
# projection, so they no longer collide on it. Staleness is caught by the
# release gate, which is also the only place it matters. Finish with
# `mix regen` on main before tagging.
git config merge.ptc-generated.name \
  "keep one side of a generated projection; regenerate with mix regen"
git config merge.ptc-generated.driver true
echo "✅ Generated-file merge driver registered (merge.ptc-generated)"
echo ""

echo "Installing git hooks..."

# Resolve the effective hooks directory through Git so linked worktrees and a
# configured core.hooksPath use the same location Git itself will execute.
HOOKS_DIR=$(git rev-parse --git-path hooks)

# A clone that disables hooks by pointing core.hooksPath at a non-directory
# resolves to a path no hook can occupy. Every copy below would fail one line
# at a time while the script still reported success, so establish that the
# destination is usable before claiming anything about it.
if ! mkdir -p "$HOOKS_DIR" 2>/dev/null || [ ! -d "$HOOKS_DIR" ]; then
  echo "❌ Cannot install hooks: $HOOKS_DIR is not a usable directory"

  CONFIGURED_HOOKS_PATH=$(git config --get core.hooksPath)
  if [ -n "$CONFIGURED_HOOKS_PATH" ]; then
    echo "   core.hooksPath is set to: $CONFIGURED_HOOKS_PATH"
    echo "   Clear it to restore hooks: git config --unset core.hooksPath"
  fi

  echo "   The merge driver above is registered regardless."
  exit 1
fi

# Install a stable wrapper; the implementation remains tracked in .githooks/.
# Failing to copy or mark a hook executable leaves the clone ungated, so treat
# either as fatal rather than printing a checkmark over a failed command.
install_hook() {
  source_path=$1
  hook_name=$2
  destination="$HOOKS_DIR/$hook_name"

  if ! cp "$source_path" "$destination"; then
    echo "❌ Failed to copy $source_path to $destination"
    exit 1
  fi

  if ! chmod +x "$destination"; then
    echo "❌ Failed to make $destination executable"
    exit 1
  fi

  echo "✅ ${hook_name} hook installed at $destination"
}

if [ -f scripts/pre-commit.template ]; then
  install_hook scripts/pre-commit.template pre-commit
else
  echo "❌ Template not found: scripts/pre-commit.template"
  exit 1
fi

if [ -f scripts/pre-push ]; then
  install_hook scripts/pre-push pre-push
else
  echo "⚠️  Pre-push hook not found: scripts/pre-push (skipping)"
fi

echo ""
echo "Git hooks installed successfully!"
echo ""
echo "Do not bypass failed hooks. Re-run the reported command to diagnose them."
echo "For scheduler pressure during pre-push tests, retry with:"
echo "  PTC_PRE_PUSH_MAX_CASES=2 git push"
