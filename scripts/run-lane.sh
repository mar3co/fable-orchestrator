#!/usr/bin/env bash
# run-lane.sh — process supervisor for fable-orchestrator CLI lanes.
#
# The harness caps any foreground tool call at 10 minutes, so lanes must never
# hold their CLI in one long call. This script owns the fragile parts:
#   start <codex|grok> <spec-file> [secs] [model]  launch detached + watchdog,
#                                                  print PID/WATCHDOG/FINAL/LOG
#   wait <pid> [slice-secs]                        one bounded slice (default 240s),
#                                                  prints EXITED or STILL-RUNNING
#   reap <pid> [watchdog-pid]                      kill lane + watchdog, cleanup
#
# The watchdog is pure bash (sleep + kill) — no coreutils/gtimeout needed —
# and survives the calling agent, so the wall clock holds even if the lane dies.
set -u

CMD=${1:-}
[ $# -gt 0 ] && shift

case "$CMD" in
start)
  LANE=${1:?usage: run-lane.sh start codex|grok <spec-file> [secs] [model]}
  SPEC=${2:?missing spec file}
  SECS=${3:-1800}
  MODEL=${4:-}
  [ -r "$SPEC" ] || { echo "STATUS: unavailable"; echo "REASON: spec file not readable: $SPEC"; exit 1; }
  FINAL=$(mktemp -t "${LANE}-final.XXXXXX")
  LOG=$(mktemp -t "${LANE}-log.XXXXXX")
  case "$LANE" in
    codex)
      command -v codex >/dev/null 2>&1 || { echo "STATUS: unavailable"; echo "REASON: codex not on PATH"; exit 1; }
      codex exec --model "${MODEL:-gpt-5.6-sol}" -c model_reasoning_effort=high \
        --sandbox workspace-write --skip-git-repo-check --cd "$(pwd)" \
        --output-last-message "$FINAL" - < "$SPEC" > "$LOG" 2>&1 &
      ;;
    grok)
      command -v grok >/dev/null 2>&1 || { echo "STATUS: unavailable"; echo "REASON: grok not on PATH"; exit 1; }
      grok --prompt-file "$SPEC" -m "${MODEL:-grok-4.5}" --permission-mode acceptEdits \
        --output-format plain --cwd "$(pwd)" > "$FINAL" 2>&1 &
      LOG=$FINAL
      ;;
    *) echo "STATUS: unavailable"; echo "REASON: unknown lane '$LANE' (codex|grok)"; exit 2 ;;
  esac
  PID=$!
  ( sleep "$SECS" && kill "$PID" 2>/dev/null \
      && echo "WATCHDOG: killed $LANE after ${SECS}s" >> "$LOG" ) >/dev/null 2>&1 &
  WATCHDOG=$!
  echo "PID: $PID"
  echo "WATCHDOG: $WATCHDOG"
  echo "FINAL: $FINAL"
  echo "LOG: $LOG"
  ;;
wait)
  PID=${1:?usage: run-lane.sh wait <pid> [slice-secs]}
  SLICE=${2:-240}
  i=0
  while [ "$i" -lt "$((SLICE / 5))" ] && kill -0 "$PID" 2>/dev/null; do
    sleep 5
    i=$((i + 1))
  done
  if kill -0 "$PID" 2>/dev/null; then echo "STILL-RUNNING"; else echo "EXITED"; fi
  ;;
reap)
  PID=${1:?usage: run-lane.sh reap <pid> [watchdog-pid]}
  WATCHDOG=${2:-}
  kill "$PID" 2>/dev/null
  [ -n "$WATCHDOG" ] && kill "$WATCHDOG" 2>/dev/null
  sleep 2
  kill -9 "$PID" 2>/dev/null
  echo "REAPED: $PID"
  ;;
*)
  echo "usage: run-lane.sh start|wait|reap ..." >&2
  exit 2
  ;;
esac
