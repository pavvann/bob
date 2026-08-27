#!/usr/bin/env python3
"""record the `codex app-server` protocol legs bob needs to decode.

drives one app-server through: initialize -> account/read + model/list ->
thread/start + thread/name/set -> a turn that needs a command approval -> a
turn that asks the user a question -> turn/steer -> turn/interrupt ->
thread/resume + thread/read, and writes every line, both directions, as JSONL.

runs against the real `~/.codex` home, so every leg is a real thread and real
quota. the prompts are trivial and the thread is archived (or deleted) at the
end. usage:

    python3 tools/codex-probe/probe.py --out /tmp/codex-probe --delete

re-run it against a new CLI version and diff the summary table to see what
moved.
"""

import argparse
import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from appserver import AppServer, Recorder, notif, server_request, summary  # noqa: E402

# request_user_input is an under-development feature; without this the model has
# no tool to ask a question with and leg 04 records nothing.
USER_INPUT_FEATURE = "default_mode_request_user_input"

APPROVAL_METHODS = (
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/permissions/requestApproval",
    "execCommandApproval",  # legacy
    "applyPatchApproval",  # legacy
)

LONG_PROMPT = (
    "write about 300 words on what a terminal emulator does. plain prose, no "
    "lists, no tool calls."
)


def log(*a):
    print(*a, flush=True)


class Probe:
    def __init__(self, args):
        self.args = args
        self.out = args.out or tempfile.mkdtemp(prefix="codex-probe-")
        self.ws = os.path.join(self.out, "workspace")
        os.makedirs(self.ws, exist_ok=True)
        self.rec = Recorder(self.out)
        self.thread_id = None
        self.cursor = 0
        self.server = None

    # -- helpers ----------------------------------------------------------

    def spawn(self, label="server"):
        extra = [] if self.args.no_user_input else ["--enable", USER_INPUT_FEATURE]
        self.server = AppServer(self.rec, label=label, extra_args=extra)
        self.cursor = 0
        return self.server

    def turn_opts(self, **over):
        opts = {
            "threadId": self.thread_id,
            "approvalPolicy": "never",
            "sandboxPolicy": {"type": "readOnly"},
        }
        if self.args.model:
            opts["model"] = self.args.model
        if self.args.effort:
            opts["effort"] = self.args.effort
        opts.update(over)
        return opts

    def start_turn(self, text, **over):
        res = self.server.call("turn/start", self.turn_opts(input=[{"type": "text", "text": text}], **over))
        return res["turn"]["id"]

    def await_completion(self, timeout=300):
        self.cursor, done = self.server.wait(notif("turn/completed"), timeout, self.cursor)
        if done is None:
            log("    ! no turn/completed within %ss" % timeout)
            return None
        turn = done["params"]["turn"]
        log("    turn/completed status=%s items=%d" % (turn["status"], len(turn.get("items", []))))
        return turn

    # -- legs -------------------------------------------------------------

    def leg_initialize(self):
        self.rec.start_leg("01-initialize")
        info = self.spawn().handshake()
        log("    codexHome=%s userAgent=%s" % (info.get("codexHome"), info.get("userAgent")))
        acct = self.server.call("account/read", {})
        log("    account/read: type=%s planType=%s" % (
            (acct.get("account") or {}).get("type"),
            (acct.get("account") or {}).get("planType"),
        ))
        models = self.server.call("model/list", {})
        rows = models.get("data", [])
        log("    model/list: %d models, default=%s" % (
            len(rows), next((m["id"] for m in rows if m.get("isDefault")), None)))

    def leg_thread(self):
        self.rec.start_leg("02-thread")
        res = self.server.call("thread/start", {"cwd": self.ws})
        self.thread_id = res["thread"]["id"]
        log("    thread/start: %s (model=%s sandbox=%s)" % (
            self.thread_id, res.get("model"), json.dumps(res.get("sandbox"))[:60]))
        self.server.call("thread/name/set", {"threadId": self.thread_id, "name": self.args.name})
        log("    thread/name/set: %r" % self.args.name)

    def leg_approval(self):
        self.rec.start_leg("03-approval")
        # `untrusted` asks before anything not on the trusted list; `date` is not
        # on it, and running it changes nothing.
        self.start_turn(
            "run the shell command `date +%s` and reply with only its output",
            approvalPolicy="untrusted",
        )
        self.cursor, req = self.server.wait(server_request(*APPROVAL_METHODS), 180, self.cursor)
        if req is None:
            log("    ! no approval request arrived")
            return
        p = req["params"]
        log("    %s id=%s command=%r" % (req["method"], req["id"], p.get("command")))
        log("    availableDecisions=%s" % json.dumps(p.get("availableDecisions")))
        self.server.respond(req["id"], {"decision": "accept"})
        self.cursor, res = self.server.wait(notif("serverRequest/resolved"), 60, self.cursor)
        log("    serverRequest/resolved: %s" % json.dumps(res["params"]) if res else "    ! no resolve")
        self.await_completion()

    def leg_userinput(self):
        self.rec.start_leg("04-userinput")
        if self.args.no_user_input:
            log("    skipped (--no-user-input): shape is in the pinned schema at")
            log("    ToolRequestUserInputParams.json / ToolRequestUserInputResponse.json")
            return
        self.start_turn(
            "before doing anything at all, use your request_user_input tool to ask me one "
            "question: whether i want the greeting 'hi' or 'hello'. do not guess and do not "
            "run any commands. once i answer, reply with only the word i picked."
        )
        self.cursor, req = self.server.wait(server_request("item/tool/requestUserInput"), 240, self.cursor)
        if req is None:
            log("    ! no item/tool/requestUserInput arrived — the model chose not to ask.")
            log("      re-run, or read the shape from the pinned schema.")
            return
        qs = req["params"]["questions"]
        log("    item/tool/requestUserInput id=%s isBlocking=%s questions=%d" % (
            req["id"], req["params"].get("isBlocking"), len(qs)))
        for q in qs:
            log("      q %r %r options=%s" % (
                q["id"], q["question"], [o["label"] for o in (q.get("options") or [])]))
        # answers are keyed by question id; each value is a list of option labels
        # (free text when the question sets isOther).
        answers = {
            q["id"]: {"answers": [(q.get("options") or [{"label": "hello"}])[0]["label"]]}
            for q in qs
        }
        self.server.respond(req["id"], {"answers": answers})
        log("    answered: %s" % json.dumps(answers))
        self.await_completion()

    def leg_steer(self):
        self.rec.start_leg("05-steer")
        turn_id = self.start_turn(LONG_PROMPT)
        log("    turn %s started" % turn_id)
        self.cursor, _ = self.server.wait(notif("item/agentMessage/delta"), 240, self.cursor)
        res = self.server.try_call(
            "turn/steer",
            {
                "threadId": self.thread_id,
                "expectedTurnId": turn_id,
                "input": [{"type": "text", "text": "stop there. reply with only the word: steered"}],
            },
        )
        log("    turn/steer -> %s" % json.dumps(res)[:300])
        self.await_completion()

    def leg_interrupt(self):
        self.rec.start_leg("06-interrupt")
        turn_id = self.start_turn(LONG_PROMPT)
        log("    turn %s started" % turn_id)
        self.cursor, _ = self.server.wait(notif("item/agentMessage/delta"), 240, self.cursor)
        res = self.server.try_call("turn/interrupt", {"threadId": self.thread_id, "turnId": turn_id})
        log("    turn/interrupt -> %s" % json.dumps(res)[:300])
        self.await_completion(timeout=120)

    def leg_resume(self):
        self.rec.start_leg("07-resume")
        log("    closing the app-server, then reconnecting")
        self.server.close()
        self.spawn(label="server-2").handshake()
        res = self.server.call("thread/resume", {"threadId": self.thread_id})
        log("    thread/resume: status=%s" % json.dumps(res["thread"].get("status")))
        read = self.server.call("thread/read", {"threadId": self.thread_id, "includeTurns": True})
        turns = read["thread"].get("turns") or []
        log("    thread/read: %d turns, keys=%s" % (len(turns), sorted(read["thread"].keys())))
        for t in turns:
            log("      turn %s status=%s items=%d" % (t.get("id"), t.get("status"), len(t.get("items", []))))

    def leg_cleanup(self):
        self.rec.start_leg("08-cleanup")
        if self.args.keep:
            log("    kept thread %s (--keep)" % self.thread_id)
            return
        method = "thread/delete" if self.args.delete else "thread/archive"
        log("    %s -> %s" % (method, json.dumps(
            self.server.try_call(method, {"threadId": self.thread_id}))[:200]))

    # -- driver -----------------------------------------------------------

    LEGS = [
        ("initialize", leg_initialize),
        ("thread", leg_thread),
        ("approval", leg_approval),
        ("userinput", leg_userinput),
        ("steer", leg_steer),
        ("interrupt", leg_interrupt),
        ("resume", leg_resume),
        ("cleanup", leg_cleanup),
    ]

    def run(self):
        wanted = self.args.legs.split(",") if self.args.legs else [n for n, _ in self.LEGS]
        log("out: %s" % self.out)
        started = time.time()
        try:
            for name, fn in self.LEGS:
                if name not in wanted:
                    continue
                log("[%s]" % name)
                fn(self)
        finally:
            log("")
            log("methods seen (%.1fs wall)" % (time.time() - started))
            log(summary(self.rec))
            log("")
            log("captures: %s" % self.out)
            if self.server:
                self.server.close()
            self.rec.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", help="capture directory (default: a fresh temp dir)")
    ap.add_argument("--legs", help="comma-separated subset: %s" % ",".join(n for n, _ in Probe.LEGS))
    ap.add_argument("--name", default="bob protocol probe", help="thread name")
    ap.add_argument("--model", help="model override for every turn")
    ap.add_argument("--effort", help="reasoning effort override for every turn")
    ap.add_argument("--delete", action="store_true", help="thread/delete instead of thread/archive")
    ap.add_argument("--keep", action="store_true", help="leave the probe thread in place")
    ap.add_argument("--no-user-input", action="store_true",
                    help="do not enable %s (skips the question leg)" % USER_INPUT_FEATURE)
    Probe(ap.parse_args()).run()


if __name__ == "__main__":
    main()
