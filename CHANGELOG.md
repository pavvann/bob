# changelog

what changed in bob, newest first. one entry per shipped thing, with the PR that carried it
and the number that mattered. written for the person using bob, not for the diff.

Convention: every change arrives on a branch, through a PR, reviewed independently before it
lands. Dates are merge dates.

Versions: the marketing version lives in `./VERSION` and is stamped into the bundle by
`make app`, alongside a build number that is simply the commit count — monotonic without a
counter to maintain, reproducible from any checkout. A released section below is named for the
version it shipped as; `in review` is whatever has not merged yet. `Bob → About Bob` reads the
same string bob hands codex as its client version.

## in review — 0.3.0

- **the companion stops carrying a coding terminal** — [#33](https://github.com/pavvann/bob/pull/33), closes #31.
  bob's own chat spawned with the full terminal loadout: ~94 global skills, 9 MCP servers, 89
  tools — **53.6k tokens (27% of the window) before a word was typed**. The companion now runs a
  slim, bob-owned loadout (11 tools it actually uses, no global MCP, project settings only):
  **32.0k tokens, 16%**. Work sessions keep the full loadout, byte for byte — they are supposed
  to match the terminal. Editable at `~/bob/state/companion-loadout.json`, every kept tool
  documented with its token price.

- **an app icon, and `make install`** — [#59](https://github.com/pavvann/bob/pull/59). Bob has a
  face, and a one-line way into /Applications. The source art had no alpha, so its corners were
  opaque black and would have rendered as a hard square; the silhouette is derived from the art
  itself and placed on Apple's icon grid so bob sits at the same optical size as its neighbours.
- **PATH from an interactive login shell** — [#60](https://github.com/pavvann/bob/pull/60). Bob
  reported "codex binary not found" for a binary that ran fine in a terminal, and the codex/claude
  switcher quietly disappeared from the new-session picker with it. `zsh -lc` is a login shell that
  is *not interactive*, so it skips `.zshrc` — which is where npm's global prefix, pyenv, cargo and
  nvm actually add themselves. A GUI-launched bob was computing a PATH the owner's terminal has
  never had. claude was spared only because homebrew happens to sit on the non-interactive path.

## 0.2.0 — 2026-08-31

The release that made bob two-agent, gave it a real terminal, and got it an icon.

Bob hosts **Codex sessions** alongside Claude ones: same window, same tabs, same transcript, same
ask-first permissions.

Codex ships a protocol built for GUI hosts — `codex app-server`, a persistent process speaking
newline-delimited JSON-RPC — so most of bob retargeted rather than got rebuilt. Three things arrive
free that Claude made bob work for: the context window is reported exactly, the subscription
percentages are pushed on every turn (no polling, no keychain), and listing past conversations is
one request instead of a transcript parser.

- **the protocol, pinned** — [#40](https://github.com/pavvann/bob/pull/40), closes #36. The 291
  generated schema files committed as a version fixture, a re-runnable protocol recorder, and six
  behaviours settled by probe: an unanswered approval never expires, a second turn on one thread is
  silently *merged* into the running one, child processes survive an interrupt, and the daemon
  cannot outlive bob (so a local websocket is the mechanism for background work).
- **the transport** — [#41](https://github.com/pavvann/bob/pull/41). One shared app-server, threads
  as tabs, turns streaming into the existing transcript store through the existing coalescer.
- **sessions you can open and use** — [#42](https://github.com/pavvann/bob/pull/42), closes #37. A
  provider capsule in the new-session picker, a hexagon on the tab, the same stage made generic
  rather than twinned, a per-session dial for model · effort · sandbox · approvals, and codex's
  approvals routed into bob's own ask-first card with the buttons the wire actually offered.
- **the work made visible** — [#43](https://github.com/pavvann/bob/pull/43). Commands stream their
  output into the rail while they run and land with an exit code; a failure goes red and refuses to
  fold away. Plus MCP calls, searches, file changes, and collapsible reasoning that stays absent
  when a model emits none.
- **the commands work** — [#46](https://github.com/pavvann/bob/pull/46). `/resume` was broken three
  ways: on a codex tab the word travelled to the model as a message, it appeared in no palette at
  all, and work tabs had no palette to begin with. Fixed, with a per-provider palette scoped to the
  tab's own project, and a codex resume picker that is one request ordered by real recency.
- **a first-class citizen** — [#47](https://github.com/pavvann/bob/pull/47). Codex sessions produce
  digests and answer to `>name`; the subscription strip follows whichever provider the active tab
  belongs to.
- **questions** — [#49](https://github.com/pavvann/bob/pull/49), closes #38. Codex's questions reach
  the chooser bob already had, answered on the request's own id.
- **the statusline reads the easy source** — [#48](https://github.com/pavvann/bob/pull/48), closes
  #39. Claude reports its context window and pushes both usage percentages on the wire; bob had been
  maintaining a table of model window sizes and reading a keychain token to poll an HTTP endpoint for
  numbers already in its own stdin buffer. Now both providers are symmetrical, and the keychain
  prompt is gone. A 425,933-token thread that used to pin at `ctx 100%` reads 42.6%.

Forty-one defects were found and fixed across thirteen independent review rounds getting here.

- **codex sessions in a terminal get a card and a panel** —
  [#53](https://github.com/pavvann/bob/pull/53), closes #52. A codex session running in a terminal
  was invisible to bob while a claude one got a live panel. Two filters decide what earns a card:
  `originator`, codex's analog of claude's `sdk-cli` stamp, and `source`, which has to be the
  literal string `cli` — a subagent thread carries the same originator with an *object* there, and
  33 of 45 tui rollouts on this machine are subagents, so filtering on originator alone puts three
  noise cards in the band for every real one. Rollouts are also filed by the day a session
  *started*, so one open for a week sits in last week's directory: the scan crosses date dirs.
- **a real terminal** — [#55](https://github.com/pavvann/bob/pull/55), closes #54 and #7. A pty with
  a login shell in a floating panel, one per working directory, opened from a button beside the
  input box. `vi`, `ngrok`, a dev server — anything you would type in a terminal. Closing the panel
  *hides* it: the process, the pty and the scrollback survive, so a dev server does not die because
  you shut the window. Only the shell exiting closes one for real. Burst output measured at ~105k
  lines/sec cost 2.8s of cpu and settled clean, and with no terminal open idle sits on the
  performance baseline to the tenth.
- **the protocol fixture retired** — [#57](https://github.com/pavvann/bob/pull/57). The 291 generated
  schema files #40 pinned were reference material, and the reference had been read: nothing in the
  build, the bundle or the runtime ever loaded them. What they caught lives in the decoder and the
  probe findings now, and the files stay recoverable from git history, so only 3.7MB of noise left
  every clone, worktree and file tree.

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
