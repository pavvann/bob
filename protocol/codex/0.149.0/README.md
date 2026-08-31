# codex app-server protocol — 0.149.0

The JSON Schema for every message `codex app-server` can send or receive, as
emitted by the CLI itself. This is the source of truth for the codex side of
bob's session layer: bob decodes these methods, and the union of them is far too
large and too fast-moving to hand-maintain from prose docs.

## what is here

`json-schema/` — 291 files, generated verbatim, ~3.7MB of text. Nothing pruned.

- `ClientRequest.json` — the tagged union of all **95** client methods
- `ServerNotification.json` — all **75** server notifications
- `ServerRequest.json` — all **10** server-initiated requests (approvals,
  questions, elicitations); these are the ones that need an answer
- `ClientNotification.json` — the one client notification, `initialized`
- `JSONRPC*.json` — the envelope
- one file per params/response type, `v1/` and `v2/` for the versioned ones
- `codex_app_server_protocol.schemas.json` and `.v2.schemas.json` — everything
  in one bundle each

Each per-type file inlines its whole transitive definition closure, which is why
they are big. `jq '.properties'` on one gets you the top level.

## how it was generated

```
codex app-server generate-json-schema --out protocol/codex/0.149.0/json-schema
```

Recorded `codex --version` at the time: `codex-cli 0.149.0`.

`--out` is required and the directory must be writable. There is also
`codex app-server generate-ts --out DIR`, which emits one small TypeScript type
per protocol type with the doc comments attached — much nicer to read than the
schema when you are writing a decoder by hand. It is **not committed**: 663
files and 2.7MB that no Swift build consumes, derived from this same schema.
Generate it into a temp dir when you want that view.

## why it is pinned

Version skew is the real hazard. The protocol is experimental and moves with the
CLI: methods get added, `stage: removed` features disappear, field names change.
If bob's decoding drifts from the CLI actually installed, the failure is a
silently dropped notification, not a crash — the worst kind. A pinned copy means
a diff answers "what moved?" in one command.

Two things this fixture already caught that prose would not have:

- `sandboxPolicy` is a union tagged on `type`, not a `mode` string
- paginated list responses (`model/list`, `thread/list`, `experimentalFeature/list`,
  `thread/loaded/list`) return `{data: [...], nextCursor}` — not `{models: ...}`

## adding a new version

1. `codex --version`
2. `codex app-server generate-json-schema --out protocol/codex/<version>/json-schema`
3. copy this README, update the version, the counts and the recorded version line
4. `diff -rq protocol/codex/<old>/json-schema protocol/codex/<version>/json-schema`
   and read the changed unions first — `ClientRequest`, `ServerNotification`,
   `ServerRequest`
5. re-run `tools/codex-probe/probe.py` against the new CLI and diff its summary
   table; the schema tells you what exists, the probe tells you what actually
   happens

Old versions stay: they are what a user on an older CLI is really talking to.
