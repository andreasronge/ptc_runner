#!/usr/bin/env bash
#
# Worktree lifecycle.
#
#   scripts/worktree.sh gc [--yes] [--no-fetch] [--no-issues]
#   scripts/worktree.sh new <branch> [issue-number]
#   scripts/worktree.sh seed [<dir>]
#
# A worktree is a cache, not an artifact. `git worktree remove` never deletes
# the branch, so a checkout whose commits are already in `origin/main` costs a
# few hundred megabytes of `_build` and buys nothing -- recreate it with one
# `git worktree add` if you need it back. `gc` reclaims exactly those and
# refuses to touch anything holding work.
#
# The reap decision is derived from git state, never from a naming convention,
# so it covers the worktrees Codex and Claude Code create under their own roots
# as well as the ones you made by hand.

set -euo pipefail

BASE="origin/main"
DO_REMOVE=0
DO_FETCH=1
DO_ISSUES=1
IDLE_HOURS=24
QUIET=0

die() {
  echo "❌ $*" >&2
  exit 1
}

mtime_of() {
  case "$(uname -s)" in
    Darwin) stat -f %m "$1" 2>/dev/null || printf '0' ;;
    *) stat -c %m "$1" 2>/dev/null || printf '0' ;;
  esac
}

# A worktree stopped part-way through an operation is not idle, however clean
# it looks. A rebase that has checked out the upstream tip but not yet replayed
# its commits reads as "merged, nothing uncommitted" for the whole window --
# observed live, on a worktree an agent was actively working in.
interrupted_op() {
  local gitdir="$1"
  if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]; then
    printf 'rebase in progress'
  elif [ -f "$gitdir/MERGE_HEAD" ]; then
    printf 'merge in progress'
  elif [ -f "$gitdir/CHERRY_PICK_HEAD" ]; then
    printf 'cherry-pick in progress'
  elif [ -f "$gitdir/REVERT_HEAD" ]; then
    printf 'revert in progress'
  elif [ -f "$gitdir/BISECT_LOG" ]; then
    printf 'bisect in progress'
  fi
}

# Hours since the worktree's HEAD last moved. The rebase window above is only
# minutes wide, so recent activity is the guard that actually protects it.
#
# Deliberately not the index: `git status` rewrites it, so any read-only look
# -- this script's own dirt check, an editor, another agent -- would reset the
# clock and nothing would ever be reapable. The reflog moves only when a ref
# really moves.
idle_hours() {
  local gitdir="$1" now newest=0 stamp file
  now="$(date +%s)"
  for file in "$gitdir/logs/HEAD" "$gitdir/HEAD"; do
    stamp="$(mtime_of "$file")"
    if [ "$stamp" -gt "$newest" ]; then
      newest="$stamp"
    fi
  done
  printf '%s' $(((now - newest) / 3600))
}

# The main worktree is always the first record git prints. Strip the prefix
# rather than taking field 2 so paths containing spaces survive.
main_worktree() {
  git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /, ""); print; exit}'
}

# Flatten `git worktree list --porcelain` into `path<TAB>head<TAB>branch<TAB>flags`.
collect_worktrees() {
  local line path="" head="" branch="" flags=""
  emit() {
    if [ -n "$path" ]; then
      printf '%s\t%s\t%s\t%s\n' "$path" "$head" "$branch" "$flags"
    fi
  }
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }" ;;
      "HEAD "*) head="${line#HEAD }" ;;
      "branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
      "detached") branch="" ;;
      "locked"*) flags="${flags}locked," ;;
      "prunable"*) flags="${flags}prunable," ;;
      "")
        emit
        path=""; head=""; branch=""; flags=""
        ;;
    esac
  done < <(git worktree list --porcelain)
  emit
}

# Count the things in a worktree that represent unsaved work.
#
# An untracked *symlink* does not: several worktrees point `deps` at the main
# checkout to save disk, and `.gitignore`'s `/deps` cannot match a symlink in
# every git version. Everything else counts, including untracked directories.
worktree_dirt() {
  local wt="$1" line status entry count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    status="${line:0:2}"
    entry="${line:3}"
    case "$entry" in
      '"'*'"') entry="${entry%\"}"; entry="${entry#\"}" ;;
    esac
    if [ "$status" = "??" ] && [ -L "$wt/$entry" ]; then
      continue
    fi
    count=$((count + 1))
  done < <(git -C "$wt" status --porcelain 2>/dev/null || true)
  printf '%s' "$count"
}

# Issue number carried by a branch name: `issue-1244`, `issue_1244`, or a
# trailing bare-number segment like `check/1243`.
issue_of_branch() {
  local branch="$1" number
  number=$(printf '%s' "$branch" | sed -nE 's/.*[Ii]ssue[-_/]?([0-9]+).*/\1/p' | head -1)
  if [ -z "$number" ]; then
    number=$(printf '%s' "$branch" | sed -nE 's#.*/([0-9]+)$#\1#p' | head -1)
  fi
  printf '%s' "$number"
}

issue_state() {
  local number="$1"
  gh issue view "$number" --json state --jq .state 2>/dev/null || true
}

# ----------------------------------------------------------------------
# Seeding: copy build artifacts from the main checkout into a worktree.
#
# The main checkout is the cache. Its artifacts are transferable to another
# checkout on this machine when the toolchain (mise.toml) and dependency sets
# (the lockfiles) are byte-identical -- OS and architecture are constant on
# one machine. Correctness never rests on that key: Mix revalidates deps and
# _build against mix.lock and source digests, and dialyxir revalidates the
# project PLT against the module set, so a stale seed costs a rebuild, never
# a wrong answer. Each worktree owns its copies outright -- nothing writable
# is ever shared, so concurrent gates cannot race.
# ----------------------------------------------------------------------

SEED_KEY_FILES=(mise.toml mix.lock ptc_viewer/mix.lock ptc_runner_launcher/mix.lock)

# deps/_build make `mix deps.get` and `mix compile` incremental in all three
# Mix projects; priv/plts carries the writable project PLT so dialyxir
# updates it instead of re-adding ~1,500 modules (the core PLT is already
# shared machine-wide via ~/.cache/ptc_runner -- see mix.exs).
SEED_ARTIFACTS=(
  deps
  _build
  priv/plts
  ptc_viewer/deps
  ptc_viewer/_build
  ptc_runner_launcher/deps
  ptc_runner_launcher/_build
)

# Copy-on-write clone where the filesystem supports it (APFS, btrfs, XFS);
# plain copy otherwise. A clone is near-instant and shares blocks until
# either side writes.
clone_tree() {
  local src="$1" dst="$2"
  case "$(uname -s)" in
    Darwin)
      if ! cp -Rc "$src" "$dst" 2>/dev/null; then
        rm -rf "${dst:?}"
        cp -R "$src" "$dst"
      fi
      ;;
    *) cp -R --reflink=auto "$src" "$dst" ;;
  esac
}

seed_worktree() {
  local src="$1" dst="$2" file artifact staging tmp seeded=0 start=$SECONDS

  for file in "${SEED_KEY_FILES[@]}"; do
    if ! cmp -s "$src/$file" "$dst/$file"; then
      echo "🌱 Seed skipped: $file differs from the main checkout's copy"
      return 0
    fi
  done

  # Stage each copy and promote it with an atomic same-volume rename, so an
  # interrupted seed can never leave a partial tree that a later run skips as
  # "already present". The staging path carries this process's PID so two
  # concurrent seeds of one destination cannot delete each other's work; a
  # leftover dir from a crash is gitignored, inert, and safe to remove.
  staging="$dst/.worktree-seed-tmp.$$"
  rm -rf "$staging"

  for artifact in "${SEED_ARTIFACTS[@]}"; do
    tmp="$staging/${artifact//\//__}"
    if [ -L "$src/$artifact" ]; then
      echo "   ⏭️  $artifact — main checkout's copy is a symlink"
    elif [ ! -d "$src/$artifact" ]; then
      echo "   ⏭️  $artifact — not built in the main checkout"
    elif [ -e "$dst/$artifact" ] || [ -L "$dst/$artifact" ]; then
      echo "   ⏭️  $artifact — already present"
    elif mkdir -p "$staging" "$(dirname "$dst/$artifact")" &&
      clone_tree "$src/$artifact" "$tmp" &&
      scrub_seed_artifact "$artifact" "$tmp" &&
      promote_seed_artifact "$tmp" "$dst/$artifact"; then
      echo "   🌱 $artifact"
      seeded=$((seeded + 1))
    else
      echo "   ⚠️  $artifact — not promoted (copy failed, torn PLT, or lost a race)"
    fi
  done

  rm -rf "$staging"
  echo "🌱 Seeded ${seeded} artifact(s) from $src in $((SECONDS - start))s"
}

# Two PLT-specific guards before promotion:
#
# 1. dialyxir skips its PLT check entirely when the stored dependency hash
#    matches (check_hash?/1 in mix/tasks/dialyzer.ex), and that hash covers
#    the app set, not the PLT file's integrity — drop it so the first
#    dialyzer run in the new worktree always revalidates the copied PLT.
# 2. A PLT cloned while the main checkout's dialyzer is rewriting it can be
#    a torn copy, and dialyxir raises on an invalid PLT rather than
#    rebuilding it — each staged PLT must prove it decodes before promotion.
scrub_seed_artifact() {
  local artifact="$1" tmp_tree="$2" plt
  if [ "$artifact" = "priv/plts" ]; then
    rm -f "$tmp_tree"/*.hash
    for plt in "$tmp_tree"/*.plt; do
      [ -e "$plt" ] || continue
      plt_decodes "$plt" || return 1
    done
  fi
}

# A PLT file is a single external term (#file_plt{}), and binary_to_term
# rejects both truncation and trailing garbage, so a successful decode of the
# staged copy proves the snapshot is complete regardless of what the source's
# writer was doing. Needs erl on PATH; without it the artifact is not seeded.
plt_decodes() {
  PTC_SEED_PLT="$1" erl -noshell -eval '
    P = os:getenv("PTC_SEED_PLT"),
    R = case file:read_file(P) of
          {ok, Bin} -> try binary_to_term(Bin) of _ -> 0 catch _:_ -> 1 end;
          _ -> 1
        end,
    halt(R).' 2>/dev/null
}

# Promotion must be a no-replace operation: a bare `mv` whose destination
# sprang into existence (a concurrent seed) would move the staged tree
# *inside* it and report success. `mkdir` is the atomic claim — it fails on
# any existing entry, symlinks included — and each top-level entry then moves
# in with an atomic same-volume rename. An interruption mid-promotion leaves
# only whole top-level units (whole dep dirs, whole build envs, whole PLTs),
# which Mix and dialyxir treat as merely not-yet-built.
promote_seed_artifact() {
  local tmp="$1" final="$2" entry
  mkdir "$final" 2>/dev/null || return 1
  for entry in "$tmp"/* "$tmp"/.[!.]* "$tmp"/..?*; do
    { [ -e "$entry" ] || [ -L "$entry" ]; } || continue
    mv "$entry" "$final/" || return 1
  done
  rmdir "$tmp"
}

cmd_seed() {
  local dst="${1:-}" main_wt
  main_wt="$(main_worktree)"
  main_wt="$(cd "$main_wt" && pwd -P)"
  if [ -z "$dst" ]; then
    dst="$(git rev-parse --show-toplevel)"
  fi
  [ -d "$dst" ] || die "$dst does not exist"
  # Physical paths: a tmpdir symlink (macOS /var -> /private/var) must not
  # make the same checkout look like two different ones.
  dst="$(cd "$dst" && pwd -P)"
  [ "$dst" != "$main_wt" ] || die "refusing to seed the main checkout from itself"
  seed_worktree "$main_wt" "$dst"
}

cmd_gc() {
  local main_wt current_wt path head branch flags dirt
  local reapable="" held="" unmerged="" count_reapable=0

  main_wt="$(main_worktree)"
  current_wt="$(git rev-parse --show-toplevel)"

  git worktree prune

  if [ "$DO_FETCH" = "1" ]; then
    git fetch -q origin main 2>/dev/null ||
      echo "⚠️  could not fetch origin/main; judging against the local ref"
  fi
  git rev-parse --verify -q "$BASE" >/dev/null ||
    die "$BASE does not exist; nothing to compare against"

  while IFS=$'\t' read -r path head branch flags; do
    local label="${branch:-(detached)}"
    case "$flags" in
      *locked*)
        held="${held}${path}\t${label}\tlocked\n"
        continue
        ;;
    esac
    if [ "$path" = "$main_wt" ] || [ "$path" = "$current_wt" ]; then
      continue
    fi
    local gitdir busy idle
    gitdir="$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null || true)"
    if [ -n "$gitdir" ]; then
      busy="$(interrupted_op "$gitdir")"
      if [ -n "$busy" ]; then
        held="${held}${path}\t${label}\t${busy}\n"
        continue
      fi
      idle="$(idle_hours "$gitdir")"
      if [ "$idle" -lt "$IDLE_HOURS" ]; then
        held="${held}${path}\t${label}\tactive ${idle}h ago\n"
        continue
      fi
    fi
    if ! git merge-base --is-ancestor "$head" "$BASE" 2>/dev/null; then
      unmerged="${unmerged}${path}\t${label}\n"
      continue
    fi
    dirt="$(worktree_dirt "$path")"
    if [ "$dirt" != "0" ]; then
      held="${held}${path}\t${label}\t${dirt} uncommitted change(s)\n"
      continue
    fi
    reapable="${reapable}${path}\t${label}\n"
    count_reapable=$((count_reapable + 1))
  done < <(collect_worktrees)

  if [ "$QUIET" = "1" ]; then
    if [ "$count_reapable" != "0" ]; then
      echo "🧹 ${count_reapable} worktree(s) fully merged and idle — scripts/worktree.sh gc"
    fi
    return 0
  fi

  if [ -n "$held" ]; then
    echo ""
    echo "Kept — in use or holding something:"
    printf '%b' "$held" | while IFS=$'\t' read -r path label reason; do
      printf '  %-56s %-40s %s\n' "$path" "$label" "$reason"
    done
  fi

  if [ -n "$unmerged" ]; then
    echo ""
    echo "Kept — not in $BASE:"
    printf '%b' "$unmerged" | while IFS=$'\t' read -r path label; do
      local number note="" state
      number="$(issue_of_branch "$label")"
      if [ -n "$number" ] && [ "$DO_ISSUES" = "1" ] && command -v gh >/dev/null 2>&1; then
        # Resolved loosely: the number may name an issue or a PR, and either
        # being finished while the branch is still out of main is the signal.
        state="$(issue_state "$number")"
        if [ -n "$state" ] && [ "$state" != "OPEN" ]; then
          note="#${number} is ${state} but the branch is not in ${BASE} — confirm before removing"
        fi
      fi
      printf '  %-56s %-40s %s\n' "$path" "$label" "$note"
    done
  fi

  if [ "$count_reapable" = "0" ]; then
    echo ""
    echo "✅ Nothing to reclaim."
    return 0
  fi

  echo ""
  if [ "$DO_REMOVE" = "1" ]; then
    echo "Removing ${count_reapable} merged, clean worktree(s) — branches are kept:"
  else
    echo "Reclaimable — merged into $BASE, nothing uncommitted (${count_reapable}):"
  fi

  printf '%b' "$reapable" | while IFS=$'\t' read -r path label; do
    if [ "$DO_REMOVE" != "1" ]; then
      printf '  %-56s %s\n' "$path" "$label"
      continue
    fi
    # Cleanliness is already established above; --force only overrides git's
    # own stricter untracked-symlink check.
    if git worktree remove "$path" 2>/dev/null ||
      git worktree remove --force "$path" 2>/dev/null; then
      printf '  ✅ %-53s %s\n' "$path" "$label"
    else
      printf '  ❌ %-53s %s (remove failed)\n' "$path" "$label"
    fi
  done

  if [ "$DO_REMOVE" != "1" ]; then
    echo ""
    echo "Dry run. Re-run with --yes to remove them. Branches are never deleted."
  fi
}

cmd_new() {
  local branch="${1:-}" issue="${2:-}" main_wt slug dir assignees state

  [ -n "$branch" ] || die "usage: scripts/worktree.sh new <branch> [issue-number]"

  main_wt="$(main_worktree)"
  slug="$(printf '%s' "$branch" | tr '/' '-')"
  dir="$(dirname "$main_wt")/$(basename "$main_wt")-${slug}"
  [ ! -e "$dir" ] || die "$dir already exists"

  if [ -n "$issue" ]; then
    command -v gh >/dev/null 2>&1 || die "gh is required to claim an issue"
    # gc recovers the issue from the branch name, so the link has to live there.
    case "$branch" in
      *"$issue"*) : ;;
      *) die "branch must carry the issue number, e.g. fix/issue-${issue}-short-slug" ;;
    esac
    state="$(issue_state "$issue")"
    [ "$state" = "OPEN" ] || die "issue #${issue} is ${state:-unreadable}"
    assignees="$(gh issue view "$issue" --json assignees --jq '.assignees[].login' 2>/dev/null || true)"
    [ -z "$assignees" ] ||
      die "issue #${issue} is already assigned to: $(echo "$assignees" | tr '\n' ' ')"
  fi

  git fetch -q origin main
  git worktree add -b "$branch" "$dir" origin/main

  seed_worktree "$main_wt" "$dir"

  if [ -n "$issue" ]; then
    gh issue edit "$issue" --add-assignee @me >/dev/null
    gh issue comment "$issue" --body "Claimed by an agent working in \`${branch}\` at \`${dir}\` on $(hostname -s), $(date -u +%Y-%m-%dT%H:%M:%SZ).

Assignment here is advisory, not a lock. If this claim has no commits on \`${branch}\` and has gone quiet, unassign and take it over." >/dev/null
    # Re-read: two agents that both saw "unassigned" can both have written.
    assignees="$(gh issue view "$issue" --json assignees --jq '.assignees[].login' 2>/dev/null || true)"
    if [ "$(echo "$assignees" | grep -c .)" -gt 1 ]; then
      echo "⚠️  issue #${issue} now has multiple assignees ($(echo "$assignees" | tr '\n' ' ')) — check before continuing"
    fi
    echo "🔖 Claimed issue #${issue}"
  fi

  echo ""
  echo "📁 $dir"
  echo "   Fresh worktrees need the setup in AGENTS.md before tests will run."
}

usage() {
  cat <<'USAGE'
scripts/worktree.sh gc [--yes] [--idle-hours N] [--no-fetch] [--no-issues]
    Report worktrees whose commits are already in origin/main, that hold no
    uncommitted work, and that nothing has touched for N hours (default 24).
    With --yes, remove them; branches are always kept. --quiet prints only a
    one-line count, and nothing at all when there is nothing to reclaim.

scripts/worktree.sh new <branch> [issue-number]
    Create a worktree beside the main checkout, branched from origin/main,
    and seed it with the main checkout's deps, _build, and project-PLT
    artifacts when toolchain and lockfiles match (Mix revalidates them, so
    a stale seed only costs a rebuild). With an issue number, verify it is
    open and unassigned, then assign it and post a claim comment. The branch
    name must contain the issue number.

scripts/worktree.sh seed [<dir>]
    Seed an existing worktree (default: the current one) from the main
    checkout. Artifacts already present are left untouched, so this is safe
    to re-run and only fills gaps.
USAGE
}

main() {
  local command="${1:-}"
  [ $# -gt 0 ] && shift || true

  case "$command" in
    gc)
      while [ $# -gt 0 ]; do
        case "$1" in
          --yes) DO_REMOVE=1 ;;
          --dry-run) DO_REMOVE=0 ;;
          --quiet) QUIET=1 ;;
          --no-fetch) DO_FETCH=0 ;;
          --no-issues) DO_ISSUES=0 ;;
          --idle-hours)
            shift
            IDLE_HOURS="${1:-24}"
            ;;
          *) die "unknown option: $1" ;;
        esac
        shift
      done
      cmd_gc
      ;;
    new) cmd_new "$@" ;;
    seed) cmd_seed "$@" ;;
    ""| -h | --help | help) usage ;;
    *)
      usage >&2
      die "unknown command: $command"
      ;;
  esac
}

main "$@"
