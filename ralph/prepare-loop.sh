#!/usr/bin/env bash
# ralph/prepare-loop.sh: everything a pass needs before pi runs, so that
# pure-loop.sh stays the pure ralph loop. Re-reads the plan, extracts the next
# unchecked item, names the worktree once (a standalone pi call) and
# repairs it, trusts its mise config, tracks stuck-item escalation, assembles
# the pass prompt. A source without a published plan inventory gets the plan
# pass first (see PLAN-PROMPT.md and plan.sh). Each worktree owns its loop
# state in .ralph/ (gitignored): a source marker tying it to its plan, the
# stuck counter, the pass prompt.
#
# stdout: the answer, as shell for pure-loop.sh to eval:
#   PASS_DIR= PASS_MODEL= PASS_PROMPT=   a runnable pass
#   echo "plan complete ..."; exit 0     every item is checked
# With 'name' instead of a pass number, only resolves the worktree branch for
# the source (naming it on first contact) and prints it: run.sh keys its log
# directory on it.
# stderr: the pass banner and diagnostics.
# Usage: ralph/prepare-loop.sh <github-issue-url | gitlab-issue-url | local-file> <pass | name>
set -euo pipefail

SOURCE=$1
PASS=$2
MODEL=${MODEL:-qwen3:8b}   # the local builder, an explicit choice; override to escalate
ESCALATION_MODEL=${ESCALATION_MODEL:-qwen3-coder:30b}   # the stuck-item builder, one pass at a time
ESCALATE_AFTER=${ESCALATE_AFTER:-2}   # consecutive passes on one item before escalating
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$DIR")
NOTES=$DIR/NOTES.md   # pass-to-pass memory: the model appends, every pass reads
WORKTREES=$ROOT/.worktrees
mkdir -p "$WORKTREES"

case "$SOURCE" in
  https://github.com/*)
    PLAN=$(gh issue view "$SOURCE" --json body --jq .body)
    ;;
  https://gitlab.com/*)
    PLAN=$(glab issue view "$SOURCE" --output json | jq -r .description)
    ;;
  *)
    PLAN=$(cat "$SOURCE")
    ;;
esac

# each worktree's .ralph/source names the plan it belongs to; finding the
# worktree for this source is a scan, so parallel loops never collide. Only a
# source no worktree claims gets the standalone pi naming call: the branch is
# named ONCE over the plan, never in the plan itself. PI_BIN (exported
# by run.sh) bypasses the json-mode shim; direct callers get plain `pi`.
resolve_worktree() {
  BRANCH=""
  for marker in "$WORKTREES"/*/.ralph/source; do
    [[ -f "$marker" ]] || continue
    if [[ "$(<"$marker")" == "$SOURCE" ]]; then
      BRANCH=$(basename "${marker%/.ralph/source}")
      break
    fi
  done
  if [[ -z "$BRANCH" ]]; then
    BRANCH=$({
      printf 'You name git branches. The convention is type-N-kebab-title, where type is one of feat|fix|docs|refactor|test|chore and N is the issue number.\n'
      printf 'Suggest the single branch name for the plan below, from %s.\n' "$SOURCE"
      printf 'Reply with ONLY the branch name.\n\n%s\n' "$PLAN"
    } | "${PI_BIN:-pi}" -p --provider ollama --model "$MODEL" --no-session --tools read 2>/dev/null \
      | grep -m1 -oE '(feat|fix|docs|refactor|test|chore)-[0-9]+-[a-z0-9-]+' | head -1 || true)
    if [[ -z "$BRANCH" ]]; then
      echo "prepare-loop.sh: pi did not produce a usable branch name" >&2
      exit 1
    fi
    echo "prepare-loop.sh: worktree branch named '$BRANCH'" >&2
  fi

  WORKTREE=$ROOT/.worktrees/$BRANCH
  git -C "$ROOT" worktree prune
  if [[ ! -d "$WORKTREE" ]]; then
    if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git -C "$ROOT" worktree add "$WORKTREE" "$BRANCH" >&2
    else
      git -C "$ROOT" worktree add "$WORKTREE" >&2
    fi
  fi
  mise trust "$WORKTREE/mise.toml" >&2 2>/dev/null || true

  RSTATE=$WORKTREE/.ralph
  mkdir -p "$RSTATE"
  printf '%s\n' "$SOURCE" > "$RSTATE/source"
}

# name mode: resolve the branch, answer it, done
if [[ "$PASS" == name ]]; then
  resolve_worktree
  printf '%s\n' "$BRANCH"
  exit 0
fi

# the plan intro: everything above the first checkbox
INTRO=$(awk '/^- \[/ { exit } { print }' <<<"$PLAN")

ITEM=$(awk '{
  if (!scanning_current_task_and_gate) {
    if ($0 ~ /^- \[ \]/) {
      scanning_current_task_and_gate = 1
      print
    }
  } else {
    if ($0 ~ /^- \[/) exit
    print
  }
}' <<<"$PLAN")

# no unchecked item left: the answer pure-loop.sh evals is the stop itself
if [[ -z "$ITEM" ]]; then
  printf 'echo "plan complete in %d passes"\nexit 0\n' "$((PASS - 1))"
  exit 0
fi

resolve_worktree

# plan mode: no item is built before the plan inventory exists. The
# inventory lives at the source (a marked comment on the issue, or a sibling
# -plan.md file), published by ralph/plan.sh; a source without one turns this
# pass into the plan pass, and every later pass reads what it left behind.
PLAN_MARK='<!-- ralph:plan -->'
INVENTORY=""
case "$SOURCE" in
  https://github.com/*)
    INVENTORY=$(gh issue view "$SOURCE" --json comments \
      --jq "[.comments[].body | select(startswith(\"$PLAN_MARK\"))] | last // empty")
    ;;
  https://gitlab.com/*)
    INVENTORY=$(glab issue view "$SOURCE" --comments 2>/dev/null \
      | awk -v m="$PLAN_MARK" 'index($0, m) {found=1} found' || true)
    ;;
  *)
    if [[ -f "${SOURCE%.md}-plan.md" ]]; then
      INVENTORY=$(cat "${SOURCE%.md}-plan.md")
    fi
    ;;
esac

# the same item ESCALATE_AFTER passes in a row means the base model is stuck:
# give the bigger model one pass, then hand back. The plan pass is an item
# like any other: a model that cannot land the inventory escalates too.
STUCK=$RSTATE/stuck
if [[ -z "$INVENTORY" ]]; then
  item_head='__plan-mode__'
else
  item_head=${ITEM%%$'\n'*}
fi
stuck=0 last=""
if [[ -s "$STUCK" ]]; then
  IFS=$'\t' read -r stuck last < "$STUCK"
fi
if [[ "$item_head" == "$last" ]]; then
  stuck=$((stuck + 1))
else
  stuck=0
fi
printf '%s\t%s\n' "$stuck" "$item_head" > "$STUCK"
pass_model=$MODEL
if (( stuck > 0 && stuck % ESCALATE_AFTER == 0 )); then
  pass_model=$ESCALATION_MODEL
fi

# the pass banner goes to stderr: watch.sh keys its timing sidebar on it
{
  echo "── pass $PASS — $pass_model — $(date '+%H:%M:%S') ──"
  if [[ -z "$INVENTORY" ]]; then
    echo "plan mode: build the plan inventory, publish it"
  else
    echo "$ITEM"
  fi
} >&2

PROMPT=$RSTATE/prompt
if [[ -z "$INVENTORY" ]]; then
  {
    cat "$DIR/PLAN-PROMPT.md"
    printf '\nThe plan, from %s:\n\n%s\n' "$SOURCE" "$PLAN"
    printf '\nWhen the inventory is written, publish it with EXACTLY this command:\n\n  ralph/plan.sh %q\n' "$SOURCE"
  } > "$PROMPT"
else
  {
    cat "$DIR/PROMPT.md"
    printf '\nThe plan inventory (current state vs desired state), from the plan pass:\n\n%s\n' "$INVENTORY"
    printf '\nThe plan, from %s:\n\n%s\n\nThe item:\n\n%s\n' "$SOURCE" "$INTRO" "$ITEM"
    printf '\nWhen every gate is green, book the item with EXACTLY this command:\n\n  ralph/tick.sh %q\n' "$SOURCE"
    printf '\nYour notes file: %s\n' "$NOTES"
    if [[ -s "$NOTES" ]]; then
      printf '\nNotes from previous passes:\n\n%s\n' "$(tail -20 "$NOTES")"
    fi
  } > "$PROMPT"
fi

printf 'PASS_DIR=%q\nPASS_MODEL=%q\nPASS_PROMPT=%q\n' \
  "$WORKTREE" "$pass_model" "$PROMPT"
