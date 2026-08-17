#!/usr/bin/env python3
"""Deterministic stand-in for the claude CLI, speaking bob's stream-json wire.

Answers every control_request with success, emits system/init, then streams
three identical spontaneous markdown replies on a fixed schedule: the first
starts 75s after the initialize handshake, 5s gap between replies. Each reply
is ~16KB streamed as ~25-char text_deltas at 40 events/sec (~16.5s per reply,
~58s total), so bench/run.sh gets a stream window full of render pressure.
Fixed content, fixed pacing, no randomness. Stays alive after the third reply,
still answering control_requests, until stdin closes.

Wire shapes follow Sources/Bob/StreamJSON.swift and ClaudeSession.swift.
"""
import json
import sys
import threading
import time

DELTA_CHARS = 25
EVENTS_PER_SEC = 40
FIRST_REPLY_AT = 75.0
GAP = 5.0
REPLY_MIN_CHARS = 16000

SECTION = """## Section {n} — render pressure

Markdown the transcript has to lay out while deltas keep landing:
headings, bullets, a table, and fenced code, all in one message.

- every delta is a main-actor hop
- the in-flight message re-parses as it grows
- the table below re-measures on each pass

| stage | events | chars | notes |
|---|---|---|---|
| warmup | 40 | 1000 | first second of the stream |
| steady | 400 | 10000 | mid-reply, parse cost climbing |
| tail | 660 | 16500 | the last delta re-parses all of this |

```swift
struct BenchRow: Identifiable {
    let id = UUID()
    let stage: String
    let events: Int

    var label: String { "\\(stage): \\(events) events" }
}
```

A plain paragraph between sections so the layout alternates block
kinds instead of hammering one path.

"""


def build_reply():
    text = "# fake-claude bench reply\n\n"
    n = 1
    while len(text) < REPLY_MIN_CHARS:
        text += SECTION.replace("{n}", str(n))
        n += 1
    return text


write_lock = threading.Lock()
handshake = threading.Event()


def emit(obj):
    with write_lock:
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def session_id():
    args = sys.argv[1:]
    for flag in ("--session-id", "--resume"):
        if flag in args:
            i = args.index(flag)
            if i + 1 < len(args):
                return args[i + 1]
    return "fake-claude-bench"


SESSION_ID = session_id()


def init_line():
    return {"type": "system", "subtype": "init",
            "session_id": SESSION_ID, "model": "fake-claude"}


def stream_event(event):
    return {"type": "stream_event", "event": event, "session_id": SESSION_ID}


def stream_reply(text):
    emit(init_line())
    emit(stream_event({"type": "message_start",
                       "message": {"id": "msg_bench", "role": "assistant", "content": []}}))
    emit(stream_event({"type": "content_block_start", "index": 0,
                       "content_block": {"type": "text", "text": ""}}))
    chunks = [text[i:i + DELTA_CHARS] for i in range(0, len(text), DELTA_CHARS)]
    start = time.monotonic()
    for i, chunk in enumerate(chunks):
        delay = start + i / EVENTS_PER_SEC - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        emit(stream_event({"type": "content_block_delta", "index": 0,
                           "delta": {"type": "text_delta", "text": chunk}}))
    emit(stream_event({"type": "content_block_stop", "index": 0}))
    emit(stream_event({"type": "message_delta", "delta": {"stop_reason": "end_turn"}}))
    emit(stream_event({"type": "message_stop"}))
    emit({"type": "assistant",
          "message": {"role": "assistant", "content": [{"type": "text", "text": text}]},
          "session_id": SESSION_ID})
    emit({"type": "result", "subtype": "success", "is_error": False, "result": text,
          "num_turns": 1, "duration_ms": int(len(chunks) / EVENTS_PER_SEC * 1000),
          "total_cost_usd": 0.0, "session_id": SESSION_ID})


def schedule():
    handshake.wait()
    emit(init_line())
    reply = build_reply()
    time.sleep(FIRST_REPLY_AT)
    stream_reply(reply)
    time.sleep(GAP)
    stream_reply(reply)
    time.sleep(GAP)
    stream_reply(reply)


threading.Thread(target=schedule, daemon=True).start()

for line in sys.stdin:
    try:
        obj = json.loads(line)
    except ValueError:
        continue
    if obj.get("type") != "control_request":
        continue
    emit({"type": "control_response",
          "response": {"subtype": "success",
                       "request_id": obj.get("request_id"), "response": {}}})
    if (obj.get("request") or {}).get("subtype") == "initialize":
        handshake.set()
