#!/usr/bin/env bash
# ralph/pure-loop.sh: the pure ralph loop: prepare the pass, run pi on it, repeat
# Usage: ralph/pure-loop.sh <source> [max-passes]
set -euo pipefail

SOURCE=$1
MAX_PASSES=${2:-10}
DIR=$(cd "$(dirname "$0")" && pwd)
TIMEFORMAT=$'── pi: %1lR (cpu: %1lU user, %1lS sys) ──\n'

for pass in $(seq "$MAX_PASSES"); do
  # prepare-loop.sh does everything that is not the loop, and answers in
  # shell: the pass variables PASS_DIR, PASS_MODEL, PASS_PROMPT, or the
  # stop itself (`exit 0`) when every box is checked
  pass_env=$("$DIR/prepare-loop.sh" "$SOURCE" "$pass")
  eval "$pass_env"

  # every pass runs under guard.sh: exit 3 means the model spilled to CPU
  # and the machine cannot run this pass honestly, so the loop halts for a
  # human; exit 124 means the pass blew its time budget and a fresh pass
  # gets the next try
  status=0
  time (
    cd "$PASS_DIR"
    "$DIR/guard.sh" "$PASS_MODEL" \
      pi --no-session --tools read,bash,edit,write \
      -p --provider ollama --model "$PASS_MODEL" \
      < "$PASS_PROMPT"
  ) || status=$?
  if [[ $status -eq 3 ]]; then
    echo "halted on pass $pass: model spilled to CPU"
    exit 3
  fi
done

echo "iteration cap hit with items unchecked"
exit 1
