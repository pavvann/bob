import Foundation

/// Seed content for the lens layer: `lenses/*.md`, `backlog.md` and the two
/// `wiki/bob/` pages that carry bob's self-improvement judgment.
///
/// These are the generic variants written on a fresh install — the user's live
/// copies are theirs to edit and are never overwritten (see `ensureSeedFiles`).
extension BobHome {

    /// Registered into `ensureSeedFiles()`. Order is irrelevant; each is
    /// written only when absent.
    var lensSeedFiles: [(URL, String)] {
        [
            (lensesDir.appendingPathComponent("talk.md"), seedLensTalk),
            (lensesDir.appendingPathComponent("music.md"), seedLensMusic),
            (lensesDir.appendingPathComponent("project.md"), seedLensProject),
            (lensesDir.appendingPathComponent("open-line.md"), seedLensOpenLine),
            (lensesDir.appendingPathComponent("retro.md"), seedLensRetro),
            (lensesDir.appendingPathComponent("bob-dev.md"), seedLensBobDev),
            (backlogPath, seedBacklog),
            (wikiBobDir.appendingPathComponent("retro.md"), seedRetroProtocol),
            (wikiBobDir.appendingPathComponent("self-improvement.md"), seedSelfImprovement),
        ]
    }

    // MARK: lenses

    var seedLensTalk: String { """
    ---
    budget: 2000
    files:
      - MEMORY.md
    ---

    pure conversation mode — no delegation reflex, no file updates unless something
    durable surfaces. talk like a person who has been paying attention.
    """
    }

    var seedLensMusic: String { """
    ---
    budget: 3000
    files:
      - MEMORY.md
      - wiki/music/*.md
      - skills/play-music.md
      - state/music.json
    ---

    music mode. he's talking about music — playing it, finding it, building sets.

    - playback goes through the play-music skill above — one call. never the manual
      curl/osascript/bob:// dance when the skill covers it.
    - default to FULL CATALOG discovery unless he says "from my library".
    - taste spine: whatever `wiki/music/*.md` and MEMORY.md record. push discovery at
      the edges of that spine, not random. if the spine isn't written down yet, ask
      once and write the answer into `wiki/music/taste.md`.
    - storefront matters — itunes search needs the right `country=` or the trackIds
      you get back 404 on playback.
    - if playback silently fails, check MEMORY.md for a subscription or permission
      note before debugging the pipeline.
    """
    }

    var seedLensProject: String { """
    ---
    budget: 5000
    files:
      - wiki/projects/{arg}.md
      - MEMORY.md
    ---

    project mode: {arg}. ground answers in the wiki page; note drift between the page
    and what he says, and fix the page inline.
    """
    }

    var seedLensOpenLine: String { """
    ---
    budget: 1500
    files:
      - USER.md
      - MEMORY.md
      - log.md
    ---

    you're writing bob's one-line opener — the first thing he reads when the window
    appears. it should feel like a friend picking up mid-thought, not an assistant
    greeting a user.

    - draw on the most recent real thing above: what he was building, what he said
      last, what's still open.
    - specific beats warm. no "hope you're well", no questions about his day.
    - if nothing recent stands out, say something about right now (time, weather,
      what's playing) rather than inventing a thread.
    """
    }

    var seedLensRetro: String { """
    ---
    budget: 6000
    files:
      - MEMORY.md
      - index.md
      - backlog.md
      - wiki/bob/retro.md
    ---

    nightly retro pass — follow `wiki/bob/retro.md` exactly. everything additive;
    never rewrite history. if a source is missing, note it in `log.md` and move on.
    """
    }

    var seedLensBobDev: String { """
    ---
    budget: 6000
    files:
      - wiki/bob/self-improvement.md
      - backlog.md
      - wiki/projects/bob-app.md
    ---

    you are working on bob's own code — the swift/swiftui app, not the `~/bob` data
    directory. the repo path is the minion record's `workdir`.

    the guardrails in `wiki/bob/self-improvement.md` are hard rules, not suggestions.
    branch, build, commit, never push. small diffs that match the house style beat
    clever ones.
    """
    }

    // MARK: backlog

    var seedBacklog: String { """
    # backlog — bob's own improvement queue

    things bob has noticed about itself (app papercuts, wiki drift, feature ideas).
    added by conversational bob or the nightly retro. dispatched as minions — code
    items land as `bob/<id>` branches in bob's source repo, never merged by bob.

    format: `- [ ] <id> | app|wiki | S|M|L | <title> — <detail> (added YYYY-MM-DD by chat|retro)`
    done:   `- [x] ... → minion <minion-id>, branch bob/<id>` (code) or `→ done YYYY-MM-DD` (wiki)

    ids are sequential: `bl-0001`, `bl-0002`, ... never reuse one.

    ## items

    - [ ] bl-0001 | app | M | rewrite ARCHITECTURE.md to match shipped reality — it
      describes an unbuilt context-assembler, ingest/lint ops, and token caps that
      lenses now actually implement (added 2026-08-10 by chat)
    - [ ] bl-0002 | app | S | evaluate dropping ~/.claude/CLAUDE.md from bob's turns
      via --setting-sources — measure what user-level config is lost first
      (added 2026-08-10 by chat)
    """
    }

    // MARK: wiki/bob pages

    var seedRetroProtocol: String { """
    ---
    type: concept
    updated: 2026-08-10
    sources:
      - bob design conversations
    ---

    # bob — retro protocol

    the nightly pass where bob reviews its own day. the swift side only supplies the
    date and the sources; **the judgment lives here**, so bob can refine this page
    over time. that's the point — the self-improvement loop applies to the loop.

    ## the pass, in order

    1. **MEMORY.md promotions.** a bullet older than ~14 days that still matters, or
       a topic that has outgrown a few bullets, becomes a `wiki/<topic>/<page>.md`
       with an `index.md` row. mark the originals `→ moved to ...`. never delete.
    2. **index.md drift.** pages that exist but aren't listed, summaries that no
       longer describe the page, rows pointing at files that are gone.
    3. **backlog.md.** append what was actually observed today — schema is in the
       file header. dedupe against existing items before adding.
    4. **skills.** a multi-step pipeline repeated ≥3 times across sessions earns
       `skills/<name>.md` (+ `skills/bin/<name>` for the mechanical part) and a
       `.claude/skills/<name>/SKILL.md` adapter whose body is one line: "follow
       ~/bob/skills/<name>.md".
    5. **dispatch.** at most ONE `S`-size backlog item per night as a minion, lens
       `bob-dev`, origin `self`. skip entirely if a `bob/*` branch is already in
       flight.
    6. **log.md.** one line: `## [<date>] retro | <what changed>`.

    ## judgment

    **what counts as stale:** a MEMORY bullet is stale when it describes a state of
    the world rather than a fact about him — "debugging the mic" goes stale, "prefers
    text over voice output" doesn't. stale-and-still-true → promote. stale-and-moot →
    leave it; the ledger is allowed to have history in it.

    **what makes a good backlog item:** something observed, not imagined. it names
    the felt symptom ("the chip overflows the input bar at 3 words") not a solution.
    one item = one branch's worth of work. if you can't size it S/M/L, it's not
    understood well enough to file yet.

    **what deserves skillhood:** the same *pipeline* three times, not the same topic
    three times. if the steps are identical and only the arguments change, it's a
    skill. if each run needed different thinking, it's just a recurring subject —
    that belongs in the wiki instead.

    **what never happens in a retro:** deleting his words, rewriting a page wholesale,
    editing `raw/`, or filing more than a handful of items. a retro that changed forty
    things changed nothing he can review.

    ## see also

    - [self-improvement guardrails](self-improvement.md)
    - `../../backlog.md`
    """
    }

    var seedSelfImprovement: String { """
    ---
    type: concept
    updated: 2026-08-10
    sources:
      - bob design conversations
    ---

    # bob — self-improvement guardrails

    bob can change its own code. the `bob-dev` lens injects this page into every code
    minion. these are **hard rules** — a minion that breaks one has failed, even if
    the change was good.

    1. **check the tree first.** `git status --porcelain` in the repo. if it's dirty,
       append a note to the backlog item and STOP — another agent is mid-flight.
    2. **branch.** create `bob/<item-id>` from the current branch; every commit goes
       there. commit messages start `bob:` and name the backlog id.
    3. **build before commit.** `swift build` must pass. no build, no commit, no claim
       of done.
    4. **never push.** never force-anything. never touch `main`, never delete a
       branch, never commit to a branch you didn't create.
    5. **never edit `~/bob/bin/run-minion.py`.** it's regenerated from the swift
       source at every launch — edits there are lies. change the swift literal.
    6. **close the loop.** check the backlog item `[x]` with the branch name, then
       switch the repo back to the branch you found it on.
    7. **wiki scope stays small.** `wiki` items are additive edits only, and each one
       appends `## [<date>] retro | <what changed>` to `log.md` — that's the whole
       attribution mechanism while `~/bob` has no git.

    ## why it's shaped this way

    nothing bob writes reaches `main` without a human reading it: `git branch --list
    'bob/*'` is the review queue, `git branch -D` is the undo. the app repo is where
    changes land because it's revertable; `~/bob` holds the intentions because they're
    memory. if a rule here ever blocks something genuinely worth doing, file a backlog
    item arguing for the change — don't route around it.

    ## see also

    - [retro protocol](retro.md)
    - `../../backlog.md`
    """
    }
}
