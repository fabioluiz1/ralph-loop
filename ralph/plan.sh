#!/usr/bin/env bash
# ralph/plan.sh: publishes the plan inventory (ralph/artifacts.md, written by
# the plan pass) back to the plan source: a marked comment on the issue, or a
# sibling <source>-plan.md next to a local plan file. prepare-loop.sh finds it
# there and serves it to every later pass; its absence is what triggers plan
# mode, so publishing is what ends it. Ticks never touch it: the checklist in
# the original source stays the only loop control.
# Usage: ralph/plan.sh <github-issue-url | gitlab-issue-url | local-file> [artifacts]
set -euo pipefail

SOURCE=$1
ARTIFACTS=${2:-ralph/artifacts.md}

if [[ ! -s "$ARTIFACTS" ]]; then
  echo "plan.sh: $ARTIFACTS is missing or empty; write the plan inventory first" >&2
  exit 1
fi

BODY=$(printf '<!-- ralph:plan -->\n\n%s' "$(cat "$ARTIFACTS")")

case "$SOURCE" in
  https://github.com/*)
    gh issue comment "$SOURCE" --body-file - <<<"$BODY"
    ;;
  https://gitlab.com/*)
    glab issue note "$SOURCE" --message "$BODY"
    ;;
  *)
    printf '%s\n' "$BODY" > "${SOURCE%.md}-plan.md"
    ;;
esac
