#!/bin/zsh
set -euo pipefail

samples="${1:-20}"
if [[ "$samples" != <-> ]] || (( samples < 2 || samples > 300 )); then
  print -u2 "usage: $0 [samples-from-2-to-300]"
  exit 64
fi

repo_root="${0:A:h:h}"
executable="$repo_root/.build/Call Recorder.app/Contents/MacOS/CallRecorder"
pid="$(pgrep -n -f "$executable" || true)"
if [[ -z "$pid" ]]; then
  print -u2 "Call Recorder is not running. Run ./scripts/launch-app.sh first."
  exit 1
fi

print "sample,cpu_percent,memory,threads,idle_wakeups,power,cpu_time"
top \
  -l "$samples" \
  -s 1 \
  -pid "$pid" \
  -stats pid,cpu,mem,threads,idlew,power,time,command |
  awk -v pid="$pid" '$1 == pid {
    sample += 1
    memory = $3
    sub(/[+-]$/, "", memory)
    printf "%d,%s,%s,%s,%s,%s,%s\n", sample, $2, memory, $4, $5, $6, $7
  }'
