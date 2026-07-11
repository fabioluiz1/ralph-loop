#!/usr/bin/env bash
# Enforces the branch convention: type-N-kebab-title, and inside a .worktrees/
# worktree the branch must equal the worktree directory name.
# With the "commit" argument (pre-commit context), commits on main are rejected;
# set ALLOW_MAIN=1 to override for scaffold maintenance.
set -euo pipefail

context=${1:-checkout}
branch=$(git rev-parse --abbrev-ref HEAD)

if [[ "$branch" == "main" || "$branch" == "HEAD" ]]; then
  if [[ "$context" == "commit" && -z "${ALLOW_MAIN:-}" ]]; then
    echo "commits on main are forbidden: work in .worktrees/<branch> (ALLOW_MAIN=1 to override)" >&2
    exit 1
  fi
  exit 0
fi

re='^(feat|fix|docs|refactor|test|chore)-[0-9]+-[a-z0-9-]+$'
if ! [[ "$branch" =~ $re ]]; then
  echo "branch '$branch' must match 'type-N-kebab-title' (type: feat|fix|docs|refactor|test|chore)" >&2
  exit 1
fi

toplevel=$(git rev-parse --show-toplevel)
if [[ "$toplevel" == */.worktrees/* ]]; then
  dir=$(basename "$toplevel")
  if [[ "$branch" != "$dir" ]]; then
    echo "branch '$branch' must be '$dir': the worktree directory name is the branch name" >&2
    exit 1
  fi
fi
