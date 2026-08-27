#!/usr/bin/env python3
"""settle the `codex app-server` behaviours bob cannot guess from the schema.

one subcommand per open question. each drives real app-servers against the real
`~/.codex` home, records every line as JSONL under --out, and prints what it
observed. the prompts are trivial; threads are deleted or archived at the end.

    python3 tools/codex-probe/questions.py pending-approval --wait 300 --delete
    python3 tools/codex-probe/questions.py double-turn --delete
    python3 tools/codex-probe/questions.py concurrency --rounds 2,4,8 --delete
    python3 tools/codex-probe/questions.py child-survival --delete
    python3 tools/codex-probe/questions.py daemon-proxy --delete

`daemon-proxy` starts the machine-wide app-server daemon and stops it again, and
refuses to run if one is already up, since stopping someone else's is not this
script's business. where the managed daemon is not installed it self-hosts an
app-server on a socket instead and says which transport it measured.
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from appserver import AppServer, Recorder, notif, server_request, summary  # noqa: E402

APPROVAL_METHODS = (
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/permissions/requestApproval",
    "execCommandApproval",
)
NAME = "bob protocol probe"
LONG_PROMPT = (
    "write about 300 words on what a terminal emulator does. plain prose, no "
    "lists, no tool calls."
)
PONG = "reply with only: pong"
# a duration no other process on the machine is plausibly sleeping for, so the
# child-survival check can find (and later kill) exactly what codex started.
MARKER_SLEEP = "3119"


def log(*a):
    print(*a, flush=True)


def rss_kb(pid):
    try:
        return int(subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                                  capture_output=True, text=True).stdout.strip() or 0)
    except Exception:
        return -1


def descendants(pid):
    """pids under `pid`, recursively."""
    out, frontier = [], [pid]
    while frontier:
        p = frontier.pop()
        kids = subprocess.run(["pgrep", "-P", str(p)], capture_output=True, text=True).stdout.split()
        kids = [int(k) for k in kids]
        out += kids
        frontier += kids
    return out


class Sampler(threading.Thread):
    """peak RSS and peak descendant count of a pid while a round runs."""

    def __init__(self, pid, interval=0.5):
        super().__init__(daemon=True)
        self.pid, self.interval, self.stop = pid, interval, threading.Event()
        self.peak_rss, self.peak_kids = 0, 0

    def run(self):
        while not self.stop.is_set():
            self.peak_rss = max(self.peak_rss, rss_kb(self.pid))
            self.peak_kids = max(self.peak_kids, len(descendants(self.pid)))
            self.stop.wait(self.interval)


class Ctx:
    def __init__(self, args, name):
        self.args = args
        self.out = os.path.join(args.out or tempfile.mkdtemp(prefix="codex-probe-"), name)
        self.ws = os.path.join(self.out, "workspace")
        os.makedirs(self.ws, exist_ok=True)
        self.rec = Recorder(self.out)
        self.rec.start_leg(name)
        log("out: %s" % self.out)

    def server(self, label="server", cmd=None, extra_args=(), ws=None):
        return AppServer(self.rec, label=label, cmd=cmd, extra_args=extra_args, ws=ws)

    def new_thread(self, s, name=NAME):
        tid = s.call("thread/start", {"cwd": self.ws})["thread"]["id"]
        s.call("thread/name/set", {"threadId": tid, "name": name})
        return tid

    def cleanup(self, s, *thread_ids):
        if self.args.keep:
            log("kept: %s" % ", ".join(thread_ids))
            return
        method = "thread/delete" if self.args.delete else "thread/archive"
        for tid in thread_ids:
            s.try_call(method, {"threadId": tid}, timeout=30)
        log("%s: %s" % (method, ", ".join(thread_ids)))

    def done(self, rec_summary=True):
        if rec_summary:
            log("")
            log(summary(self.rec))
        self.rec.close()


def turn(s, tid, text, **over):
    params = {
        "threadId": tid,
        "input": [{"type": "text", "text": text}],
        "approvalPolicy": "never",
        "sandboxPolicy": {"type": "readOnly"},
    }
    params.update(over)
    return s.call("turn/start", params)["turn"]["id"]


# -- q1 + q2: does a pending approval time out, and what if stdin closes? ----


def cmd_pending_approval(args):
    ctx = Ctx(args, "pending-approval")
    s = ctx.server()
    s.handshake()
    tid = ctx.new_thread(s)
    log("thread %s" % tid)
    cur = 0
    turn_id = turn(s, tid, "run the shell command `date +%s` and reply with only its output",
                   approvalPolicy="untrusted")
    cur, req = s.wait(server_request(*APPROVAL_METHODS), 180, cur)
    if req is None:
        log("! no approval request; cannot run this experiment")
        ctx.cleanup(s, tid)
        return ctx.done()
    t0 = time.time()
    log("approval %s arrived (id=%s). NOT answering; waiting %ss." % (req["method"], req["id"], args.wait))

    # phase 1: sit on it and see whether the server gives up on its own.
    deadline = time.time() + args.wait
    while time.time() < deadline:
        cur, msg = s.wait(lambda m: True, min(30, max(1, deadline - time.time())), cur)
        if msg is None:
            continue
        log("  +%5.1fs  %s" % (time.time() - t0, msg.get("method") or json.dumps(msg)[:120]))
        if msg.get("method") == "turn/completed":
            log("  -> the server ended the turn on its own after %.1fs" % (time.time() - t0))
            break
    else:
        log("  -> nothing after %.1fs: the approval blocks, it does not expire" % (time.time() - t0))

    # phase 2: close stdin with the approval still pending.
    log("closing stdin with the approval still pending")
    s.close_stdin()
    t1 = time.time()
    for _ in range(80):
        if not s.alive():
            break
        time.sleep(0.25)
    log("  app-server exit=%s after %.1fs" % (s.returncode, time.time() - t1))
    kids = descendants(s.pid) if s.alive() else []
    log("  surviving descendants: %s" % kids)

    # phase 3: reconnect and ask what the thread looks like now.
    s2 = ctx.server(label="server-2")
    s2.handshake()
    read = s2.call("thread/read", {"threadId": tid, "includeTurns": True})
    log("  thread/read status=%s" % json.dumps(read["thread"].get("status")))
    for t in read["thread"].get("turns") or []:
        log("    turn %s status=%s items=%d error=%s" % (
            t.get("id"), t.get("status"), len(t.get("items", [])), json.dumps(t.get("error"))[:120]))
    rows = s2.call("thread/list", {"limit": 5}).get("data", [])
    mine = [r for r in rows if r.get("id") == tid]
    log("  thread/list row: %s" % (json.dumps({k: mine[0].get(k) for k in ("id", "status", "preview", "updatedAt")}) if mine else "not in the first 5"))
    log("  (turn under test was %s)" % turn_id)
    ctx.cleanup(s2, tid)
    s2.close()
    ctx.done()


# -- q3: is a second turn/start rejected or queued? --------------------------


def cmd_double_turn(args):
    ctx = Ctx(args, "double-turn")
    s = ctx.server()
    s.handshake()
    tid = ctx.new_thread(s)
    log("thread %s" % tid)
    first = turn(s, tid, LONG_PROMPT)
    log("first turn %s" % first)
    second = s.try_call("turn/start", {
        "threadId": tid,
        "input": [{"type": "text", "text": PONG}],
        "approvalPolicy": "never",
        "sandboxPolicy": {"type": "readOnly"},
    }, timeout=60)
    log("second turn/start response verbatim:")
    log("  %s" % json.dumps(second))
    cur = 0
    seen = []
    for _ in range(4):
        cur, msg = s.wait(lambda m: m.get("method") in ("turn/started", "turn/completed", "thread/queue/changed"), 300, cur)
        if msg is None:
            break
        p = msg.get("params", {})
        turn_obj = p.get("turn") or {}
        seen.append((msg["method"], turn_obj.get("id") or p.get("turnId"), turn_obj.get("status")))
        log("  %s turn=%s status=%s" % seen[-1])
    read = s.call("thread/read", {"threadId": tid, "includeTurns": True})
    log("thread/read: %d turns" % len(read["thread"].get("turns") or []))
    for t in read["thread"].get("turns") or []:
        log("  turn %s status=%s" % (t.get("id"), t.get("status")))
    ctx.cleanup(s, tid)
    s.close()
    ctx.done()


# -- q4: how many concurrent threads run comfortably? -----------------------


def cmd_concurrency(args):
    ctx = Ctx(args, "concurrency")
    rounds = [int(x) for x in args.rounds.split(",")]
    s = ctx.server()
    s.handshake()
    pool = []
    for i in range(max(rounds)):
        pool.append(ctx.new_thread(s, "%s %d" % (NAME, i + 1)))
    log("pool of %d threads, app-server pid %s" % (len(pool), s.pid))
    log("  baseline rss=%dkB children=%d" % (rss_kb(s.pid), len(descendants(s.pid))))

    for n in rounds:
        threads = pool[:n]
        sampler = Sampler(s.pid)
        sampler.start()
        cur = len(s.inbox)
        t0 = time.time()
        ids = {}
        for tid in threads:
            rid = s.request("turn/start", {
                "threadId": tid,
                "input": [{"type": "text", "text": PONG}],
                "approvalPolicy": "never",
                "sandboxPolicy": {"type": "readOnly"},
            })
            ids[rid] = tid
        finished, order = {}, []
        scan = cur
        while len(finished) < n and time.time() - t0 < 300:
            scan, msg = s.wait(notif("turn/completed"), 300 - (time.time() - t0), scan)
            if msg is None:
                break
            tid = msg["params"]["threadId"]
            finished[tid] = round(time.time() - t0, 2)
        # interleaving: the thread id of every streamed delta, in arrival order
        for m in s.inbox[cur:]:
            if m.get("method") in ("turn/started", "item/agentMessage/delta", "turn/completed"):
                th = m.get("params", {}).get("threadId")
                if th in threads:
                    order.append((threads.index(th), m["method"]))
        sampler.stop.set()
        sampler.join()
        wall = time.time() - t0
        slowest = max(finished.values()) if finished else None
        # interleaving: how many distinct threads had produced events before the
        # first one finished. n means they really ran side by side.
        first_done = next((k for k, (_, meth) in enumerate(order) if meth == "turn/completed"), len(order))
        active_before_first = len({i for i, _ in order[:first_done]})
        log("round n=%d: wall=%.1fs completed=%d/%d slowest=%ss peak_rss=%dkB peak_children=%d" % (
            n, wall, len(finished), n, slowest, sampler.peak_rss, sampler.peak_kids))
        log("    interleaved: %d of %d threads had produced events before the first turn completed" % (
            active_before_first, n))
        log("    per-thread completion (s): %s" % json.dumps(sorted(finished.values())))
        if len(finished) < n:
            log("    ! stopping here: not every turn completed")
            break

    log("final rss=%dkB children=%d" % (rss_kb(s.pid), len(descendants(s.pid))))
    ctx.cleanup(s, *pool)
    s.close()
    ctx.done()


# -- q5: do child processes survive turn/interrupt? -------------------------


def cmd_child_survival(args):
    ctx = Ctx(args, "child-survival")
    s = ctx.server()
    s.handshake()
    tid = ctx.new_thread(s)
    log("thread %s, app-server pid %s" % (tid, s.pid))
    cur = 0
    command = args.child_command % MARKER_SLEEP
    turn_id = turn(
        s, tid,
        "run exactly this shell command and nothing else, then reply with only the word ok: `%s`" % command,
        sandboxPolicy={"type": "workspaceWrite", "writableRoots": [ctx.ws]},
    )
    log("turn %s, command %r" % (turn_id, command))
    cur, item = s.wait(lambda m: m.get("method") == "item/started"
                       and m.get("params", {}).get("item", {}).get("type") == "commandExecution", 240, cur)
    log("commandExecution started: %s" % (json.dumps(item["params"]["item"])[:400] if item else None))
    time.sleep(3)
    before = subprocess.run(["pgrep", "-fl", "sleep %s" % MARKER_SLEEP], capture_output=True, text=True).stdout.strip()
    log("before interrupt, matching processes:\n  %s" % (before.replace("\n", "\n  ") or "(none)"))
    log("app-server descendants: %s" % descendants(s.pid))
    res = s.try_call("turn/interrupt", {"threadId": tid, "turnId": turn_id}, timeout=60)
    log("turn/interrupt -> %s" % json.dumps(res))
    cur, done = s.wait(notif("turn/completed"), 120, cur)
    log("turn/completed status=%s" % (done["params"]["turn"]["status"] if done else None))
    time.sleep(2)
    after = subprocess.run(["pgrep", "-fl", "sleep %s" % MARKER_SLEEP], capture_output=True, text=True).stdout.strip()
    log("after interrupt, matching processes:\n  %s" % (after.replace("\n", "\n  ") or "(none)"))
    ctx.cleanup(s, tid)
    log("closing the app-server")
    s.close()
    time.sleep(2)
    after_exit = subprocess.run(["pgrep", "-fl", "sleep %s" % MARKER_SLEEP], capture_output=True, text=True).stdout.strip()
    log("after the app-server exits:\n  %s" % (after_exit.replace("\n", "\n  ") or "(none)"))
    if after_exit:
        subprocess.run(["pkill", "-f", "sleep %s" % MARKER_SLEEP])
        log("cleaned up the leftover child(ren) this probe started")
    ctx.done()


# -- q6: can daemon + proxy outlive the client? ----------------------------


def daemon(*a):
    r = subprocess.run(["codex", "app-server", "daemon", *a], capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()


def cmd_daemon_proxy(args):
    """can a thread keep running after the client that started it goes away?

    three ways to hold the app-server outside the client process:
      daemon  `app-server daemon start` + `app-server proxy` (needs the managed
              standalone install at ~/.codex/packages/standalone/current/codex)
      unix    our own `--listen unix://SOCK` + `app-server proxy --sock SOCK`
      ws      our own `--listen ws://127.0.0.1:PORT`, attached to directly
    the socket transports speak websocket, so `ws` needs no extra binary.
    """
    ctx = Ctx(args, "daemon-proxy")
    code, before = daemon("version")
    if code == 0 and "failed to connect" not in before:
        log("! a daemon is already running: %s" % before.replace("\n", " | ")[:200])
        log("! refusing to start or stop someone else's daemon.")
        return ctx.done(rec_summary=False)
    log("daemon version (before): %s" % before.replace("\n", " | ")[:220])

    transport, host, connect = args.transport, None, None
    if transport in ("auto", "daemon"):
        code, start_out = daemon("start")
        log("daemon start exit=%d: %s" % (code, start_out.replace("\n", " | ")[:340]))
        if code == 0:
            transport = "daemon"
            connect = lambda label: ctx.server(label=label, cmd=["codex", "app-server", "proxy"])
        elif transport == "daemon":
            return ctx.done(rec_summary=False)
        else:
            transport = "unix" if args.try_unix else "ws"

    if transport == "unix":
        sock = args.sock
        os.makedirs(os.path.dirname(sock), exist_ok=True)
        if os.path.exists(sock):
            os.unlink(sock)
        log("self-hosting `--listen unix://%s`" % sock)
        host = spawn_host(ctx, ["codex", "app-server", "--listen", "unix://" + sock])
        for _ in range(40):
            if os.path.exists(sock):
                break
            time.sleep(0.25)
        log("host pid %s, socket present=%s" % (host.pid, os.path.exists(sock)))
        connect = lambda label: ctx.server(label=label,
                                           cmd=["codex", "app-server", "proxy", "--sock", sock])
    elif transport == "ws":
        log("self-hosting `--listen ws://127.0.0.1:%d`" % args.port)
        host = spawn_host(ctx, ["codex", "app-server", "--listen", "ws://127.0.0.1:%d" % args.port])
        time.sleep(5)
        log("host pid %s" % host.pid)
        connect = lambda label: ctx.server(label=label, ws=("127.0.0.1", args.port))

    log("transport: %s" % transport)
    try:
        try:
            s = connect("client-1")
            s.handshake(name="bob-probe")
        except Exception as e:
            log("! could not attach over %s: %s: %s" % (transport, type(e).__name__, e))
            log("! see %s for what the host logged" % os.path.join(ctx.out, "host.log"))
            return ctx.done()
        tid = ctx.new_thread(s)
        log("thread %s" % tid)
        log("thread/loaded/list: %s" % json.dumps(s.try_call("thread/loaded/list", {}, timeout=30))[:300])
        turn_id = turn(s, tid, LONG_PROMPT)
        log("turn %s started; waiting for the first delta, then dropping the client" % turn_id)
        s.wait(notif("item/agentMessage/delta"), 240, 0)
        s.kill()
        log("client dropped; waiting %ss with nothing attached" % args.wait_after_kill)
        time.sleep(args.wait_after_kill)
        log("host still alive=%s" % (host is None or host.poll() is None))

        s2 = connect("client-2")
        s2.handshake(name="bob-probe")
        log("thread/loaded/list after reconnect: %s" % json.dumps(s2.try_call("thread/loaded/list", {}, timeout=30))[:500])
        read = s2.call("thread/read", {"threadId": tid, "includeTurns": True})
        log("thread/read status=%s" % json.dumps(read["thread"].get("status")))
        for t in read["thread"].get("turns") or []:
            items = t.get("items", [])
            txt = next((i.get("text", "") for i in items if i.get("type") == "agentMessage"), "")
            log("  turn %s status=%s items=%d agentMessage=%d chars" % (
                t.get("id"), t.get("status"), len(items), len(txt)))
        ctx.cleanup(s2, tid)
        s2.close()
    finally:
        if transport == "daemon":
            log("daemon stop: %s" % " | ".join(daemon("stop")[1].splitlines())[:200])
        if host is not None:
            kill_host(host)
            log("self-hosted app-server stopped (exit=%s)" % host.returncode)
    ctx.done()


def spawn_host(ctx, cmd):
    return subprocess.Popen(cmd, stdin=subprocess.DEVNULL,
                            stdout=open(os.path.join(ctx.out, "host.log"), "wb"),
                            stderr=subprocess.STDOUT, start_new_session=True)


def kill_host(host):
    """the npm-installed codex is a node wrapper, so SIGTERM to the wrapper is
    not enough -- signal the whole process group."""
    try:
        os.killpg(os.getpgid(host.pid), signal.SIGTERM)
        host.wait(timeout=15)
    except (subprocess.TimeoutExpired, ProcessLookupError):
        try:
            os.killpg(os.getpgid(host.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        host.wait()


COMMANDS = {
    "pending-approval": cmd_pending_approval,
    "double-turn": cmd_double_turn,
    "concurrency": cmd_concurrency,
    "child-survival": cmd_child_survival,
    "daemon-proxy": cmd_daemon_proxy,
}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("command", choices=sorted(COMMANDS))
    ap.add_argument("--out", help="capture directory (default: a fresh temp dir)")
    ap.add_argument("--wait", type=int, default=300, help="pending-approval: seconds to sit on it")
    ap.add_argument("--rounds", default="2,4,8", help="concurrency: thread counts to try")
    ap.add_argument("--wait-after-kill", type=int, default=20,
                    help="daemon-proxy: seconds between killing and reconnecting")
    ap.add_argument("--child-command", default="sleep %s",
                    help="child-survival: shell command to run (%%s is a unique sleep duration)")
    # unix sockets are capped at ~104 bytes and the parent directory must not be
    # a symlink, which rules out both a long temp dir and /tmp on macOS.
    ap.add_argument("--sock", default="/private/tmp/bob-codex-probe/app-server.sock",
                    help="daemon-proxy: socket path when self-hosting over unix")
    ap.add_argument("--port", type=int, default=47311,
                    help="daemon-proxy: loopback port when self-hosting over websocket")
    ap.add_argument("--transport", default="auto", choices=("auto", "daemon", "unix", "ws"),
                    help="daemon-proxy: how to hold the app-server outside the client")
    ap.add_argument("--try-unix", action="store_true",
                    help="daemon-proxy: with --transport auto, try unix+proxy before websocket")
    ap.add_argument("--delete", action="store_true", help="thread/delete instead of thread/archive")
    ap.add_argument("--keep", action="store_true", help="leave probe threads in place")
    args = ap.parse_args()
    COMMANDS[args.command](args)


if __name__ == "__main__":
    main()
