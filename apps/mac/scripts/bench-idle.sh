#!/bin/zsh
# Idle benchmark for the running OMNIServers app (macOS).
# Usage: scripts/bench-idle.sh [label] [seconds]   -> appends a line to docs/BENCHMARKS.md
# Measures the app process only: average CPU %, RSS (MB), idle wakeups/s, threads, over N seconds,
# in three states: window visible, window minimized, (server state is whatever is running).
label=${1:-run}; secs=${2:-30}
pid=$(pgrep -x OMNIServers | head -1); [ -z "$pid" ] && { echo "OMNIServers is not running"; exit 1; }
sample() { # $1 = state name
  # top -l 2: first sample is since-boot, second is the interval
  out=$(top -l 2 -pid $pid -stats cpu,mem,idlew,threads -s $secs | tail -1)
  rss=$(ps -o rss= -p $pid | awk '{printf "%.0f", $1/1024}')
  echo "$1|$out|rss=${rss}MB"
}
osascript -e 'tell application "OMNIServers" to activate' >/dev/null 2>&1; sleep 6
a=$(sample visible)
osascript -e 'tell application "System Events" to tell process "OMNIServers" to set value of attribute "AXMinimized" of every window to true' >/dev/null 2>&1; sleep 6
b=$(sample minimized)
osascript -e 'tell application "System Events" to tell process "OMNIServers" to set value of attribute "AXMinimized" of every window to false' >/dev/null 2>&1
date=$(date +%F)
echo "$date | $label | $a | $b" | tee -a docs/BENCHMARKS.md
