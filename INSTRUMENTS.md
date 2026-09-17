# bob — instruments

How bob grows new capability without me editing Swift.

Status: **design, not built.** Supersedes `EXTENSIONS.md` (PR #62), which got
three central things wrong. This document says what changed and why.

## Why this is not called "extensions"

"Extension ecosystem" is the wrong frame for a program with one user. The
success measure is not how many exist. It is whether small personal
capabilities become part of daily work without making bob incoherent.

That reframing is not cosmetic — it changes what to optimise for:

| VS Code optimises for | bob should optimise for |
|---|---|
| long-term API compatibility | automatic migration of all twelve local instruments |
| a large third-party population | future-you understanding what exists |
| publishing and discovery | no ceremony at all — the folder existing is the install |
| stability across versions | cheap experimentation and cheap deletion |

The unit is an **instrument**: one coherent answer, decision, or verb.

- "Are my deploys healthy?"
- "How much budget is left?"
- "What shape did this turn take?"
- "Resume the session that owns this file."

## The gap, stated correctly

bob has **no** extensibility of the application. Everything it does and
everything it draws is compiled in.

`~/bob/skills/` is not a counter-example, and the earlier doc was wrong to claim
it. A skill is **instructions for the model** — trigger phrases and a recipe
loaded into context. `play-music.md` is prose telling the model to call a
script. Bob.app never reads either file: it does not parse them, render them, or
behave differently because they exist. The model's behaviour changes; the
application's does not.

So the starting point is zero, not half.

What skills do prove is the harder half, and it is why this is worth attempting
at all: **the authorship loop already works.** `watch-pr.md` carries its own
origin note — *"drafted 2026-08-13 after the same shape got queued 3x in three
days."* bob wrote it because a pattern repeated, and it was kept. That loop,
aimed at capability instead of behaviour, is the entire proposal.

## What an instrument declares

```yaml
---
name: work-map
question: What shape did this turn take?

consumes:
  - events: [file.changed, command.finished, turn.completed]
owns:
  state: layout          # private; no other instrument may read it
actions:
  - file.open
  - session.focus
projections:
  - kind: stage
    invoked: true
  - kind: glance
    slot: top-right
    reveal: { on: [command.failed] }
---

Prose for two readers: future-me, and bob when I ask it to change this.
```

Five things, and the order matters: what it consumes, what it owns, what it can
do, where it appears, and why it exists.

**A projection is not the unit.** "Deploy status" is not five extensions — it is
one instrument contributing an ambient dot, a detail panel, a command, a
notification, and a fact. Making the surface the package boundary was the first
doc's central mistake.

## Moments — the part that decides whether any of this works

> A successful instrument does not merely run. It has a reliable moment in which
> it becomes relevant.

The usual failure of extensibility is not a bad SDK. It is that extensibility
creates **supply without recurring demand**. A thing can exist and nothing ever
brings it back into the work. Panels and dashboards are the most vulnerable of
all, because opening one is another decision.

So standardising the *moments* matters more than standardising the pixels — and
bob is unusually well supplied with them already. Its agents emit a real event
vocabulary today, rendered linearly and never synthesised: user and agent
messages, command execution with live output and exit code, MCP tool calls with
status, web searches, file changes, turn completion, failures. `SessionWatcher`,
`DirWatcher`, `AttentionCenter` and the minion lifecycle add more.

**An address is not a moment.** "Lives in the notch" is an address. "Production
went from healthy to failed" is a moment. Permanent visibility is legitimate
only with **differential salience** — quiet when normal, changing character when
attention is warranted. A number that updates continuously becomes wallpaper
inside a week.

One honest exception: some ambient things are valued as atmosphere or identity —
a clock, a fitness ring, today's total. That is a real reason and this is
personal software, so delight counts. It is just not what a first instrument
should be asked to prove.

## The grammar line

The sharp question is: **is bob willing to own the interaction grammar?**

If every instrument invents its own navigation, loading state, error handling
and visual language, bob stops being an application and becomes a window manager
for tiny websites — and a graveyard of attractive toys is then an expected
property, not a failure that better standards could prevent.

But "the host renders everything" fails the other way. Every genuinely new kind
of visual would need Swift — sparkline, dependency graph, map — which is the
exact ceiling this exists to escape, moved from "adding a panel" to "adding a
chart type."

The line that resolves it:

> **bob owns 100% of the outer grammar and 20–40% of the pixels.**

- **Host-owned, always:** how effects happen, how focus moves, how failure is
  shown, how navigation works, how an instrument is configured, how it reports
  it is broken.
- **Instrument-owned, freely:** what the picture is.

Native primitives exist so that "three facts and a button" does not require a
web application — value, status, sparkline-less list, action controls.
**Deliberately no chart primitives.** A sparkline is trivial SVG inside a web
projection; a chart taxonomy is exactly the trap.

Arbitrary web rendering is therefore **normal for genuinely visual work**, not a
rare escape hatch. The isometric codebase diagram that started this conversation
is a legitimate instrument, not an exception to be tolerated.

## Data in: the host fetches, the projection renders

**A projection has no network access.** Not a limitation — a boundary.

1. CORS: a remote API will not serve a local webview origin anyway.
2. Credentials stay out of `~/bob`. An API key in `view.html` is a plaintext
   secret in a folder everything can read.
3. It makes the capability section enforceable rather than aspirational: a
   projection that cannot reach the network can only render what bob handed it,
   and cannot quietly exfiltrate anything.
4. One refresh policy, host-owned — which is what the performance gates depend
   on.

The host runs declared sources off the main actor, only while the projection is
visible, and pushes results in. The projection may ask for a refresh; it may not
go and get one.

## Effects out: declared actions

The symmetric rule, and the place mini-app incoherence actually begins — not in
rendering, but in a broad JavaScript bridge added for convenience.

> bob owns every **effect** that crosses the projection boundary. Interaction
> *inside* a projection is free and unpoliced.

Pan, zoom, hover, select, filter, expand, drill down — the instrument's
business, and no two instruments need the same selection model. A dependency
graph and a table should not be forced to agree on what a blue outline means.

"Open this file", "resume that session", "redeploy" — declared named actions,
executed by the host.

The coherence worth defending is how effects, focus, failure and navigation
behave. Not whether every selected object looks the same.

## Permissions

bob already has an ask-first approval card that the user reads and trusts. The
risk in reusing it is habituation: if a weather instrument asks permission to
refresh, the user learns to approve without reading, and that degrades the card
for the agent sessions where it genuinely matters.

| request | behaviour |
|---|---|
| declared read / refresh | no approval |
| declared navigation, from an explicit click | immediate |
| declared bounded reversible effect, from an explicit click | immediate |
| destructive or high-impact effect | approve per invocation |
| effect initiated by a timer or event rather than the user | approve per invocation, always |
| **undeclared effect** | **rejected — no card offered** |

That last row matters most. An undeclared action must not raise an approval
card, because that turns the card into a runtime privilege-escalation
mechanism — a malformed or compromised projection could keep asking for new
powers until something says yes. Changing capability means changing the manifest
and re-reviewing the instrument. An undeclared action is an error, not a request.

**Risk is classified by the host executor, not the manifest.** A manifest
claiming `risk: harmless` is worth nothing. `file.open` has bounded, known
semantics. An action backed by an arbitrary shell template does not, and
defaults to per-invocation approval with the resolved command shown.

> A named host action and a named shell recipe are not the same security object.

Pin-time trust is sufficient only for real host verbs. Shell recipes keep asking.

## State

- **Private by default.** An instrument's own directory is namespaced and no
  other instrument may read it.
- **User-authored files stay shared.** Notes, wiki, and everything under `~/bob`
  a human wrote remain readable.
- **Publishing is deferred.** Cross-instrument data must eventually be a declared
  `publishes`, never a private path someone learned the shape of — but do not
  build it until a second consumer actually exists.

This corrects the first doc's proudest and worst claim. "Every instrument reads
the same `~/bob`" is shared *access*, not composition. One instrument writes
`state/deploys.json`, three others learn its undocumented shape, and that is
global mutable state with filesystem latency. It feels wonderfully composable
for six months and is mysteriously coupled afterwards.

When publishing does arrive: named **scalar** facts — boolean, number, string,
enum, timestamp — one writer each, many readers. No arbitrary JSON documents,
and no registry: bob builds the catalogue by scanning manifests.

## Lifecycle: creation is free, permanence is earned

Near-zero authoring cost makes the permanent collection **worse**, not better,
unless something forces curation. AI removes implementation cost. It does not
remove attention cost, choice cost, visual clutter, or the cost of remembering
why a thing exists.

So: a generated instrument starts as **scratch**. Immediately usable, no
ceremony. Permanence requires evidence.

> **Time schedules the review. Human judgment performs the eviction.**

After N active days bob asks: keep it here · revise it · remove it from this
surface · archive it. Ignore the review and it loses its **scarce placement** —
the notch, the stage — while its folder survives untouched.

**Expiration removes privilege, not work.**

Usage counts are shown as evidence for that judgment, never as an automatic
score: days rendered, state changes observed, detail opens, actions taken,
errors. A green deploy dot may have zero interactions in a year and be worth
keeping. Clicks would punish exactly the ambient instruments that succeed.

Pinned is not immortal either. A periodic re-acknowledgement of scarce placement
is the anti-graveyard mechanism — not a clever engagement formula.

## Performance budget

bob went from 26% idle CPU to 0.2% and has held it through a month of features.
This is the classic way to give that back.

1. Zero instruments installed must not move any existing bench window.
2. Installed-but-hidden must cost nothing measurable: no timer, no webview, no
   watcher beyond the one directory scan.
3. A new bench case — several instruments visible and refreshing — against the
   same idle / stream / idle-with-transcript windows.

If a webview per visible projection exceeds the budget, the answer is fewer
visible projections, not a looser budget.

## What v1 deliberately cannot do

- No cross-instrument reads, and no `publishes` until a second consumer exists.
- No direct instrument-to-instrument messaging.
- No background work: hidden means stopped.
- No undeclared actions, ever — not even with approval.
- No compatibility promise. The format will change and bob will migrate the
  folders.
- No publishing, discovery, or install flow.

## The first instrument: a live work map

There is a trap in picking the first one. Everything that best fits the criteria
above — real moment, differential salience — is something bob **already does
natively and better**: the usage strip, the `AttentionCenter` digest, the file
tree. Rebuilding those as instruments proves a mechanism by making the product
worse. Meanwhile everything genuinely absent — deploy status, revenue, channel
analytics — needs credentials and has no existing moment in bob, which is the
profile that becomes wallpaper.

The way out is a third category: **a derived lens over bob's own event stream.**
Those events are rendered linearly today and never synthesised into an
interpretation.

> **What is the agent touching, and where is this turn concentrated in the
> codebase?**

Plausibly the isometric diagram that started this conversation, fed by live
session events. Nodes illuminate as files are edited. Commands animate where
they ran. Failures stay marked. Turn completion freezes the footprint. Pan,
zoom, hover and filter are internal; clicking a file is `file.open`; clicking a
session marker is `session.focus`.

It is not a weaker rewrite of existing UI, and not an external dashboard:

- the **file tree** answers *what files exist?*
- the **activity rail** answers *what happened, in order?*
- the **work map** answers *what shape did this work take?*

And it exercises nearly every seam at once — an existing bob moment, arbitrary
custom rendering, high-frequency internal interaction, structured event
delivery, host navigation actions, private layout state, an invoked stage
projection — with no credentials and no third-party service.

Its ambient projection is **not** in v1. First prove the stage view earns
repeated use. If a stable summary emerges that deserves peripheral attention,
that summary can contribute to a glance later.

## Open questions

1. **How are events delivered to a projection?** A push per event is simple and
   chatty; a coalesced snapshot is cheaper and loses ordering. The transcript
   work says coalesce, but a work map may care about sequence.
2. **How many native primitives, exactly?** "Value, status, list, action" is the
   sketch. The real number should come from the second and third instrument, not
   from this document.
3. **What is N in "after N active days, review"?** Seven is a guess.
4. **Where do instruments live** — `~/bob/instruments/`?

## Risks

- **The API gets designed against imagined instruments.** Mitigation is the
  sequencing: one instrument, built for its own sake, before any second slot.
- **The perf win gets spent.** Mitigation is the gates, with a control run on
  the branch's own base.
- **The escape hatch becomes the default** and bob erodes into a webview host
  one projection at a time. Mitigation is the grammar line: bob keeps 100% of
  the outer grammar regardless of who draws the picture.
- **It never gets used.** The real failure mode. If the only instruments that
  exist are the ones written to test the system, that is the answer, and deleting
  it beats feeding it.

## Where this came from

Three rounds of argument with codex, which disagreed with the first doc on the
unit, on shared state, and on rendering, and was right on all three. It also
supplied two things neither doc had: that a successful extension needs a
*moment* rather than a surface, and that time should schedule a review while
judgment performs the eviction.

It conceded in return that a host-renders-everything position simply relocates
the ceiling, which is what produced the 100%/20–40% split; that a published-fact
registry is premature before a second consumer; and that interaction internal to
a projection must stay unpoliced or the diagram that prompted all of this becomes
impossible.
