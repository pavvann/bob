# changelog

what changed in bob, newest first. one entry per shipped thing, with the PR that carried it
and the number that mattered. written for the person using bob, not for the diff.

Convention: every change arrives on a branch, through a PR, reviewed independently before it
lands. Dates are merge dates.

## in review

- **the companion stops carrying a coding terminal** — [#33](https://github.com/pavvann/bob/pull/33), closes #31.
  bob's own chat spawned with the full terminal loadout: ~94 global skills, 9 MCP servers, 89
  tools — **53.6k tokens (27% of the window) before a word was typed**. The companion now runs a
  slim, bob-owned loadout (11 tools it actually uses, no global MCP, project settings only):
  **32.0k tokens, 16%**. Work sessions keep the full loadout, byte for byte — they are supposed
  to match the terminal. Editable at `~/bob/state/companion-loadout.json`, every kept tool
  documented with its token price.

## 2026-08-27

- **a resumed conversation shows the conversation** — [#32](https://github.com/pavvann/bob/pull/32), closes #30.
  Restored tabs came back holding the right conversation over an empty stage, and `/resume` hid
  the tab's own thread — so the only rows left to click were older ones, and picking one moved
  the session off its newest turns. Tabs now hydrate their transcript on relaunch, the current
  thread stays in the picker marked as such, and rows are dated by their newest real message
  instead of file mtime, which the CLI's idle heartbeats had been falsifying by up to nine days
  (16 of 32 projects listed in the wrong order). Also: a dying process can no longer re-adopt
  the conversation it was asked to leave.

## 2026-08-24

- **the statusline** — [#28](https://github.com/pavvann/bob/pull/28), closes #1.
  Subscription state lives in the top-right corner — 5-hour usage, when it resets, the week —
  and each session carries `model · ctx%` under its input bar. Percentages take the terminal's
  colour ramp. Reads the OAuth usage endpoint every ten minutes, on app-activate, and whenever a
  session's own wire reports a rate-limit event; the countdown ticks in a leaf view once a
  minute. Context is measured from per-turn usage against the model's real window, and any
  session that outgrows its assumed window promotes its own denominator rather than pinning at
  100%.
- **the comet holds its speed around the bar** — [#29](https://github.com/pavvann/bob/pull/29).
  Moving the border to the render server left it spinning at constant *angular* rate, so on a
  wide bar the head crawled through the long edges and shot around the ends. The rotation is now
  keyframed to uniform arc length — same zero per-frame cost, even pace.

## 2026-08-19 — the performance redesign

Bob idled at **26% CPU** doing nothing, and pinned a core whenever a transcript was on screen.
Measured, then fixed in phases, each benchmarked. Integrated as
[#27](https://github.com/pavvann/bob/pull/27); tracked in #12.

| | before | after |
|---|--:|--:|
| idle | 18.6% CPU | **0.1%** |
| idle, transcript on stage | 87.6% CPU | **0.07%** |
| streaming | 89.9% | **~66%** |
| main-thread file reads | ~340/min | **0** |

- **a deterministic bench** — [#20](https://github.com/pavvann/bob/pull/20). A fake claude that
  replays the stream-json protocol on a fixed clock, and `bench/run.sh` measuring real CPU-seconds
  per window. Every phase below was judged against it.
- **animations move to the render server** — [#21](https://github.com/pavvann/bob/pull/21). The
  ambient wash was animating four window-sized blobs forever under a 105pt blur; the comet was
  doing 27 path flattenings per frame on the main thread. Now: a cached wash that crossfades, a
  Core Animation comet, and every always-on animation pauses when its window isn't visible.
  The law learned here: a SwiftUI-driven forever-animation re-runs layout for the whole window
  every frame — idle flourishes settle and freeze, anything that must move forever lives on a
  layer.
- **coalesce the wire to the display** — [#22](https://github.com/pavvann/bob/pull/22). Streamed
  text lands as at most one UI mutation per 16ms instead of one per token, boundaries flush ahead
  of themselves so ordering survives, and wire chatter never reaches the main thread at all.
- **the transcript storm** — [#23](https://github.com/pavvann/bob/pull/23). The full core burned
  with a transcript on screen turned out to be a resonance driven by ordinary pointer movement:
  two owners of the scroll offset re-pinning each other, the whole transcript laid out twice per
  pass, transcript-wide animations stretching each kick. One scroll follow, one layout pass, one
  live row.
- **the transcript is a store** — [#24](https://github.com/pavvann/bob/pull/24). Message content
  moved out of the session object: completed rows immutable, one mutable tail. A token now
  invalidates one row instead of the window.
- **parse once** — [#25](https://github.com/pavvann/bob/pull/25). Markdown blocks parse and style
  exactly once and keep their identity; only the unstable tail re-parses. A 16KB reply cost
  2,026ms of parse work before, 30ms after. `/resume` stopped hitching, and the 24KB
  fall-back-to-plain-text cliff is gone.
- **the filesystem tells bob when a file changed** — [#26](https://github.com/pavvann/bob/pull/26).
  Thirteen poll loops became one ref-counted FSEvents watcher; state mirrors write in order;
  every publish is equality-guarded. Fixed on the way: the calendar tile could stay stuck on
  "denied" after you granted access.
- **widgets step aside on a session page** — [#19](https://github.com/pavvann/bob/pull/19),
  closes #3. The ambient tiles collapse to icons while you're reading a session; hovering one
  brings the whole tile back over the transcript.

## 2026-08-14

- **chat and sessions you can actually read** — [#17](https://github.com/pavvann/bob/pull/17).
  Transcripts render as markdown — tables as tables, code as code — with real tree-sitter
  syntax highlighting (40 grammars, and a linker trick that kept the app at 16MB instead of
  101MB). Plus the file tree on the left, a tabbed code viewer that remembers its size, the
  branch chip and agent rows in the right gutter, and a chooser when claude asks a question.

## 2026-08-13

- **/resume** — [#15](https://github.com/pavvann/bob/pull/15). Pick up any past conversation in
  this project, in any session — the picker lists the conversations you had, not the errands bob
  ran on your behalf.
- **a way home** — [#16](https://github.com/pavvann/bob/pull/16). A chip, ⌘B, and one more esc
  layer, so a session page is never a dead end.
- **bob goes wild — the single claude interface.** The stretch that made bob the place claude
  lives instead of a widget dashboard: persistent sessions with work-session tabs that survive a
  relaunch, ask-first permissions, the attention centre and `>name` dispatch, the notes and
  canvas surfaces, the model dial (opus by default, never the priciest tier by accident), and
  minions for delegated work.

## 2026-05-26 → 05-29

- **bob exists.** SwiftUI mac app, blurred window, voice in and out, the animated input border;
  the claude bridge with session continuity; the `~/bob` workspace; and the first ambient tiles —
  music, work, calendar, todos, weather.
