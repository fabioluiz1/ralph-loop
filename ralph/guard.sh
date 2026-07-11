#!/usr/bin/env bash
# ralph/guard.sh: runs one pi pass under watch. Two rules, checked every 15s:
#   - the model must stay on the GPU. Any CPU spill in `ollama ps` kills the
#     pass and answers exit 3, the signal for the loop to HALT: a spilled
#     model grinds for hours, and escalating onto it only grinds harder.
#   - the pass must fit its budget (PASS_TIMEOUT, default 1800s). Overruns
#     kill the pass and answer exit 124: the loop moves on, a fresh pass
#     retries with a clean context.
# Usage: ralph/guard.sh <model> <command...>   (stdin passes through)
set -euo pipefail

MODEL=$1; shift
PASS_TIMEOUT=${PASS_TIMEOUT:-1800}
POLL=15

"$@" <&0 &
CMD_PID=$!

verdict=0
elapsed=0
while kill -0 "$CMD_PID" 2>/dev/null; do
  sleep "$POLL"
  elapsed=$((elapsed + POLL))
  if ollama ps 2>/dev/null | awk -v m="$MODEL" '$1 == m' | grep -q 'CPU'; then
    echo "guard: $MODEL spilled to CPU; killing the pass, halting the loop" >&2
    verdict=3
    break
  fi
  if (( elapsed >= PASS_TIMEOUT )); then
    echo "guard: pass outlived its ${PASS_TIMEOUT}s budget; killing it, moving on" >&2
    verdict=124
    break
  fi
done

if (( verdict != 0 )); then
  kill "$CMD_PID" 2>/dev/null || true
  sleep 2
  kill -9 "$CMD_PID" 2>/dev/null || true
fi
wait "$CMD_PID" || true
exit "$verdict"
