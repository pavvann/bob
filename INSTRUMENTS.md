# bob — instruments

How bob grows new capability without rebuilding the app.

Status: **design, not built.** Third version. The first two were argued from
first principles and were wrong in ways that research settled immediately, so
this one leads with how the working systems actually do it.

## What the working systems do

| | runtime | who fetches | who draws | wire | isolation |
|---|---|---|---|---|---|
| **Raycast** | Node child process, one worker thread per extension | the extension | **the host** — React → JSON render tree → JSON Patch → native AppKit | JSON-RPC over stdio | v8 isolate + memory cap |
| **VS Code** | Node extension host process | the extension | the host (tree views, panels); webviews are the exception | IPC | separate process |
| **Shopify** | your own server | the app | **the host** — Polaris web components at declared targets | App Bridge | iframe |
| **MCP** | any language, own process | the server | n/a — the consumer is a model | JSON-RPC over stdio or HTTP | process boundary |

Three things are common to all of them, and the first two are the opposite of
what this document said in its first two versions:

1. **The extension gets a real runtime and does its own I/O.** Node, or your own
   server. It holds its own credentials and makes its own network calls. Nobody
   makes the host fetch on the extension's behalf.
2. **The extension does not draw pixels.** It declares UI in the host's own
   components and the host renders natively. This is why every Raycast extension
   looks like Raycast and every Shopify extension looks like Shopify.
3. **A fixed message vocabulary over JSON-RPC.** Raycast is explicit: extensions
   may send only registered messages, and *"arbitrary calling into Raycast code
   isn't possible."*

Also worth noting: **Raycast deliberately does not sandbox.** No file I/O or
network restrictions. Its security model is open source, human review, and a kill
list. For bob — one user, who wrote or asked for every instrument — the
equivalent is that you can read the folder.

The earlier fear that drove the wrong design was CORS. It only applies to
webviews. VS Code's docs say exactly this: a webview must proxy through the
extension host. An extension with a Node runtime has no CORS problem at all,
because it is not a browser.

## The shape for bob

**An instrument is a process.** Any language. It fetches its own data, holds its
own credentials, does the real work.

**The wire is JSON-RPC over stdio — which bob already speaks, twice.**
`CodexServer.swift`, `CodexProtocol.swift` and `StreamPump.swift` are ~1,400
lines of exactly this: process lifecycle, request/response routing,
notifications, crash handling, stdin teardown. It survived 41 defects across 13
review rounds against a real server. A third client on the same plumbing is a
much smaller job than a new runtime.

**Bob draws.** The instrument sends a description of what it wants shown; bob
renders it in SwiftUI. That is what makes an instrument look like bob rather than
like a small website parked in a window.

**A webview is the escape hatch, not the default.** Genuinely visual work — the
isometric codebase diagram, a chart nobody's primitive covers — gets arbitrary
HTML. That path pays the CORS tax and proxies through bob, exactly as VS Code
does. Rare by design.

## The second face: bob as an MCP server

An instrument already holds real data. The sessions running inside bob already
want that data. Right now they cannot reach it, and a Claude session running
inside bob does not know it is inside bob.

So an instrument has two faces on one connection:

- **UI face** — a render tree and user events. Consumer: the owner.
- **MCP face** — tools and resources. Consumer: the model in a session. Optional.

And bob aggregates. **One `bob` MCP server, with the instruments inside it.**

This is the ecosystem's converged pattern, not a guess: an April 2026 survey of
**17** MCP gateways (MetaMCP, agentgateway, mcp-proxy, IBM ContextForge, Kong,
Cloudflare Portals) found they agree on flat aggregation, tool namespacing and a
single endpoint.

Why it matters here: **bob registers with each CLI once, ever.** Adding, pinning
or removing an instrument after that never touches a file the CLIs own — which
is what makes the lifecycle below possible at all.

### The transport question, and why it answers itself

Stdio transport means the *client spawns the server*. Bob cannot be spawned by a
CLI that bob itself launched. So bob serves **streamable HTTP on localhost**, and
the ordering problem disappears: bob is already running, bob spawns the session,
the session connects outward.

Verified on this machine, 2026-09-17:

```
claude mcp add --transport http bob http://127.0.0.1:PORT -H "Authorization: Bearer …"
codex  mcp add bob --url http://127.0.0.1:PORT --bearer-token-env-var BOB_MCP_TOKEN
```

Both CLIs take a streamable-HTTP MCP server, and both take a bearer token. The
codex config already holds one HTTP MCP server, so this path is live rather than
theoretical.

Bob has no HTTP server today. `Network.framework`'s `NWListener` ships with macOS
and needs no dependency, which matters for an app with one SPM dependency it
thought hard about.

### What bob itself should expose

The instruments are not the whole prize. Bob knows things no MCP server knows:
what is in the other tab, what the last turn in the codex session did, what the
wiki says about a project, what is on the stage.

A session that can ask bob about bob is a bigger idea than the extension system,
and it arrives on the same plumbing.

## The trap: this is issue #31 again

Twelve instruments, four tools each, is **48 tool definitions in every session's
context on every turn**.

That fight already happened here. #31: the companion carried ~94 skills, 9 MCP
servers and 89 tools — **53.6k tokens, 27% of the window, before a word was
typed.** An aggregator that exposes everything recreates it exactly, except
self-inflicted.

The protocol anticipates this. Servers declare `tools: { listChanged: true }`,
clients subscribe through `subscriptions/listen`, and the server emits
`notifications/tools/list_changed` when the set changes — so bob can show a
session only what is relevant and change its mind without a restart. The MCP docs
explicitly recommend **progressive tool discovery** for clients federating many
servers.

The same survey found **per-client tool visibility is an open design space** —
none of the 17 gateways does it well as of Q1 2026. Bob is unusually placed to,
because it is the only one that knows which project a session is sitting in. That
is an edge and a warning in one sentence.

## What survives from the earlier versions

Three ideas came out of the argument with codex and are unaffected by the
research:

**An instrument is a question, not a place.** "Deploy status" is not five
extensions; it is one capability contributing an ambient indicator, a panel, a
command, a notification and a fact. Projections are presentation, and
presentation must not define the package boundary.

**A successful instrument needs a moment.** Extensibility creates supply without
recurring demand; a thing exists and nothing brings it back. An *address* ("lives
in the corner") is not a *moment* ("revenue crossed the target"). bob is
unusually well supplied with moments already — file changes, command exits, turn
completion, failures, `SessionWatcher`, `DirWatcher`, `AttentionCenter`.

**Time schedules the review; judgment performs the eviction.** Creation is free,
so permanence has to cost something. A new instrument is on probation; after N
active days bob asks. Ignore the question and it loses its scarce placement — the
corner, the stage — while the folder survives untouched. Expiry removes
privilege, not work. Clicks are the wrong signal because they would punish
exactly the quiet ambient instruments that succeed.

### One open disagreement, flagged rather than resolved

Codex's framework prefers instruments that earn attention through events, and
says plainly that *"a number that updates continuously will probably become
wallpaper."*

The thing that started this was a permanently visible business metric. That is
the case codex calls weak. It conceded the exception — some ambient objects are
valued as motivation or identity, and *"this is personal software; delight
counts"* — but the framework still leans against it.

**This is the owner's call, not the framework's**, and it is recorded here
unresolved: is bob's extension surface for things that alert you, or things you
look at?

## What v1 is

- One instrument, chosen because it is wanted for itself.
- One projection kind.
- Process + JSON-RPC, on the existing plumbing.
- Host-rendered UI. The webview escape hatch exists but is not the first thing
  built.
- No MCP face until the UI face works.
- No cross-instrument reads. No background work when hidden. No compatibility
  promise — bob migrates the folders when the format changes.

## Open questions

1. **What is the first instrument?** Still the most important unanswered
   question, and the one that stops this being architecture for its own sake.
2. **How many host UI primitives, and which?** Raycast's answer is roughly list,
   detail, form, action panel. bob's should come from the second and third
   instrument, not from this document.
3. **Does the MCP face come before or after the UI face?** It may be the more
   valuable half, which is an argument for going first and an argument for going
   second.
4. **Alerting or looking at?** See the flagged disagreement above.

## Verified on this machine, 2026-09-17

Recorded with dates because the last set of protocol facts in this repo went five
releases stale without anyone noticing.

- `claude mcp add --transport http … -H …` — HTTP transport with headers
- `codex mcp add … --url … --bearer-token-env-var …` — streamable HTTP with bearer auth
- codex config already contains an HTTP MCP server, so the shape is proven here
- `codex-cli 0.154.0`, and bob's codex behavioural findings were measured against
  0.149.0 — see `tools/codex-probe/FINDINGS.md`
- MCP protocol version `2026-07-28`; sampling and logging deprecated
- bob imports no HTTP server today; `NWListener` would add none
