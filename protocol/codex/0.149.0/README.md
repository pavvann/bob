# codex app-server protocol — 0.149.0

The JSON Schema for every message `codex app-server` can send or receive, as
emitted by the CLI itself. This is the source of truth for the codex side of
bob's session layer: bob decodes these methods, and the union of them is far too
large and too fast-moving to hand-maintain from prose docs.

## what is here

Nothing but this file. The 291 generated schema files it describes were removed
once the decoder was written and verified against a live server — they were
reference material, and the reference has been read.

They are not lost. They landed whole in `372c0c9` and are in git history
permanently:

```
git show 372c0c9:protocol/codex/0.149.0/json-schema/ClientRequest.json
git checkout 372c0c9 -- protocol/codex/0.149.0/json-schema   # all 291 back
```

What they contained, for the record: `ClientRequest.json` (the tagged union of
all **95** client methods), `ServerNotification.json` (**75** notifications),
`ServerRequest.json` (**10** server-initiated requests — approvals, questions,
elicitations), `ClientNotification.json` (just `initialized`), the `JSONRPC*`
envelope, one file per params/response type with `v1/` and `v2/` variants, and
two all-in-one bundles. ~3.7MB, nothing pruned, each per-type file inlining its
whole transitive definition closure.

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

## why it was pinned, and why the files are gone

Version skew is the real hazard. The protocol is experimental and moves with the
CLI: methods get added, `stage: removed` features disappear, field names change.
When bob's decoding drifts from the CLI actually installed, the failure is a
silently dropped notification rather than a crash — the worst kind.

The fixture earned its keep. Two things it caught that prose docs would not have:

- `sandboxPolicy` is a union tagged on `type`, not a `mode` string
- paginated list responses (`model/list`, `thread/list`,
  `experimentalFeature/list`, `thread/loaded/list`) return `{data: [...],
  nextCursor}` — not `{models: ...}`

Both of those now live where they matter, in `CodexProtocol.swift` and
`tools/codex-probe/FINDINGS.md`. That is the argument for deleting the files:
the value was in the reading, the reading is done, and 292 machine-generated
files that no build consumes are noise in every clone, every worktree, every
grep and every file tree — bob's own included.

The diff-what-moved case survives intact, because answering it always required
generating the *new* schema anyway, and the old one is one `git show` away.

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

Generate into a temp dir and diff there. Committing a version is only worth it
while a decoder is being written against it — after that, git history is the
archive.
