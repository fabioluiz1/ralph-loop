#!/usr/bin/env bash
# ralph/watch.sh: the viewer, renders pi's json event stream as live text, adds an
# ollama timing sidebar, and prints warm-up dots until the first token of each pass
# Usage: ralph/watch.sh <run-log>          follow a live run, or replay a finished one
#        ralph/pure-loop.sh ... | ralph/watch.sh        pipe mode
set -euo pipefail

# input: a run log to follow (arg) or the raw stream on stdin (pipe mode).
# In file mode the run's end sentinel stops the viewer, so it exits with the
# run; Ctrl-C merely detaches and the run keeps going.
LOG=${1:-}
if [[ -n "$LOG" && ! -f "$LOG" ]]; then
  echo "watch.sh: no such log: $LOG" >&2
  exit 1
fi
SENTINEL='── ralph run ended'

MARK=$(mktemp /tmp/ralph-watch-XXXXXX)        # epoch of the current pass start
FLAG=$(mktemp /tmp/ralph-watch-flag-XXXXXX)   # last pass whose warm-up dots were stopped
trap 'rm -f "$MARK" "$FLAG"' EXIT

log_file=$(lsof -p "$(pgrep -f 'ollama serve' 2>/dev/null | head -1)" 2>/dev/null \
  | awk '$4~/^1w/ && $5=="REG" {print $NF; exit}')

if [[ -n "${log_file:-}" && -f "$log_file" ]]; then
  # warm-up dots: one per second from pass start until the sidebar speaks
  (
    while :; do
      sleep 1
      mark=$(cat "$MARK" 2>/dev/null || true)
      [[ -z "$mark" ]] && continue
      [[ "$(cat "$FLAG" 2>/dev/null || true)" == "$mark" ]] && continue
      printf '.' >&3
    done
  ) 3>&2 >/dev/null 2>/dev/null &
  DOTS_PID=$!

  (
    out() {
      # sidebar lines land amid pi's token stream: blank lines before and after so
      # they never splice a sentence (this also ends the warm-up dot line)
      [[ "$(cat "$FLAG" 2>/dev/null || true)" != "$seen" ]] && printf '%s' "$seen" > "$FLAG"
      # shellcheck disable=SC2059
      printf '\n\n' >&3
      printf "$@" >&3
      printf '\n' >&3
    }

    seen="" start=0 call_n=0 label="thinking"
    tail -f -n 0 "$log_file" 2>/dev/null \
    | grep --line-buffered 'launch_slot_.*processing task\|print_timing' \
    | while IFS= read -r line; do
        mark=$(cat "$MARK" 2>/dev/null || true)
        [[ -z "$mark" ]] && continue   # no pass running yet
        if [[ "$mark" != "$seen" ]]; then
          seen=$mark
          start=$mark
          call_n=0
          label="thinking"
        fi
        el=$(( $(date +%s) - start ))
        m=$(( el / 60 )); s=$(( el % 60 ))
        if [[ "$line" == *launch_slot_*"processing task"* ]]; then
          call_n=$(( call_n + 1 ))
          if (( call_n > 1 )); then
            out '  [%02d:%02d] ── tool call %d ──\n' "$m" "$s" "$((call_n - 1))"
            label="generating"
          fi
        elif [[ "$line" == *print_timing*n_decoded* ]]; then
          decoded=$(printf '%s' "$line" | grep -o 'n_decoded = *[0-9]*' | grep -o '[0-9]*$')
          tg=$(printf '%s' "$line" | grep -o 'tg = *[0-9.]*' | grep -o '[0-9.]*$')
          [[ -z "$decoded" ]] && continue
          out '  [%02d:%02d] [%s] %s tokens @ %s t/s\n' "$m" "$s" "$label" "$decoded" "$tg"
        fi
      done
    # fd3 -> real stderr for sidebar output; stdout/stderr detached so the subshell can't
    # hold the pipe open or print job-control noise when its tail gets killed
  ) 3>&2 >/dev/null 2>/dev/null &
  WATCHER_PID=$!
fi

# render pi's --mode json NDJSON events back into readable text as they stream:
# thinking dim, answer plain, tool calls one header plus their streamed args,
# tool results dim, first 10 lines with a count of the rest; anything that is
# not a JSON event passes through
RENDER='
def clip($n): if length > $n then .[0:$n] + " …" else . end;
def render:
  if .type == "message_update" then
    .assistantMessageEvent as $e |
    if   $e.type == "thinking_start" then "[2m── think ──\n"
    elif $e.type == "thinking_delta" then ($e.delta // "")
    elif $e.type == "thinking_end"   then "[0m\n"
    elif $e.type == "text_start"     then "── answer ──\n"
    elif $e.type == "text_delta"     then ($e.delta // "")
    elif $e.type == "text_end"       then "\n"
    elif $e.type == "toolcall_start" then "── tool: " + ($e.partial.content[-1].name // "?") + " [2m"
    elif $e.type == "toolcall_delta" then ($e.delta // "")
    elif $e.type == "toolcall_end"   then "[0m\n"
    else empty end
  elif .type == "message_end" and .message.role == "toolResult" then
    ((.message.content // []) | map(select(.type == "text") | .text)
      | join("\n") | split("\n")) as $lines |
    "[2m" + ($lines[0:10] | to_entries
      | map((if .key == 0 then "  ↳ " else "    " end) + (.value | clip(200)))
      | join("\n"))
    + (if ($lines | length) > 10
       then "\n    … " + (($lines | length) - 10 | tostring) + " more lines"
       else "" end)
    + "[0m\n"
  else empty end;
. as $line | try ($line | fromjson | render) catch ($line + "\n")
'

render_stream() {
  cur_mark="" delta_seen=""
  while IFS= read -r line; do
    # scrub pty artifacts, kept for callers that still wrap the loop in script(1)
    line=${line//$'\r'/}
    line=${line//$'^D\b\b'/}
    if [[ "$line" == "── pass"* ]]; then
      cur_mark=$(date +%s)
      echo "$cur_mark" > "$MARK"
      # announce the new pass: full-width rules and blank lines around the header
      rule=$(printf '═%.0s' {1..60})
      line=$'\n\n'"$rule"$'\n'"$line"$'\n'"$rule"$'\n'
    elif [[ "$line" == '{"type":"message_update"'* && "$delta_seen" != "$cur_mark" ]]; then
      # first streamed token of the pass: end the warm-up dot line, stop the dots
      delta_seen=$cur_mark
      printf '%s' "$cur_mark" > "$FLAG"
      printf '\n' >&2
    fi
    printf '%s\n' "$line"
    if [[ "$line" == "$SENTINEL"* ]]; then
      # tail never sees EOF on a file: kill it or the pipeline waits forever.
      # SIGPIPE, because that is what losing your reader means, and bash
      # reports it as a normal exit instead of printing "Terminated"
      pkill -PIPE -P $$ -x tail 2>/dev/null || true
      break
    fi
  done | jq --unbuffered -Rrj "$RENDER"
}

if [[ -n "$LOG" ]]; then
  # follow from the first line: attaching mid-run replays the history then
  # goes live; a finished log replays fully and exits at the sentinel
  tail -n +1 -f -- "$LOG" | render_stream || true
else
  render_stream
fi

for pid in "${DOTS_PID:-}" "${WATCHER_PID:-}"; do
  [[ -z "$pid" ]] && continue
  pkill -P "$pid" 2>/dev/null || true   # the tail/grep/sleep children, or they outlive us
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
done
