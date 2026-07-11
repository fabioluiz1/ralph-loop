#!/usr/bin/env bash
# ralph/run.sh: the launcher. Starts the pure loop in the background,
# writing its raw NDJSON stream to a per-run log, then attaches watch.sh to
# render it live. The run and the viewer are decoupled: Ctrl-C or a dead
# terminal only detaches the viewer, the run keeps going.
#   re-attach:  ralph/watch.sh <log>
#   stop run:   kill -- -<pid>   (pid printed at start, also in the .pid file)
# Usage: ralph/run.sh <issue-url-or-plan-file> [max-passes]
set -euo pipefail

ISSUE=$1
MAX_PASSES=${2:-10}
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$DIR")

PI_BIN=$(command -v pi)
export PI_BIN   # prepare-loop.sh uses the real pi for its one-shot naming call

# raw NDJSON log, kept for post-mortem debugging. Logs live in ralph/logs
# (gitignored), named after the worktree branch, not inside the worktree:
# they outlive it. prepare-loop.sh resolves the branch before the loop starts.
# A known plan resolves instantly; a first contact needs one pi naming call,
# slow on a local model, so it runs backgrounded behind a heartbeat that only
# speaks up (and starts its dot-per-second) once the wait is real.
NAME_OUT=$(mktemp /tmp/ralph-name-XXXXXX)
printf 'ralph: worktree ' >&2
"$DIR/prepare-loop.sh" "$ISSUE" name > "$NAME_OUT" 2>/dev/null &
NAME_PID=$!
waited=0
while kill -0 "$NAME_PID" 2>/dev/null; do
  sleep 1
  kill -0 "$NAME_PID" 2>/dev/null || break
  (( waited == 0 )) && printf 'first contact, pi is naming the branch ' >&2
  printf '.' >&2
  waited=$((waited + 1))
done
if ! wait "$NAME_PID"; then
  printf 'no name\n' >&2
  printf 'ralph: could not resolve a branch for %s\n' "$ISSUE" >&2
  printf 'ralph: is ollama up? see for yourself: ralph/prepare-loop.sh %q name\n' "$ISSUE" >&2
  rm -f "$NAME_OUT"
  exit 1
fi
BRANCH=$(<"$NAME_OUT")
rm -f "$NAME_OUT"
(( waited > 0 )) && printf ' ' >&2
printf '%s\n' "$BRANCH" >&2

LOG_DIR=$DIR/logs/$BRANCH
mkdir -p "$LOG_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG=$LOG_DIR/$STAMP.ndjson
PIDFILE=$LOG_DIR/$STAMP.pid
: > "$LOG"   # the viewer tails it, so it must exist before the run starts

# pi -p in text mode prints nothing until the whole response is done, so no pty
# trick can make it stream. Its json mode emits one NDJSON event per token,
# thinking included. A pi shim on PATH adds --mode json so pure-loop.sh stays pure;
# watch.sh renders the event stream back into readable text.
SHIM_DIR=$(mktemp -d /tmp/ralph-pi-shim-XXXXXX)
cat > "$SHIM_DIR/pi" <<EOF
#!/usr/bin/env bash
exec "$PI_BIN" --mode json "\$@"
EOF
chmod +x "$SHIM_DIR/pi"

# the run: backgrounded in its own process group (set -m) so the viewer's
# Ctrl-C can never reach it, HUP ignored so a closed terminal cannot either.
# The wrapper owns the shim cleanup and always appends the end sentinel that
# watch.sh exits on. 2>&1 keeps pure-loop.sh's time report in the log.
set -m
(
  finish() {
    printf '\n── ralph run ended (exit %s) ──\n' "$1" >> "$LOG"
    rm -rf "$SHIM_DIR"
    rm -f "$PIDFILE"
  }
  trap 'finish 143; exit 143' TERM
  trap '' HUP
  status=0
  PATH="$SHIM_DIR:$PATH" "$DIR/pure-loop.sh" "$ISSUE" "$MAX_PASSES" \
    >> "$LOG" 2>&1 < /dev/null || status=$?
  finish "$status"
) &
LOOP_PID=$!
set +m
echo "$LOOP_PID" > "$PIDFILE"

REL=${LOG#"$ROOT"/}
{
  printf 'ralph: %-8s %s\n' log "$REL"
  printf 'ralph: %-8s %s\n' watch "Ctrl-C detaches the viewer only; the run keeps going"
  printf 'ralph: %-8s %s\n' attach "ralph/watch.sh $REL"
  printf 'ralph: %-8s %s\n' stop "kill -- -$LOOP_PID"
} >&2

exec "$DIR/watch.sh" "$LOG"
