# bob — extensions

How you add things to bob without me editing Swift.

Status: **design, not built.** Nothing here exists yet. This document is the
argument for a shape, and the list of things v1 deliberately will not do.

## The gap

bob already has extensions. They just can't draw anything.

```
~/bob/skills/play-music.md
~/bob/skills/watch-pr.md
```

Those are real: you wrote them, they are plain files in a folder you own, and
adding one needs no rebuild. They change what bob **does**.

There is no equivalent for what bob **shows**. Every visible thing in bob is
compiled in. `AppSurface` is a two-case enum — `notes`, `canvas` — and adding a
third means editing the enum, a switch, a symbol table and a router, then
rebuilding and reinstalling.

The evidence that this is a real ceiling and not a theoretical one:

- **The terminal shipped as a floating panel**, not as a surface, specifically
  because becoming a surface cost more than the feature did.
- **`NSPanel` setup is now written by hand three times** — `SessionPanel`,
  `FileViewer`, `TerminalPanel` — 74 lines of near-identical window
  configuration, drifting apart as each one learns something the others don't.
- Three real cases is the point at which a seam can be cut from evidence
  instead of guessed at. We are past it.

## The one-line version

`~/bob/skills/` changes bob's behaviour. `~/bob/extensions/` should change bob's
surface. Same idea, same folder, same plain files.

## Non-goals

Naming these first, because most of the cost of an extension system comes from
goals nobody stated out loud.

- **Not a marketplace.** No publishing, no discovery, no install flow.
- **Not multi-user.** One person's machine. The moment a stranger's extension
  runs here, this document is wrong and needs a versioned contract, a real
  sandbox, and a deprecation policy. Build so that is *possible*, pay for none
  of it now.
- **Not an SDK.** No generated bindings, no typed client library, no docs site.
- **Not a plugin API in the VS Code sense** — a large imperative surface that
  extensions call into. See below.
- **Not a way to replace built-in UI.** An extension adds; it does not override
  the transcript, the input bar, or the tab strip.

## What VS Code got right, and where it costs

Worth copying:

- **Most extensions declare rather than draw.** "I add a command." "I add a view
  to the sidebar." The editor renders it. The API is mostly a list of *slots*,
  which is what keeps writing one tractable.
- **Extensions run out-of-process**, so a bad one cannot take the editor down.

Worth not copying:

- You must learn TypeScript and a large API before the first useful thing.
- Packaging and publishing ceremony.
- **Extensions cannot see each other's data.** Each keeps private state, so they
  never compose.
- You cannot edit an extension you installed; you fork it.
- Startup cost scales with the number installed.

The last two are where "but better" actually lives, and both fall out of
decisions bob has already made.

## The model

### 1. Slots

bob has a small number of places a thing can live. An extension declares which
one it wants. The list is short on purpose and grows only when a real case
demands it.

| slot | what it is | exists today as |
|---|---|---|
| `panel` | floating resizable window, own title, remembers its size | `SessionPanel`, `FileViewer`, `TerminalPanel` |
| `widget` | small always-on-top strip, no chrome, fixed screen position | nothing — this is the new one |
| `stage` | centre stage, full width, replaces the conversation | `notes`, `canvas` |
| `bar` | an icon in the top strip with a hover panel | the five ambient tiles |
| `rail` | the right gutter of a session | `SessionRail`, `CodexRail` |

`widget` is `panel` with a different window level, no titlebar, and a screen
anchor instead of a remembered frame. That is the whole difference, and it is
why the sequencing below builds `panel` first and gets `widget` nearly free.

### 2. A folder, not a package

```
~/bob/extensions/deploys/
  extension.md      ← frontmatter: what it is, where it goes, what it may read
  view.html         ← what it draws
```

No manifest format to learn beyond YAML frontmatter, which `~/bob/skills/`
already uses. No build step. No install command — the folder existing *is* the
installation.

### 3. `extension.md`

```markdown
---
name: deploys
slot: widget
anchor: top-right
size: { width: 260, height: 40 }
refresh: 60s
reads:
  - shell: "vercel ls --json | head -c 4096"
---

Shows the most recent deploy and whether it is green.

Click opens the dashboard.
```

Frontmatter is the contract bob reads. The prose below it is for two audiences:
you in six months, and bob when you ask it to change this extension. That second
audience is the reason this is markdown and not JSON.

### 4. Drawing: HTML in a webview

Not because it is easy, but for three reasons that are specific to bob:

- **The model writes good HTML.** The isometric codebase diagram that started
  this conversation is exactly this, already proven.
- **A `WKWebView` is a separate process.** An extension that hangs or crashes
  takes its own content process with it, not bob. That is VS Code's isolation
  property without building an extension host.
- **One mechanism covers several wants at once** — a widget, a dashboard, a
  codebase diagram, eventually a browser view — instead of one bespoke Swift
  view per idea.

Native SwiftUI stays for everything bob already draws. The transcript, the input
bar and the tab strip are hot paths that cost real work to make cheap, and none
of that is being handed to a webview.

### 5. Data: one shared space

Every extension reads the same `~/bob` — notes, wiki, state, usage, sessions.
This is the part VS Code cannot do, and it is not a feature that needs building:
it is a consequence of bob having chosen plain files in one directory three
years before anyone asked for extensions.

Two extensions that both read `~/bob/state/` compose by construction. Two VS Code
extensions with private state never will.

### 6. Authorship: you ask, bob writes

The intended way to get an extension is not to write one.

> "bob, put my deploy status in the top right corner"

bob writes the folder. You read the markdown, change the number you don't like,
and it reloads.

This is the only part of this document that justifies building it at all. A
folder-based plugin loader is a week of work and a solved problem everywhere. A
folder-based plugin loader **whose contents are written by asking** is the thing
no marketplace can hand you, and it only works because the format is small,
declarative, and made of text a model is good at.

## Capabilities — the hard part, stated honestly

The interesting question is not how to load a folder. That is a day. It is what
an extension is allowed to do, and then not changing the answer.

Declared in frontmatter:

- `reads.files` — globs under `~/bob`
- `reads.state` — named app facts: active session, usage, git branch, tab list
- `reads.shell` — a command whose stdout the view receives

**An extension runs with your privileges.** `reads.shell` means arbitrary
execution; a command can reach the network and write anywhere you can. The
manifest documents *intent* — it is a thing you can read before trusting a
folder — but it is not a sandbox and this document will not pretend otherwise.

That is acceptable while you are the only author and bob is the only thing
writing these folders. It stops being acceptable the moment an extension arrives
from somewhere else, and that is the trigger to revisit — not a later nice-to-have.

The honest alternative, if that day comes: drop `reads.shell`, give the host a
fixed menu of data sources, and make extensions pure views over them. Worth
knowing now that this is the escape hatch, because it is much easier to remove a
capability that was always declared than to add a declaration later.

## Lifecycle

- **Discovery** — scan `~/bob/extensions/*/extension.md` at launch, and on write
  via the existing `DirWatcher`. A malformed manifest is skipped with its error
  surfaced, never fatal.
- **Activation** — nothing loads until its slot is on screen. A `panel`
  extension costs nothing until you open it; a `widget` costs nothing until it
  is enabled.
- **Refresh** — `refresh:` is a floor, not a promise, and it does not tick while
  the extension is hidden.
- **Teardown** — hiding a slot tears its webview down. A hung extension is
  killable without restarting bob.

## Performance budget

bob went from 26% idle CPU to 0.2% and has held it through a month of features.
An extension system is the classic way to give that back, so it gets gates like
everything else.

1. **Zero extensions installed must not move any existing bench window.**
2. **Installed-but-hidden must cost nothing measurable** — no timer, no webview,
   no watcher beyond the one directory scan that already exists.
3. **A new bench case**: several extensions visible and refreshing, measured
   against the same idle/stream/idle-with-transcript windows.

If a webview per visible extension turns out to cost more than the budget, the
answer is fewer visible extensions, not a looser budget.

## What v1 deliberately cannot do

- Only **one slot**: `panel`. Everything else stays compiled in.
- **No custom slots.** You cannot invent a new region of the window.
- **No cross-extension messaging.** They share `~/bob` and nothing else.
- **No background work.** Hidden means stopped.
- **No writing** to `~/bob` from an extension. Read-only until there is a case.
- **No versioning, no compatibility promise.** The format will change under you,
  and bob rewrites your folders when it does.

## Sequencing

1. **Consolidate the three hand-rolled panels** into one host. No extension
   support yet — this is a pure refactor with an immediate payoff, and it is the
   thing that proves the panel abstraction is real before anything depends on it.
2. **`panel` extensions.** Manifest, discovery, webview host, the `reads`
   surface, the bench case. One real extension written by hand to prove it.
3. **`widget`.** Same host, different window level and a screen anchor. Nearly
   free once (2) exists, and it is the first piece of bob that lives outside
   bob's own window.
4. **Bob writes them.** A skill that turns "put X in the corner" into a folder.
   Only worth doing once the format has survived a few hand-written ones.
5. **Revisit the slot list** against what was actually built, and only then
   consider `stage` — which is where the `AppSurface` enum finally dies.

## Open questions

Things this document deliberately does not decide.

1. **Is `reads.shell` in v1?** It is what makes the deploy-status example work
   and it is the capability that makes the security section uncomfortable. The
   alternative is a fixed menu of data sources and a much smaller v1.
2. **What is the first real extension?** It should be something glanceable that
   is wanted independently of proving the system — otherwise the format gets
   designed against a toy.
3. **Does a `panel` extension get the glass chrome** the terminal now has, or
   draw its own titlebar inside the webview?
4. **`~/bob/extensions/` or `~/bob/surfaces/`?** Extensions is the more honest
   name if this later holds non-visual things too.

## Risks

- **The API gets designed against imagined extensions.** VS Code's grew over a
  decade against real ones. Mitigation is the sequencing above: one slot, one
  real extension, then decide.
- **The perf win gets spent.** Mitigation is the gates, run before merge, with a
  control on the branch's own base.
- **HTML becomes the path of least resistance** and bob's native feel erodes one
  webview at a time. Mitigation is the rule that extensions add and never
  replace: nothing bob already draws moves into a webview.
- **It never gets used.** The real failure mode. If after (2) and (3) the only
  extensions are the ones written to test the system, that is the answer, and the
  right move is to delete it rather than keep feeding it.
