# bob — architecture

A synthesis of what makes OpenClaw, Hermes, Karpathy's LLM Wiki, and the broader voice-AI landscape work — turned into concrete design rules for bob.

## The premise

bob is a conversational interface to your own computer. You talk; bob talks back. Over time, bob writes down what it learns about you in **markdown files you own and can read**. The window has no chrome because the conversation is the product. The memory has no magic because Karpathy is right — implicit personalization is anti-user; the artifact is explicit.

bob is **not** a productivity tool, **not** a second brain, **not** an agent that takes actions. It is a place to think out loud with your computer.

## Three pillars (one borrowed from each lineage)

### 1. Plain-text everything — borrowed from OpenClaw

Identity, memory, rules, skills all live as readable markdown. The user can `cat`, `grep`, edit by hand, diff in git. No SQLite-hidden state, no opaque vector store. If bob "knows" something about you, it's a line in a file you can open in Finder.

### 2. Wiki memory — borrowed from Karpathy

Bob's long-term memory is a **navigable wiki** under `~/bob/`, not an embeddings blob. It uses an `index.md` catalog instead of RAG at small scale. Three explicit operations: **ingest** (write new things in), **query** (read relevant things out), **lint** (dedupe, fix contradictions, archive). The user can `git diff` what bob added after every session.

> "The memory artifact is explicit and navigable... you can see exactly what the AI does and does not know and you can inspect and manage this artifact." — Karpathy, [Farzapedia](https://x.com/karpathy/status/2040572272944324650)

### 3. Self-authored skills — borrowed from Hermes

When you do a non-trivial multi-step thing with bob successfully, bob offers to save it as a markdown recipe in `~/bob/skills/`. Next time you say something close to the trigger, bob loads that recipe into context. This is how bob "learns repetitive tasks" — no fine-tuning, no continuous training, just a growing folder of `*.md` you can read.

## Directory layout

```
~/bob/                      ← User-owned, git-trackable, visible in Finder
├── SOUL.md                 ← Bob's persona / tone / behavior rules (small, edits rare)
├── USER.md                 ← What bob knows about you (facts, preferences)
├── index.md                ← Catalog of every wiki page with one-line summaries
├── log.md                  ← Append-only chronological ledger of sessions
├── wiki/                   ← Topic pages bob writes and maintains
│   ├── projects.md         ← Map of your 26 active + 39 orphaned projects (bob's first job)
│   ├── people.md
│   └── ...
├── skills/                 ← Self-authored recipes for repetitive tasks
│   ├── morning-brief.md
│   └── deploy-fam.md
├── raw/                    ← Untouched session transcripts, by date
│   └── 2026-05-24/
└── CLAUDE.md               ← Schema/config telling claude how to maintain the wiki
```

## Process model

```
SwiftUI app window (Ghostty-blur, no chrome)
   │
   ├── ConversationActor (one per active session)
   │     ├── command queue ........... serialize user → claude → user (OpenClaw lesson)
   │     ├── context assembler ...... SOUL + USER + index + matched wiki pages
   │     ├── claude bridge ........... spawn `claude -p --resume <id>` with prepared prompt
   │     ├── stream sink ............ pipe stdout to UI + append to raw/<date>/<id>.md
   │     └── post-session ingest .... ask claude to update wiki + log; show diff for approval
   │
   ├── VoiceInput (push-to-talk)
   ├── VoiceOutput (AVSpeechSynthesizer, opt-in)
   └── GlobalHotkey (summon / dismiss the window)
```

State invariant: **the model never touches I/O directly**. bob's Swift code assembles the prompt, parses the output, writes to files. Claude only sees a clean prompt. This is the "Gateway-owns-state" rule from OpenClaw — and it keeps prompt-injection out of the threat model.

## The three operations (borrowed from Karpathy)

- **talk** — the live conversation. Default mode. Spawns `claude -p` with assembled context.
- **ingest** — after a session ends, ask claude to write what should change in the wiki: new facts to `USER.md`, new topic pages, append to `log.md`. Show a unified diff before applying.
- **lint** — manual (or weekly) pass over the wiki to dedupe entries, resolve contradictions, archive stale facts to `wiki/archive/`. Karpathy: "lint is non-optional."

## Context budget (don't repeat Hermes' mistake)

Hermes ships ~45k tokens of memory per call in long-running setups. That's the failure mode to avoid.

Targets:
- **Always loaded:** `SOUL.md` + `USER.md` + `index.md` → cap at **~2k tokens combined**
- **On-demand loaded:** wiki pages whose index entries fuzzy-match the current query → cap at **~6k tokens added**
- **Never loaded by default:** `log.md` history, full raw transcripts, archive

Bob enforces these caps in Swift before calling `claude -p`. If a wiki page grows past a threshold, bob suggests splitting it.

## UX rules

What bob **does** do:
- Float on top, blurred, no titlebar (already shipped in v0)
- Summon with a global hotkey, dismiss with `Esc` or focus loss
- Hold-to-talk for voice (push-to-talk feels conversational; always-listening feels surveillant — Wispr lesson)
- Show the raw transcript before sending (Cleft lesson: don't silently rewrite the user)
- Voice in, text out by default; TTS opt-in (Tab lesson: text respects shared spaces)
- Reflective follow-up turns, not one-shot Q&A (Pi lesson, minus Pi's lack of utility)

What bob **doesn't** do:
- No sidebar / history pane / "new chat" button — to revisit past sessions, open `~/bob/log.md` in your editor
- No always-on mic or screen capture (Highlight + Cluely's burned trust)
- No "invisible to others" / cheating positioning (Cluely)
- No persistent floating overlay following your cursor
- No marketplace or skill hub (OpenClaw's ClawHub got poisoned with malicious skills)
- No agent autonomy / no actions on your behalf in v1 (keeps the prompt-injection threat model trivial)
- No embeddings or fine-tuning until grep + `index.md` provably hits its limit

## Threat model (small on purpose)

bob does not act on the world. It reads markdown, calls `claude -p`, writes markdown. The OpenClaw CVE class (`127.0.0.1` WebSocket → one-click RCE) doesn't apply because bob doesn't expose a network surface. If bob ever does:
- localhost-only + token-required + origin-header validation, non-negotiable
- API keys (if any) go in macOS Keychain, not files
- Confirm-before-execute defaults for anything that touches the shell beyond `claude -p`

## What v0 already does (as of 2026-05-24)

- SwiftUI Mac app, Ghostty-style `NSVisualEffectView` blur, hidden titlebar, drag-anywhere window
- Text input → `claude -p` via `/bin/zsh -l -c`, streams stdout into the response area
- Voice input (Speech framework) with mic toggle
- Voice output (AVSpeechSynthesizer) opt-in, off by default
- `make app` produces a properly bundled `Bob.app` with mic + speech-recognition entitlements

## What to build next (priority order)

1. **Bootstrap `~/bob/`** — initialize SOUL.md, USER.md, CLAUDE.md, empty wiki/skills/raw/log dirs on first launch. Bob's first job: scan `~/Code/` + `~/.claude/projects/` and write `wiki/projects.md` (the map of the 86 projects). This is the "context of all my projects" feature, done explicitly.
2. **Context assembler in Swift** — read SOUL + USER + index before each `claude -p` call; fuzzy-match index entries against the query; concatenate matched pages; enforce token caps.
3. **Session persistence with `claude -p --resume`** — give every session an ID, write `raw/<date>/<id>.md` as it streams. One session per bob "window opening."
4. **Ingest pass** — at session end, spawn a second `claude -p` whose system prompt is "given this transcript, propose diffs to ~/bob/wiki/ and ~/bob/log.md." Show diff in bob's UI, accept/reject per-hunk.
5. **Global hotkey** — Carbon `RegisterEventHotKey` to summon/dismiss the window. Default to `⌥Space`, configurable.
6. **Push-to-talk** — hold-space-to-talk replacing the click-to-toggle mic.
7. **Skills** — `~/bob/skills/<name>.md` with trigger phrases. Slash-command activation + fuzzy auto-suggestion.
8. **Lint command** — `bob lint` runs a claude pass over the wiki for dedupe/staleness.

Each step is independently shippable. Build → use → see what feels wrong → adjust.

## Inspiration / sources

- [Karpathy LLM Wiki gist (April 2026)](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) — the whole memory model
- [Karpathy LLM OS tweet (2023)](https://x.com/karpathy/status/1707437820045062561) — context-as-RAM framing
- [openclaw/openclaw](https://github.com/openclaw/openclaw) — plain-markdown identity files, gateway-owns-state, command queue
- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) — self-authored SKILL.md procedural memory
- Granola — Mac-native polish reference
- Pi (Inflection) — minimal-chrome conversational shape (without the no-utility trap)
- Wispr Flow — hold-to-talk dictation pattern
