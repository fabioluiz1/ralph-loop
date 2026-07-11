#!/usr/bin/env bash
# ralph/tick.sh: ticks the FIRST unchecked item in the plan, nothing else.
# The only sanctioned way to update the plan; the body is read, one checkbox
# flipped, and written back, so a full-body overwrite can never happen here.
# Usage: ralph/tick.sh <github-issue-url | gitlab-issue-url | local-file>
set -euo pipefail

SOURCE=$1

case "$SOURCE" in
  https://github.com/*)
    BODY=$(gh issue view "$SOURCE" --json body --jq .body)
    ;;
  https://gitlab.com/*)
    BODY=$(glab issue view "$SOURCE" --output json | jq -r .description)
    ;;
  *)
    BODY=$(cat "$SOURCE")
    ;;
esac

# flip only the first `- [ ]` line to `- [x]`; every other byte passes through
TICKED=$(awk '{
  if (!ticked && $0 ~ /^- \[ \]/) {
    sub(/^- \[ \]/, "- [x]")
    ticked = 1
  }
  print
}' <<<"$BODY")

if [[ "$TICKED" == "$BODY" ]]; then
  echo "tick.sh: no unchecked item in the plan; nothing to do" >&2
  exit 1
fi

case "$SOURCE" in
  https://github.com/*)
    gh issue edit "$SOURCE" --body-file - <<<"$TICKED"
    ;;
  https://gitlab.com/*)
    glab issue update "$SOURCE" --description "$TICKED"
    ;;
  *)
    printf '%s\n' "$TICKED" > "$SOURCE"
    ;;
esac
