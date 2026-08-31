"""minimal newline-delimited JSON-RPC client for `codex app-server`.

stdlib only. two transports: a spawned process over stdio, and a websocket to a
`--listen ws://HOST:PORT` app-server (the socket transports really do speak
websocket, path `/`, so a long-lived server can be attached to and detached
from). responses from the app-server omit the `jsonrpc` member, so nothing here
requires it. every line in and out is recorded verbatim.
"""

import base64
import json
import os
import socket
import struct
import subprocess
import threading
import time


class Recorder:
    """appends every line, in both directions, to all.jsonl and a per-leg file."""

    def __init__(self, out):
        self.out = out
        os.makedirs(out, exist_ok=True)
        self.all = open(os.path.join(out, "all.jsonl"), "w", buffering=1)
        self.leg = None
        self.leg_file = None
        self.counts = {"in": {}, "out": {}}
        self.lock = threading.Lock()

    def start_leg(self, name):
        with self.lock:
            if self.leg_file:
                self.leg_file.close()
            self.leg = name
            self.leg_file = open(os.path.join(self.out, name + ".jsonl"), "w", buffering=1)

    def record(self, direction, who, msg, raw=None):
        line = json.dumps(
            {
                "ts": round(time.time(), 3),
                "dir": direction,
                "who": who,
                "leg": self.leg,
                "msg": msg if msg is not None else raw,
            },
            separators=(",", ":"),
        )
        key = self._key(msg)
        with self.lock:
            self.counts[direction][key] = self.counts[direction].get(key, 0) + 1
            self.all.write(line + "\n")
            if self.leg_file:
                self.leg_file.write(line + "\n")

    @staticmethod
    def _key(msg):
        if not isinstance(msg, dict):
            return "<unparsed>"
        if "method" in msg:
            return msg["method"] + (" (request)" if "id" in msg else " (notification)")
        if "error" in msg:
            return "<error response>"
        return "<response>"

    def close(self):
        with self.lock:
            if self.leg_file:
                self.leg_file.close()
                self.leg_file = None
            self.all.close()


class Stdio:
    """a spawned app-server, talked to over its stdin/stdout."""

    def __init__(self, cmd, env, stderr_path):
        self.proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=open(stderr_path, "wb"), text=True, bufsize=1, env=env,
            start_new_session=True,
        )

    @property
    def pid(self):
        return self.proc.pid

    def lines(self):
        for raw in self.proc.stdout:
            yield raw

    def write(self, line):
        self.proc.stdin.write(line)
        self.proc.stdin.flush()

    def alive(self):
        return self.proc.poll() is None

    @property
    def returncode(self):
        return self.proc.poll()

    def close_stdin(self):
        self.proc.stdin.close()

    def close(self):
        """graceful: close stdin and let the app-server shut itself down."""
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.kill()
        return self.proc.returncode

    def kill(self):
        self.proc.kill()
        self.proc.wait()


class Ws:
    """a websocket client for `codex app-server --listen ws://HOST:PORT`.

    RFC 6455 text frames only, which is all the protocol uses.
    """

    def __init__(self, host, port, timeout=15):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            "GET / HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % (host, port, key)
        ).encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise IOError("websocket upgrade closed")
            buf += chunk
        status = buf.split(b"\r\n", 1)[0].decode(errors="replace")
        if "101" not in status:
            raise IOError("websocket upgrade refused: %s" % status)
        self.rest = buf.split(b"\r\n\r\n", 1)[1]
        self.open = True
        self.pid = None

    def _read(self, n):
        while len(self.rest) < n:
            chunk = self.sock.recv(max(4096, n - len(self.rest)))
            if not chunk:
                raise EOFError
            self.rest += chunk
        out, self.rest = self.rest[:n], self.rest[n:]
        return out

    def lines(self):
        while True:
            try:
                b1, b2 = self._read(2)
                n = b2 & 0x7F
                if n == 126:
                    n = struct.unpack(">H", self._read(2))[0]
                elif n == 127:
                    n = struct.unpack(">Q", self._read(8))[0]
                payload = self._read(n)
                opcode = b1 & 0x0F
                if opcode == 8:  # close
                    return
                if opcode in (1, 2):
                    yield payload.decode(errors="replace")
            except (EOFError, OSError):
                return

    def write(self, line):
        payload = line.encode()
        mask = os.urandom(4)
        n = len(payload)
        head = b"\x81"
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += b"\xfe" + struct.pack(">H", n)
        else:
            head += b"\xff" + struct.pack(">Q", n)
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def alive(self):
        return self.open

    @property
    def returncode(self):
        return None

    def close_stdin(self):
        self.close()

    def close(self):
        self.open = False
        try:
            self.sock.close()
        except Exception:
            pass
        return 0

    def kill(self):
        """drop the connection without a close frame, as a crashed client would."""
        self.open = False
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        self.sock.close()


class AppServer:
    def __init__(self, rec, label="server", extra_args=(), env=None, cmd=None, ws=None):
        self.rec = rec
        self.label = label
        self.inbox = []
        self.cv = threading.Condition()
        self._next_id = 0
        self.stderr_path = os.path.join(rec.out, label + ".stderr.log")
        if ws:
            self.tx = Ws(*ws)
        else:
            self.tx = Stdio(cmd or ["codex", "app-server", *extra_args], env, self.stderr_path)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    # -- plumbing ---------------------------------------------------------

    def _read(self):
        for raw in self.tx.lines():
            raw = raw.strip()
            if not raw:
                continue
            try:
                msg = json.loads(raw)
            except ValueError:
                self.rec.record("in", self.label, None, raw=raw)
                continue
            self.rec.record("in", self.label, msg)
            with self.cv:
                self.inbox.append(msg)
                self.cv.notify_all()
        with self.cv:
            self.inbox.append({"_eof": True})
            self.cv.notify_all()

    def send(self, msg):
        self.rec.record("out", self.label, msg)
        self.tx.write(json.dumps(msg, separators=(",", ":")) + "\n")

    def request(self, method, params=None):
        self._next_id += 1
        self.send({"method": method, "id": self._next_id, "params": params or {}})
        return self._next_id

    def notify(self, method, params=None):
        self.send({"method": method, "params": params or {}})

    def respond(self, req_id, result):
        self.send({"id": req_id, "result": result})

    def respond_error(self, req_id, code, message):
        self.send({"id": req_id, "error": {"code": code, "message": message}})

    # -- waiting ----------------------------------------------------------

    def wait(self, pred, timeout=120, cursor=0):
        """scan inbox from `cursor` for the first msg matching pred.

        returns (next_cursor, msg), or (cursor, None) on timeout / EOF. never
        consumes, so several waiters can read the same stream.
        """
        deadline = time.time() + timeout
        while True:
            with self.cv:
                while cursor < len(self.inbox):
                    msg = self.inbox[cursor]
                    cursor += 1
                    if msg.get("_eof"):
                        return cursor, None
                    if pred(msg):
                        return cursor, msg
                left = deadline - time.time()
                if left <= 0:
                    return cursor, None
                self.cv.wait(min(left, 0.25))

    def call(self, method, params=None, timeout=120):
        msg = self.try_call(method, params, timeout)
        if msg is None:
            raise TimeoutError("no response to %s" % method)
        if "error" in msg:
            raise RuntimeError("%s failed: %s" % (method, json.dumps(msg["error"])))
        return msg.get("result", {})

    def try_call(self, method, params=None, timeout=120):
        """like call, but returns the raw response instead of raising."""
        rid = self.request(method, params)
        _, msg = self.wait(lambda m: m.get("id") == rid and "method" not in m, timeout)
        return msg

    def handshake(self, name="bob-probe", version="0.0.1"):
        res = self.call(
            "initialize",
            {"clientInfo": {"name": name, "title": "bob", "version": version}},
        )
        self.notify("initialized", {})
        return res

    # -- lifetime ---------------------------------------------------------

    @property
    def pid(self):
        return self.tx.pid

    @property
    def returncode(self):
        return self.tx.returncode

    def alive(self):
        return self.tx.alive()

    def close_stdin(self):
        self.tx.close_stdin()

    def close(self):
        return self.tx.close()

    def kill(self):
        self.tx.kill()


def notif(method):
    return lambda m: m.get("method") == method and "id" not in m


def server_request(*methods):
    return lambda m: m.get("method") in methods and "id" in m


def summary(rec):
    """method -> count table, both directions."""
    lines = []
    for direction, title in (("out", "client -> server"), ("in", "server -> client")):
        rows = sorted(rec.counts[direction].items(), key=lambda kv: (-kv[1], kv[0]))
        lines.append("  %s" % title)
        for method, n in rows:
            lines.append("    %5d  %s" % (n, method))
    return "\n".join(lines)
