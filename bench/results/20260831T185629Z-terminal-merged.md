# bench: terminal-merged

| label | commit | idle CPU% | stream CPU% | idle+transcript CPU% | max RSS (MB) |
|---|---|---|---|---|---|
| terminal-merged | 1517228 | 0.2 | 57.1 | 0.4 | 147 |

- CPU% = cputime delta over the window, of one core (can exceed 100)
- windows: idle 15-75s after launch (no transcript), stream 80-140s,
  idle-with-transcript 150-180s (three rendered replies on stage, fake silent)
- harness: bench/fake-claude.py via BOB_CLAUDE_BIN — three identical ~16KB markdown
  replies, ~25-char text_deltas at 40 events/sec, first reply at handshake+75s, 5s gaps
- machine: Apple M1, macOS 26.5.1
- ambient pollers read the real ~/bob and ~/.claude dirs, so environment noise
  exists but is consistent across runs
- cpu profile: 20260831T185629Z-terminal-merged.sample.txt beside this file (not committed)
