"""sandy-claude-usage and sandy-claude-statusline, run for real.

Both helpers are baked into Dockerfile.base by sandy's generate_dockerfile_base
heredoc; this extracts them from the script (so it tests what ships) and runs
them against payloads shaped like Claude Code's statusLine JSON. Run by
run-tests.sh §81; also runnable on its own: python3 test/test_claude_usage_statusline.py
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

SANDY = Path(__file__).resolve().parent.parent / "sandy"


def _heredoc(name):
    text = SANDY.read_text()
    m = re.search(r"<<'%s' \\\n[^\n]*\n(.*?)\n%s\n" % (name, name), text, re.S)
    if not m:
        raise RuntimeError("heredoc %s not found in sandy" % name)
    return m.group(1) + "\n"


FUTURE = int(datetime.datetime.now(tz=datetime.timezone.utc).timestamp()) + 3 * 86400


def payload(seven=None, five=None, api_ms=None, out=None, sid="s1"):
    p = {"session_id": sid, "model": {"display_name": "Opus"},
         "context_window": {"used_percentage": 40.2}}
    rl = {}
    if seven is not None:
        rl["seven_day"] = {"used_percentage": seven, "resets_at": FUTURE}
    if five is not None:
        rl["five_hour"] = {"used_percentage": five, "resets_at": FUTURE - 86400}
    if rl:
        p["rate_limits"] = rl
    if api_ms is not None:
        p["cost"] = {"total_api_duration_ms": api_ms, "total_duration_ms": 10 ** 9}
    if out is not None:
        p["context_window"]["total_output_tokens"] = out
    return p


class Base(unittest.TestCase):
    def setUp(self):
        self.td = Path(tempfile.mkdtemp())
        self.home = self.td / "home"
        (self.home / ".claude").mkdir(parents=True)
        self.usage = self.td / "sandy-claude-usage"
        self.usage.write_text(_heredoc("CLAUDE_USAGE_HELPER"))
        self.usage.chmod(0o755)
        self.marker = self.td / "marker.json"
        self.rl = self.home / ".claude" / "rate-limits"

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def env(self, **kw):
        e = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.home),
             "SANDY_USAGE_MARKER": str(self.marker), "SANDY_USAGE_STATE_DIR": str(self.td / "state"),
             "TZ": "UTC"}
        e.update(kw)
        return e

    def run_usage(self, data, raw=None, **env):
        raw = raw if raw is not None else json.dumps(data).encode()
        p = subprocess.run([sys.executable, "-I", str(self.usage)], input=raw,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env(**env))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stderr, b"")
        return p.stdout.decode()

    def mark(self, **m):
        self.marker.write_text(json.dumps(m))


class TestUsage(Base):
    def test_token_labelled_by_marker(self):
        self.mark(cred_mode="oauth-token", credentials={"claude": {"kind": "oauth-token", "fingerprint": "989bdc2f", "label": "corp (eng)"}})
        out = self.run_usage(payload(seven=78.4, five=12.0))
        self.assertTrue(out.startswith("corp (eng) · 7d 78% \u21bb"), out)
        self.assertIn("5h 12% \u21bb", out)
        latest = json.loads((self.rl / "rate-limits-latest.json").read_text())
        self.assertEqual((latest["credential"], latest["credential_kind"]), ("989bdc2f", "oauth-token"))
        self.assertEqual(latest["seven_day"]["used_percentage"], 78.4)
        self.assertTrue(latest["seven_day"]["resets_at_utc"].endswith("Z"))

    def test_token_without_label_shows_fingerprint(self):
        self.mark(cred_mode="api-key", credentials={"claude": {"kind": "api-key", "fingerprint": "0badf00d"}})
        self.assertTrue(self.run_usage(payload(seven=1)).startswith("0badf00d · "))

    def test_token_never_named_by_the_stale_login_record(self):
        # A token names no account; .claude.json holds an older /login.
        self.mark(cred_mode="oauth-token", credentials={})
        (self.home / ".claude" / ".claude.json").write_text(json.dumps(
            {"oauthAccount": {"accountUuid": "abcdef12-0", "emailAddress": "old@example.com"}}))
        out = self.run_usage(payload(seven=5))
        self.assertNotIn("old@example.com", out)
        self.assertTrue(out.startswith("7d 5%"), out)

    def test_login_named_by_email(self):
        self.mark(cred_mode="full", credentials={})
        (self.home / ".claude" / ".claude.json").write_text(json.dumps(
            {"oauthAccount": {"accountUuid": "feedface-0", "emailAddress": "me@example.com"}}))
        self.assertTrue(self.run_usage(payload(seven=5)).startswith("me@example.com · 7d 5%"))
        latest = json.loads((self.rl / "rate-limits-latest.json").read_text())
        self.assertEqual((latest["credential"], latest["credential_kind"]), ("feedface", "login"))

    def test_records_only_changes(self):
        self.mark(credentials={"claude": {"kind": "oauth-token", "fingerprint": "989bdc2f"}})
        for pct in (10.0, 10.0, 20.0):
            self.run_usage(payload(seven=pct))
        lines = next(self.rl.glob("rate-limits-*.jsonl")).read_text().splitlines()
        self.assertEqual([json.loads(l)["seven_day"]["used_percentage"] for l in lines], [10.0, 20.0])

    def test_no_usage_no_record(self):
        self.assertEqual(self.run_usage(payload()), "")
        self.assertFalse(self.rl.exists())

    def test_expired_window_dropped(self):
        p = payload(seven=90, five=5)
        p["rate_limits"]["seven_day"]["resets_at"] = 1
        out = self.run_usage(p)
        self.assertNotIn("7d", out)
        self.assertIn("5h 5%", out)

    def test_bad_input_is_silent(self):
        for raw in (b"not json", b"[1,2]", b"", b'{"rate_limits":{"seven_day":{"used_percentage":"x","resets_at":true}}}'):
            self.assertEqual(self.run_usage(None, raw=raw), "")

    def test_tok_per_s_is_last_reply_over_api_time_growth(self):
        # First render: no baseline yet.
        self.assertNotIn("tok/s", self.run_usage(payload(api_ms=2000, out=50)))
        # A reply of 300 tokens while API time grew by 6 s: 50 tok/s. The
        # session's wall clock (total_duration_ms) must not enter into it.
        self.assertIn("~50 tok/s", self.run_usage(payload(api_ms=8000, out=300)))
        # A render with no new API time keeps the last rate.
        self.assertIn("~50 tok/s", self.run_usage(payload(api_ms=8000, out=300)))
        # The counter going back is another session: no rate until a new delta.
        self.assertNotIn("tok/s", self.run_usage(payload(api_ms=100, out=300)))
        # Sessions do not share state.
        self.assertNotIn("tok/s", self.run_usage(payload(api_ms=9000, out=300, sid="other")))


class TestStatusline(Base):
    def setUp(self):
        super().setUp()
        if not shutil.which("jq"):
            self.skipTest("needs jq")
        sl = _heredoc("STATUSLINE_HELPER")
        # Point at the extracted usage helper; drop timeout (GNU) for macOS hosts.
        sl = sl.replace("/usr/local/bin/sandy-claude-usage", str(self.usage)).replace("timeout 2 ", "")
        self.sl = self.td / "sandy-claude-statusline"
        self.sl.write_text(sl)
        self.sl.chmod(0o755)
        self.mark(credentials={"claude": {"kind": "oauth-token", "fingerprint": "989bdc2f", "label": "corp"}})

    def run_sl(self, data, **env):
        p = subprocess.run(["bash", str(self.sl)], input=json.dumps(data).encode(),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env(**env))
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.decode()

    def test_appends_usage(self):
        out = self.run_sl(payload(seven=78))
        self.assertTrue(out.startswith("Opus · 40% ctx · corp · 7d 78% \u21bb"), out)

    def test_usage_off(self):
        self.assertEqual(self.run_sl(payload(seven=78), SANDY_CLAUDE_USAGE="0"), "Opus · 40% ctx\n")

    def test_wraps_host_command_first(self):
        cmd = "%s -c 'import sys,json; print(\"HOST \" + json.load(sys.stdin)[\"session_id\"])'" % sys.executable
        out = self.run_sl(payload(seven=1), SANDY_STATUSLINE_WRAP=cmd).split("\n")
        self.assertEqual(out[0], "HOST s1")
        self.assertTrue(out[1].startswith("Opus · 40% ctx · corp"), out)

    def test_failing_host_command_is_dropped(self):
        out = self.run_sl(payload(seven=1), SANDY_STATUSLINE_WRAP="exit 3")
        self.assertTrue(out.startswith("Opus · 40% ctx · corp"), out)


if __name__ == "__main__":
    unittest.main()
