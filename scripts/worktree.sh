#!/bin/zsh
# Multiplex local work with git worktrees under .worktrees/ (gitignored).
#
#   scripts/worktree.sh new <name> [base]   create branch feature/<name> off base
#                                           (default origin/main) in .worktrees/<name>
#   scripts/worktree.sh list                show active worktrees
#   scripts/worktree.sh remove <name>       remove the worktree (and its branch if merged)
#
# Each worktree is a full checkout with its own .build/, so `swift build`,
# `swift test`, and `swift run motive-demo` run independently per feature.
# To run two demos at once, give each its own runtime home:
#   MOTIVE_HOME=$(pwd)/.motive-home swift run motive-demo
# (port collisions fall back to ephemeral ports automatically; server.json
# under each MOTIVE_HOME records the truth).
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
TREES_DIR="$PROJECT_DIR/.worktrees"

cmd="${1:-list}"

case "$cmd" in
  new)
    name="${2:?usage: worktree.sh new <name> [base]}"
    base="${3:-origin/main}"
    branch="feature/$name"
    tree_dir="$TREES_DIR/$name"
    if [[ -e "$tree_dir" ]]; then
      echo "worktree already exists: $tree_dir" >&2
      exit 1
    fi
    # Best-effort freshness; offline/sandboxed runs still work off local refs.
    git -C "$PROJECT_DIR" fetch -q origin 2>/dev/null || true
    if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$PROJECT_DIR" worktree add "$tree_dir" "$branch"
    else
      git -C "$PROJECT_DIR" worktree add -b "$branch" "$tree_dir" "$base"
    fi
    echo "$tree_dir  ($branch, from $base)"
    echo "next:  cd $tree_dir && swift test"
    ;;

  list)
    git -C "$PROJECT_DIR" worktree list
    ;;

  remove)
    name="${2:?usage: worktree.sh remove <name>}"
    branch="feature/$name"
    tree_dir="$TREES_DIR/$name"
    git -C "$PROJECT_DIR" worktree remove "$tree_dir"
    # Only delete the branch when it's merged; -d refuses otherwise.
    if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$PROJECT_DIR" branch -d "$branch" 2>/dev/null \
        || echo "branch $branch kept (not merged; use 'git branch -D $branch' to force)"
    fi
    ;;

  *)
    echo "usage: worktree.sh {new <name> [base] | list | remove <name>}" >&2
    exit 1
    ;;
esac
