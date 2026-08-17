#!/bin/bash
# bench/run.sh <label> [--skip-build] — one deterministic perf run.
#
# Builds Bob.app, launches it against bench/fake-claude.py (BOB_CLAUDE_BIN),
# samples CPU/RSS once a second through a fixed timeline — settle 15s, idle
# window 15-75s, stream window 80-140s (the fake's replies start at handshake
# +75s) — takes a 10s `sample` profile, quits bob gracefully, and writes
# bench/results/<utc>-<label>.md. Compare .md files across branches for
# honest before/after numbers.
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
RAW="$(mktemp -d)"

BOB_CLAUDE_BIN="$ROOT/bench/fake-claude.py" "$ROOT/Bob.app/Contents/MacOS/Bob" >/dev/null 2>&1 &
BOBPID=$!
LAUNCH=$(date +%s)
echo "launched Bob (pid $BOBPID)"

# sample_window <start offset s> <end offset s> <out file>
sample_window() {
    while [ "$(date +%s)" -lt $((LAUNCH + $1)) ]; do sleep 1; done
    : > "$3"
    while [ "$(date +%s)" -lt $((LAUNCH + $2)) ]; do
        if ! ps -o %cpu=,rss= -p "$BOBPID" >> "$3"; then
            echo "Bob died mid-run — check ~/bob/state/bridge-stderr.log" >&2
            exit 1
        fi
        sleep 1
    done
}

echo "settling, then idle window (15-75s)"
sample_window 15 75 "$RAW/idle.txt"
echo "stream window (80-140s)"
sample_window 80 140 "$RAW/stream.txt"

PROFILE="$RESULTS/$TS-$LABEL.sample.txt"
echo "profiling 10s -> $PROFILE"
sample "$BOBPID" 10 -file "$PROFILE" >/dev/null

osascript -e 'quit app "Bob"' || true
for _ in $(seq 1 15); do
    kill -0 "$BOBPID" 2>/dev/null || break
    sleep 1
done
kill -0 "$BOBPID" 2>/dev/null && echo "warning: Bob did not quit — quit it yourself (never kill it)" >&2

# stats <file> -> "avg_cpu max_cpu max_rss_mb"
stats() {
    awk '{ c += $1; if ($1 > mc) mc = $1; if ($2 > mr) mr = $2; n++ }
         END { if (n) printf "%.1f %.1f %.0f", c / n, mc, mr / 1024 }' "$1"
}
read -r IDLE_AVG IDLE_MAX IDLE_RSS <<< "$(stats "$RAW/idle.txt")"
read -r STREAM_AVG STREAM_MAX STREAM_RSS <<< "$(stats "$RAW/stream.txt")"
MAX_RSS=$IDLE_RSS
[ "$STREAM_RSS" -gt "$MAX_RSS" ] && MAX_RSS=$STREAM_RSS
rm -rf "$RAW"

MD="$RESULTS/$TS-$LABEL.md"
cat > "$MD" <<EOF
# bench: $LABEL

| label | commit | idle avg CPU% | idle max CPU% | stream avg CPU% | stream max CPU% | max RSS (MB) |
|---|---|---|---|---|---|---|
| $LABEL | $SHA | $IDLE_AVG | $IDLE_MAX | $STREAM_AVG | $STREAM_MAX | $MAX_RSS |

- machine: $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion)
- windows: idle 15-75s after launch, stream 80-140s; \`ps -o %cpu,rss\` once a second
- harness: bench/fake-claude.py via BOB_CLAUDE_BIN — three identical ~16KB markdown
  replies, ~25-char text_deltas at 40 events/sec, first reply at handshake+75s, 5s gaps
- ambient pollers read the real ~/bob and ~/.claude dirs, so environment noise
  exists but is consistent across runs
- cpu profile: $TS-$LABEL.sample.txt beside this file (not committed)
EOF

echo
echo "wrote $MD"
cat "$MD"
