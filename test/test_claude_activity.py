"""sandy-claude-activity, run for real.

The helper is baked into Dockerfile.base by sandy's generate_dockerfile_base
heredoc; this extracts it from the script (so it tests what ships) and feeds it
hook payloads shaped like the ones Claude Code 2.1.310 sent in a measured TUI
run. Run by run-tests.sh §210; also runnable on its own:
python3 test/test_claude_activity.py
"""
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SANDY = Path(os.environ.get("SANDY_SCRIPT") or Path(__file__).resolve().parent.parent / "sandy")
T0 = 1_790_000_000  # a fixed UTC epoch, so dates and ages are exact


def _heredoc(name):
    text = SANDY.read_text()
    m = re.search(r"<<'%s' \\\n[^\n]*\n(.*?)\n%s\n" % (name, name), text, re.S)
    if not m:
        raise RuntimeError("heredoc %s not found in sandy" % name)
    return m.group(1) + "\n"


def day(t):
    return datetime.datetime.fromtimestamp(t, tz=datetime.timezone.utc).strftime("%Y-%m-%d")


class Base(unittest.TestCase):
    def setUp(self):
        self.td = Path(tempfile.mkdtemp())
        self.helper = self.td / "sandy-claude-activity"
        self.helper.write_text(_heredoc("CLAUDE_ACTIVITY_HELPER"))
        self.helper.chmod(0o755)
        self.out = self.td / "activity"
        self.marker = self.td / "marker.json"
        self.marker.write_text(json.dumps({"sandbox_name": "proj-1a2b3c4d"}))
        self.tsv = self.td / "sessions.tsv"
        self.t = T0

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def hook(self, event, sid="s1", raw=None, **extra):
        p = dict(extra, hook_event_name=event, session_id=sid)
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.td),
               "SANDY_ACTIVITY_DIR": str(self.out), "SANDY_ACTIVITY_MARKER": str(self.marker),
               "SANDY_ACTIVITY_SESSIONS": str(self.tsv), "SANDY_ACTIVITY_NOW": str(self.t)}
        r = subprocess.run([sys.executable, "-I", str(self.helper)], input=raw if raw is not None else json.dumps(p),
                           capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "", "a hook must print nothing (UserPromptSubmit stdout reaches the prompt)")
        return r

    def lines(self):
        out = []
        for f in sorted(self.out.glob("activity-*.jsonl")):
            out += [json.loads(x) for x in f.read_text().splitlines()]
        return out

    def latest(self):
        return json.loads((self.out / "activity-latest.json").read_text())

    def entry(self, sid="s1"):
        return self.latest()["sessions"][sid]


class States(Base):
    def test_turn_sequence_and_line_schema(self):
        for ev in ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"):
            self.hook(ev, source="startup") if ev == "SessionStart" else self.hook(ev)
        ls = self.lines()
        self.assertEqual([(l["event"], l["state"], l["seq"]) for l in ls],
                         [("SessionStart", "idle", 1), ("UserPromptSubmit", "working", 2), ("Stop", "idle", 3)])
        self.assertEqual(set(ls[0]), {"v", "ts", "sandbox", "agent", "session_id", "session_name", "seq",
                                      "event", "state", "subagents_active", "detail"})
        self.assertEqual((ls[0]["v"], ls[0]["agent"], ls[0]["sandbox"], ls[0]["session_name"]),
                         (1, "claude", "proj-1a2b3c4d", None))
        self.assertTrue(re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", ls[0]["ts"]))
        self.assertEqual(self.latest()["v"], 1)

    def test_only_changes_are_logged_but_last_event_ts_moves(self):
        self.hook("UserPromptSubmit")
        self.t += 30
        self.hook("PreToolUse", tool_name="Bash")
        self.t += 30
        self.hook("PostToolUse", tool_name="Bash")
        self.assertEqual(len(self.lines()), 1)
        e = self.entry()
        self.assertEqual((e["state"], e["seq"], e["event"], e["last_event"]), ("working", 1, "UserPromptSubmit", "PostToolUse"))
        self.assertEqual(e["last_event_ts"], datetime.datetime.fromtimestamp(T0 + 60, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))

    def test_notifications(self):
        self.hook("UserPromptSubmit")
        self.hook("PreToolUse", tool_name="Write")
        self.hook("Notification", notification_type="permission_prompt", message="Claude needs your permission")
        self.assertEqual((self.entry()["state"], self.entry()["detail"]), ("waiting", "permission_prompt"))
        self.hook("PostToolUse", tool_name="Write")
        self.assertEqual(self.entry()["state"], "working")
        self.hook("Notification", notification_type="auth_success")
        self.assertEqual(self.entry()["state"], "working", "an unrelated notification is not a state")
        self.hook("Notification", notification_type="idle_prompt")
        self.assertEqual(self.entry()["state"], "idle")

    def test_stopfailure_and_session_end(self):
        self.hook("UserPromptSubmit")
        self.hook("StopFailure")
        self.assertEqual(self.entry()["state"], "idle")
        self.hook("SessionEnd")
        self.assertEqual(self.entry()["state"], "ended")
        self.assertEqual(self.lines()[-1]["seq"], 3)

    def test_sessions_are_separate(self):
        self.hook("UserPromptSubmit", sid="a")
        self.hook("UserPromptSubmit", sid="b")
        self.hook("Stop", sid="a")
        self.assertEqual((self.entry("a")["state"], self.entry("a")["seq"]), ("idle", 2))
        self.assertEqual((self.entry("b")["state"], self.entry("b")["seq"]), ("working", 1))

    def test_session_name_from_sandys_record(self):
        self.tsv.write_text("launch\tL1\tdone\nctl\tup\ts-named\tController\tyes\tnone\t-\n")
        self.hook("UserPromptSubmit", sid="s-named")
        self.hook("UserPromptSubmit", sid="s-other")
        self.assertEqual(self.entry("s-named")["session_name"], "Controller")
        self.assertIsNone(self.entry("s-other")["session_name"])

    def test_no_marker_gives_null_sandbox(self):
        self.marker.unlink()
        self.hook("UserPromptSubmit")
        self.assertIsNone(self.entry()["sandbox"])


class Subagents(Base):
    def test_counted_by_id_and_internal_stops_ignored(self):
        self.hook("UserPromptSubmit")
        self.hook("SubagentStop", agent_id="internal1", agent_type="")
        self.assertEqual(self.entry()["subagents_active"], 0, "a stop for an id that never started must not count")
        self.hook("SubagentStart", agent_id="a1", agent_type="general-purpose")
        self.hook("SubagentStart", agent_id="a2", agent_type="general-purpose")
        self.hook("SubagentStop", agent_id="internal2", agent_type="")
        self.assertEqual(self.entry()["subagents_active"], 2)
        self.hook("Stop")
        e = self.entry()
        self.assertEqual((e["state"], e["subagents_active"]), ("idle", 2), "a background subagent outlives the turn")
        self.hook("SubagentStop", agent_id="a1")
        self.assertEqual(self.entry()["subagents_active"], 1)
        self.assertEqual([l["subagents_active"] for l in self.lines()], [0, 1, 2, 2, 1])

    def test_session_start_resets_but_compact_does_not(self):
        self.hook("UserPromptSubmit")
        self.hook("SubagentStart", agent_id="a1")
        self.hook("SessionStart", source="compact")
        self.assertEqual((self.entry()["state"], self.entry()["subagents_active"]), ("working", 1))
        self.hook("SessionStart", source="resume")
        self.assertEqual((self.entry()["state"], self.entry()["subagents_active"]), ("idle", 0))


class Retention(Base):
    def test_prune_idle_or_ended_after_24h_only(self):
        for sid in ("old-idle", "old-ended", "old-working", "fresh-idle"):
            self.hook("UserPromptSubmit", sid=sid)
        self.hook("Stop", sid="old-idle")
        self.hook("SessionEnd", sid="old-ended")
        self.t += 23 * 3600
        self.hook("Stop", sid="fresh-idle")
        self.t += 2 * 3600
        self.hook("UserPromptSubmit", sid="now")
        self.assertEqual(sorted(self.latest()["sessions"]), ["fresh-idle", "now", "old-working"])

    def test_daily_files_kept_14_days(self):
        self.out.mkdir()
        old, keep = self.out / ("activity-%s.jsonl" % day(T0 - 15 * 86400)), self.out / ("activity-%s.jsonl" % day(T0 - 13 * 86400))
        other = self.out / "notes.txt"
        for f in (old, keep, other):
            f.write_text("x\n")
        self.hook("UserPromptSubmit")
        self.assertFalse(old.exists())
        self.assertTrue(keep.exists() and other.exists())
        self.assertTrue((self.out / ("activity-%s.jsonl" % day(T0))).exists())


class Robustness(Base):
    def test_bad_input_prints_nothing_and_records_nothing(self):
        for raw in ("", "not json", "[1,2]", "null", json.dumps({"hook_event_name": "Stop"}),
                    json.dumps({"hook_event_name": "Stop", "session_id": "../../etc"}),
                    json.dumps({"hook_event_name": "Stop", "session_id": "x" * 500})):
            self.hook("Stop", raw=raw)
        self.assertFalse((self.out / "activity-latest.json").exists())

    def test_never_writes_through_a_planted_link(self):
        self.out.mkdir()
        victim = self.td / "victim"
        victim.write_text("keep\n")
        (self.out / ("activity-%s.jsonl" % day(T0))).symlink_to(victim)
        (self.out / "activity-latest.json").symlink_to(victim)
        self.hook("UserPromptSubmit")
        self.assertEqual(victim.read_text(), "keep\n")
        (self.out / ".lock").unlink()
        (self.out / ".lock").symlink_to(victim)
        (self.out / "activity-latest.json").unlink()
        self.hook("Stop")
        self.assertEqual(victim.read_text(), "keep\n")
        self.assertFalse((self.out / "activity-latest.json").exists(), "a planted lock link stops the write")

    def test_symlinked_activity_dir_is_refused(self):
        real = self.td / "elsewhere"
        real.mkdir()
        self.out.symlink_to(real)
        self.hook("UserPromptSubmit")
        self.assertEqual(list(real.iterdir()), [])

    def test_concurrent_hooks_lose_no_session(self):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.td),
               "SANDY_ACTIVITY_DIR": str(self.out), "SANDY_ACTIVITY_MARKER": str(self.marker),
               "SANDY_ACTIVITY_SESSIONS": str(self.tsv), "SANDY_ACTIVITY_NOW": str(self.t)}
        procs = [subprocess.Popen([sys.executable, "-I", str(self.helper)], stdin=subprocess.PIPE, env=env)
                 for _ in range(40)]
        for i, p in enumerate(procs):
            p.stdin.write(json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "c%d" % i}).encode())
            p.stdin.close()
        for p in procs:
            p.wait(timeout=60)
        self.assertEqual(len(self.latest()["sessions"]), 40, "an unlocked read-modify-write drops sessions")
        self.assertEqual(len(self.lines()), 40)


if __name__ == "__main__":
    unittest.main(verbosity=1)
