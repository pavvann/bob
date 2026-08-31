# codex app-server: what the schema does not tell you

Measured against `codex-cli 0.149.0` on macOS (arm64), driving real app-servers
against the real `~/.codex` home. Every claim below came out of a capture made by
the two scripts beside this file; probe threads were named `bob protocol probe`
and deleted afterwards.

The schema is pinned in `protocol/codex/0.149.0/`. This file covers the
behaviours the schema cannot express.

## the tools

```
# the seven protocol legs, as JSONL, one thread, archived at the end
python3 tools/codex-probe/probe.py --out DIR [--delete] [--legs approval,steer]

# one subcommand per open question
python3 tools/codex-probe/questions.py pending-approval --wait 300 --delete
python3 tools/codex-probe/questions.py double-turn --delete
python3 tools/codex-probe/questions.py concurrency --rounds 2,4,8 --delete
python3 tools/codex-probe/questions.py child-survival --delete
python3 tools/codex-probe/questions.py daemon-proxy --delete
```

python3, stdlib only. `--out` defaults to a fresh temp dir, never the repo. Both
scripts print a method-to-count table at the end; diff that table after a CLI
upgrade. `samples.jsonl` holds eleven representative lines with filesystem paths
redacted and account usage zeroed; full captures stay out of the repo.

## the table

| question | answer | consequence for bob |
| --- | --- | --- |
| does an unanswered approval time out? | no. 300s, zero further traffic | bob owns the timeout, or there isn't one |
| pending approval, client closes stdin? | app-server exits 0 in ~9s, turn recorded `interrupted` | crash-safe; nothing to reconcile |
| second `turn/start` on a busy thread? | neither rejected nor queued: merged into the **running** turn | never assume a new turn id |
| concurrency in one app-server | 8 threads interleave, flat RSS, no extra children | one app-server for all codex tabs |
| children survive `turn/interrupt`? | **yes**. only app-server exit reaps them | interrupt is not a kill switch |
| can a thread outlive its client? | yes, if the app-server does, over `--listen ws://` | phase 3 hosts the server, not the daemon |

## 1. an unanswered approval blocks forever

**Did.** `turn/start` with `approvalPolicy: "untrusted"` and the prompt "run the
shell command `date +%s`". The server asked for approval. Nothing was answered
for 300 seconds.

**Observed.** One notification when the approval opened, then silence:

```json
{"method":"thread/status/changed","params":{"threadId":"...","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}
```

No `turn/completed`, no error, no retry, for the full five minutes. The approval
request params carry no deadline field either.

**Consequence.** Bob owns the deadline. A codex tab can sit in
`waitingOnApproval` indefinitely, so the approval card must be persistent and
visible from the tab chip: a missed card is a permanently stuck session, not a
slow one. `activeFlags: ["waitingOnApproval"]` is the flag to drive that from,
and it comes back through `thread/status/changed` on the resume path too.

One asymmetry worth keeping: `ToolRequestUserInputParams` has a nullable
`autoResolutionMs`, so a *question* may name its own auto-resolve deadline (it
was `null` in the one observed). Approval params have no equivalent. Do not
generalise the two.

## 2. closing stdin with an approval pending is clean

**Did.** Same thread, approval still outstanding, closed the client's stdin,
waited for the process, reconnected with a fresh app-server and read the thread
back.

**Observed.**

```
app-server exit=0 after 9.3s
surviving descendants: []
thread/read status={"type": "notLoaded"}
  turn 01a044b2-5898-...-20427dc7f557 status=interrupted items=2 error=null
thread/list row: {"status": {"type": "notLoaded"}, "preview": "run the shell command ..."}
```

**Consequence.** Three things.

- No orphaned approval, no stuck turn: the rollout records the turn as
  `interrupted`, so a crashed bob leaves a resumable thread, not a corrupt one.
- Shutdown takes up to ~10 seconds. Bob must not treat a not-yet-exited
  app-server as hung before then, and must not block its own quit on it.
- `thread.status` is a **runtime** property. A thread nobody has loaded reports
  `{"type":"notLoaded"}`, not `idle`. The resume picker must render that as "not
  running", and must never read `notLoaded` as an error.

## 3. a second `turn/start` is silently merged into the running turn

**Did.** Started a long turn, then immediately sent a second `turn/start` on the
same thread with a different message.

**Observed.** The second call succeeded and returned the *first* turn:

```json
{"id":5,"result":{"turn":{"id":"01a044aa-7ab2-7910-b4e1-b0b0bb768f55","items":[],"itemsView":"notLoaded","status":"inProgress","error":null,"startedAt":null,"completedAt":null,"durationMs":null}}}
```

`01a044aa-7ab2-...` is the id the *first* `turn/start` returned. Afterwards
`thread/read` showed **one** turn holding both user messages and both answers,
in order: `userMessage` (long prompt), `agentMessage`, `userMessage` ("reply with
only: pong"), `agentMessage` ("pong"). No `thread/queue/changed`, no second
`turn/started`.

**Consequence.** `turn/start` on a busy thread behaves as an implicit
`turn/steer`. Bob must not key anything off "the turn id I just got back": it may
be a turn already in flight. Either gate sends on the thread being idle and route
mid-turn input through `turn/steer` explicitly (which takes `expectedTurnId`, so
it fails loudly instead of silently merging), or accept the merge and treat
`turn.id` from the response as advisory. The explicit path is better: a steer
against a stale `expectedTurnId` is a real error bob can show.

## 4. concurrency is a non-issue at bob's scale

**Did.** One app-server, a pool of eight threads, then rounds of 2, 4 and 8
simultaneous trivial turns ("reply with only: pong"), sampling RSS and the
descendant process count every 500ms.

**Observed.**

```
baseline           rss=33648kB children=1
round n=2: wall=3.6s completed=2/2 peak_rss=33664kB peak_children=1   per-thread [2.26, 3.56]
round n=4: wall=3.0s completed=4/4 peak_rss=32640kB peak_children=1   per-thread [2.17, 2.38, 2.53, 3.05]
round n=8: wall=4.6s completed=8/8 peak_rss=32768kB peak_children=1   per-thread [2.61 ... 4.63]
```

Every round: all n threads had produced events before the first turn completed,
so they genuinely interleave rather than serialise. Wall clock barely moved from
2 to 8. RSS did not grow. The one child process is the npm wrapper's real binary,
and its count never changed with thread count.

**Consequence.** One app-server for every codex tab in a bob window is right. No
per-thread process budget, and no need to tear down idle threads for memory.

**Caveat, stated plainly.** Each thread starts its own MCP servers: 8 threads
produced 8 `mcpServer/startupStatus/updated` `starting`-then-`ready` pairs for
`codex_apps`. That one is in-process, so it cost no subprocess. This machine's
global config declares no external MCP servers, so the per-thread-per-server
subprocess cost of a real stdio MCP server was **not measured**. Assume a user
with N stdio MCP servers and T codex tabs pays N x T processes. What would settle
it: add one trivial stdio MCP server to the global config and re-run
`concurrency`. If it bites, the lever is the per-session `-c` override at
`thread/start`, the same lever issue #35 already names.

## 5. `turn/interrupt` does not kill the child process

**Did.** Ran `sleep 3119` in a turn (a duration nothing else on the machine would
be sleeping for), interrupted the turn mid-command, then looked at the process
table: before, after, and again after the app-server exited.

**Observed.**

```
before interrupt: 30971 sleep 3119        app-server descendants: [30422, 30968, 30971]
turn/interrupt -> {"id": 5, "result": {}}
turn/completed status=interrupted
after interrupt:  30971 sleep 3119        <-- still alive
after the app-server exits: (none)
```

The item was reported as failed while the process kept running:

```json
{"method":"item/completed","params":{"item":{"type":"commandExecution","command":"/bin/zsh -lc 'sleep 3119'","status":"failed","exitCode":-1}}}
```

**Consequence.** Interrupt is a *logical* cancel: the turn stops, the item is
marked `failed` with `exitCode: -1`, and the OS process is abandoned. Only
app-server exit reaps it. So bob's stop button cannot promise the command
stopped, and bob's quit path must actually terminate its app-servers: leaking one
leaks every command it ever abandoned. And because the npm-installed `codex` is a
node wrapper around the real binary, terminating the wrapper alone is not enough;
signal the process group (`questions.py` does this in `kill_host`).

**Also observed, and it matters more than it looks:** `turn/completed` arrived
**before** the `item/completed` for the interrupted command. `turn/completed` is
authoritative for the turn's *status*, but it is not the last message of a turn.
Bob must not tear down per-turn routing state on `turn/completed`, or it will
drop the trailing item updates.

## 6. a thread can outlive its client, but not via the daemon

**Did.** Three routes, in order.

1. `codex app-server daemon start`
2. our own `codex app-server --listen unix://SOCK` plus `codex app-server proxy --sock SOCK`
3. our own `codex app-server --listen ws://127.0.0.1:PORT`, attached to directly

**Observed: route 1 is unavailable.**

```
Error: managed standalone Codex install not found at ~/.codex/packages/standalone/current/codex
This command requires the standalone install managed by the Codex installer,
because the daemon starts and updates app-server from that fixed path.
```

The daemon only works for a codex installed by the official installer. An
npm-installed codex, the common case and this machine's, cannot start it at all.
Installing the standalone build to get a daemon is a change to the user's codex,
not something bob can do quietly.

**Observed: route 2 is broken in 0.149.0.** The socket comes up, `proxy`
connects, and `initialize` never gets an answer. With `RUST_LOG` on the host:

```
codex_app_server_transport::transport::unix_socket: app-server control socket listening
codex_app_server_transport::transport::unix_socket: failed to upgrade control socket
  websocket connection: WebSocket protocol error: httparse error: invalid token
```

So the socket transports speak **websocket**, and `app-server proxy --sock`
cannot complete the upgrade against a plain `--listen unix://` server. Reproduce
with `questions.py daemon-proxy --transport unix`. (Two smaller traps on the way
there: the socket path must be under 104 bytes, and its parent must not be a
symlink, which rules out `/tmp` on macOS.)

**Observed: route 3 works.** `--listen ws://127.0.0.1:PORT` accepts an ordinary
RFC 6455 client at path `/` (the probe carries its own ~50-line client). A turn
started by one client, which was then killed mid-stream, ran to completion with
nothing attached:

```
turn 01a044c5-b711-... started; waiting for the first delta, then dropping the client
client dropped; waiting 20s with nothing attached
host still alive=True
thread/loaded/list after reconnect: {"data":["01a044c5-a203-..."],"nextCursor":null}
thread/read status={"type": "idle"}
  turn 01a044c5-b711-... status=completed items=2 agentMessage=2076 chars
```

2076 characters of answer were produced while no client existed, and the thread
was still loaded in the server on reconnect.

**Consequence for phase 3.** The mechanism is real, but it is *not* the `daemon`
plus `proxy` pair: plan against that and it will not exist on most machines. What
holds work alive is simply an app-server that outlives its client, and bob can
have that today.

- codex-minions = a long-lived `codex app-server --listen ws://127.0.0.1:<port>`
  that bob starts, attaches to, detaches from and re-attaches to. Bob needs a
  websocket client for it (`URLSessionWebSocketTask` covers this) and has to own
  the port, the lifetime and the reaping. See finding 5.
- `thread/loaded/list` is the "what is still running" query; it returns
  `{data: [threadId...], nextCursor}`.
- Do not build phase 3 on `app-server daemon`, and do not ask the user to
  reinstall codex to get it. Revisit only if a later CLI drops the
  managed-install requirement and fixes the unix-socket upgrade.

Untested, and worth knowing before phase 3 ships: whether a detached client
misses events permanently (the reconnect saw final state via `thread/read`, not a
replay), and whether an approval raised while nothing is attached blocks the
thread the way finding 1 says it does. What would settle it: a turn that needs an
approval, started, then detached from before answering.

## smaller things, learned the same way

- **Server request ids live in their own namespace.** The first server-initiated
  request arrived as `"id": 0` while the client was also using small integers.
  Pending server requests must be tracked separately from bob's own outgoing ids,
  or the two collide.
- **`serverRequest/resolved`** fires after an approval or question is answered,
  carrying `{threadId, requestId}`. Use it to dismiss a card, including one
  answered by another client.
- **Provoking a question needs a feature flag.** `item/tool/requestUserInput` only
  appears with `--enable default_mode_request_user_input` (stage
  `underDevelopment`, off by default). Enabling it also emits a `warning`
  notification about under-development features. Bob should decode the request
  regardless, since it can arrive whenever the config enables it, but should not
  count on it.
- **Approval requests carry `availableDecisions`**, e.g.
  `["accept", {"acceptWithExecpolicyAmendment": {...}}, "cancel"]`. Render the
  buttons from that array rather than hardcoding a decision set; `decline` and
  `acceptForSession` exist in the schema but were not offered here.
- **`turn/steer` returns the same `turnId`** it was given, and requires
  `expectedTurnId`. A steered turn still completes with `status: "completed"`.
- **Paginated responses are `{data, nextCursor}`.** True for `model/list`,
  `thread/list`, `thread/loaded/list` and `experimentalFeature/list`.
  `thread/list` takes `limit`, not `pageSize`.
- **Errors come back without `jsonrpc`, like everything else:**
  `{"error":{"code":-32600,"message":"no rollout found for thread id ..."},"id":4}`
  from deleting an already-deleted thread.
- **`item/tool/requestUserInput` has no item.** No `item/started` or
  `item/completed` accompanies it; the only handle is the `itemId` in the request
  params. The question card cannot be built from the item stream.
- **`initialize` reports back `codexHome`**, a cheap assertion that bob is talking
  to the global `~/.codex` and not something else.
