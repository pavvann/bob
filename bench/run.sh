#!/bin/bash
# bench/run.sh <label> [--skip-build] — one deterministic perf run.
#
# Builds Bob.app, launches it against bench/fake-claude.py (BOB_CLAUDE_BIN),
# and measures true CPU consumed per window via `ps -o cputime` deltas —
# %cpu is a decaying average that drags the launch burst through the idle
# window and can't show a steady-state change. Fixed timeline: settle 15s,
# idle 15-75s (empty transcript), stream 80-140s (the fake's replies start at
# handshake+75s), idle-with-transcript 150-180s (the regime the streaming
# phases must win), 10s `sample` profile, graceful quit. Writes
# bench/results/<utc>-<label>.md; compare .md files across branches.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="${1:-}"
if [ -z "$LABEL" ]; then
    echo "usage: bench/run.sh <label> [--skip-build]" >&2
    exit 1
fi
SKIP_BUILD="${2:-}"

if pgrep -x Bob >/dev/null; then
    echo "Bob is running — quitting it gracefully first"
    osascript -e 'quit app "Bob"' || true
    sleep 5
    if pgrep -x Bob >/dev/null; then
        echo "Bob is still running; quit it yourself and rerun." >&2
        exit 1
    fi
fi

if [ "$SKIP_BUILD" != "--skip-build" ]; then
    make -C "$ROOT" app
fi
if [ ! -x "$ROOT/Bob.app/Contents/MacOS/Bob" ]; then
    echo "no Bob.app — run without --skip-build" >&2
    exit 1
fi

RESULTS="$ROOT/bench/results"
mkdir -p "$RESULTS"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
SHA="$(git -C "$ROOT" rev-parse --short HEAD)"

BOB_CLAUDE_BIN="$ROOT/bench/fake-claude.py" "$ROOT/Bob.app/Contents/MacOS/Bob" >/dev/null 2>&1 &
BOBPID=$!
LAUNCH=$(date +%s)
echo "launched Bob (pid $BOBPID)"

alive() {
    kill -0 "$BOBPID" 2>/dev/null ||
        { echo "Bob died mid-run — check ~/bob/state/bridge-stderr.log" >&2; exit 1; }
}

# accumulated CPU seconds, parsed from [[HH:]MM:]SS.cc
cpusecs() {
    ps -o cputime= -p "$BOBPID" | awk '{
        n = split($1, a, ":"); s = a[n] + 0
        if (n > 1) s += a[n-1] * 60
        if (n > 2) s += a[n-2] * 3600
        printf "%.2f", s }'
}

RSSLOG="$(mktemp)"
# window <start offset s> <end offset s> -> CPU% of one core over the window
# (runs in a command substitution, so RSS goes to a file, not a variable)
window() {
    while [ "$(date +%s)" -lt $((LAUNCH + $1)) ]; do sleep 1; done
    alive
    local t0 c0 t1 c1
    t0=$(date +%s); c0=$(cpusecs)
    while [ "$(date +%s)" -lt $((LAUNCH + $2)) ]; do
        sleep 2
        alive
        ps -o rss= -p "$BOBPID" >> "$RSSLOG"
    done
    t1=$(date +%s); c1=$(cpusecs)
    awk -v c0="$c0" -v c1="$c1" -v t0="$t0" -v t1="$t1" \
        'BEGIN { printf "%.1f", (c1 - c0) / (t1 - t0) * 100 }'
}

echo "settling, then idle window (15-75s)"
IDLE=$(window 15 75)
echo "stream window (80-140s)"
STREAM=$(window 80 140)
echo "idle-with-transcript window (150-180s)"
IDLE2=$(window 150 180)

PROFILE="$RESULTS/$TS-$LABEL.sample.txt"
echo "profiling 10s -> $PROFILE"
sample "$BOBPID" 10 -file "$PROFILE" >/dev/null

osascript -e 'quit app "Bob"' || true
for _ in $(seq 1 15); do
    kill -0 "$BOBPID" 2>/dev/null || break
    sleep 1
done
kill -0 "$BOBPID" 2>/dev/null && echo "warning: Bob did not quit — quit it yourself (never kill it)" >&2

MAX_RSS=$(awk '$1 > m { m = $1 } END { print m + 0 }' "$RSSLOG")
rm -f "$RSSLOG"

MD="$RESULTS/$TS-$LABEL.md"
cat > "$MD" <<EOF
# bench: $LABEL

| label | commit | idle CPU% | stream CPU% | idle+transcript CPU% | max RSS (MB) |
|---|---|---|---|---|---|
| $LABEL | $SHA | $IDLE | $STREAM | $IDLE2 | $((MAX_RSS / 1024)) |

- CPU% = cputime delta over the window, of one core (can exceed 100)
- windows: idle 15-75s after launch (no transcript), stream 80-140s,
  idle-with-transcript 150-180s (three rendered replies on stage, fake silent)
- harness: bench/fake-claude.py via BOB_CLAUDE_BIN — three identical ~16KB markdown
  replies, ~25-char text_deltas at 40 events/sec, first reply at handshake+75s, 5s gaps
- machine: $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion)
- ambient pollers read the real ~/bob and ~/.claude dirs, so environment noise
  exists but is consistent across runs
- cpu profile: $TS-$LABEL.sample.txt beside this file (not committed)
EOF

echo
echo "wrote $MD"
cat "$MD"
