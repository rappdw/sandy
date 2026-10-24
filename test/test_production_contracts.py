"""Host properties executed against production source, never copied algorithms."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT / "sandy").read_text()


def span(start, end, source=SOURCE):
    if source.count(start) != 1 or source.count(end) != 1:
        raise AssertionError("production extraction anchor missing or ambiguous")
    return source.split(start, 1)[1].split(end, 1)[0]


def function(name, source=SOURCE):
    match = re.search(r"^" + re.escape(name) + r"\(\)\s*\{.*?^\}", source, re.M | re.S)
    if not match:
        raise AssertionError("missing production function: " + name)
    return match[0] + "\n"


def gemini_credential_probe_source():
    """Run the production loader and mount assembly with synthetic credentials."""
    staged_name = next(line for line in SOURCE.splitlines() if line.startswith('_sandy_staged_name()'))
    mount_start = '    RUN_FLAGS+=(-v "$SANDBOX_DIR/gemini:/home/sandy/.gemini")'
    mount_end = '\nfi\nif _sandy_agent_has codex; then\n    RUN_FLAGS+=(-v "$SANDBOX_DIR/codex:/home/sandy/.codex")'
    return ('set -euo pipefail\ninfo() { :; }; warn() { echo "$*" >&2; }\n'
            + staged_name + '\n' + function('_gemini_write_auth_type') + function('load_gemini_credentials')
            + '\n_sandy_launch_id=credential-probe\nGEMINI_CRED_TMPDIR=""\nGEMINI_ADC_MOUNT=""\n'
            + 'RUN_FLAGS=()\nmkdir -p "$SANDBOX_DIR/gemini"\nload_gemini_credentials\n'
            + mount_start + span(mount_start, mount_end)
            + '\nprintf "%s\\0" "$GEMINI_CRED_TMPDIR" "$GEMINI_SELECTED_AUTH" "${RUN_FLAGS[@]}"\n')


def gemini_credential_cleanup_source():
    start = '    if [ -n "${GEMINI_CRED_TMPDIR:-}" ]; then\n        rm -rf "$GEMINI_CRED_TMPDIR" || true\n'
    end = '    if [ -n "${CODEX_CRED_TMPDIR:-}" ]; then\n        rm -rf "$CODEX_CRED_TMPDIR" || true\n'
    return start + span(start, end)


class ProductionContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.ws = self.home / "workspace"
        self.sb = self.root / "sandbox"
        for path in (self.ws, self.sb / "claude", self.home / ".claude"):
            path.mkdir(parents=True, exist_ok=True)
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.home),
                    "WORK_DIR": str(self.ws), "SANDBOX_DIR": str(self.sb),
                    "SANDY_HOME": str(self.home / ".sandy"), "SANDBOX_IS_NEW": "true"}

    def run_source(self, code, **env):
        prefix = 'set -euo pipefail\ninfo() { :; }; warn() { echo "$*" >&2; }; error() { echo "$*" >&2; }\n'
        return subprocess.run(["bash", "-c", prefix + code], env={**self.env, **env},
                              stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=20)

    def test_gemini_oauth_refresh_is_private_per_launch_and_cleaned_up(self):
        host_dir = self.home / '.gemini'
        host_dir.mkdir()
        original = '{"access_token":"fixture-old","refresh_token":"fixture-refresh"}'
        for filename in ('oauth_creds.json', 'tokens.json'):
            with self.subTest(filename=filename):
                host = host_dir / filename
                host.write_text(original)
                copies = []
                for _ in range(2):
                    run = self.run_source(gemini_credential_probe_source(), SANDY_GEMINI_AUTH='oauth',
                                          TMPDIR=str(self.root))
                    self.assertEqual(run.returncode, 0, run.stderr)
                    directory, auth, *flags = run.stdout.rstrip('\0').split('\0')
                    copy = Path(directory) / filename
                    copies.append(copy)
                    self.assertEqual(auth, 'oauth-personal')
                    self.assertIn(str(copy) + ':/home/sandy/.gemini/' + filename + ':rw', flags)
                    self.assertEqual(Path(directory).stat().st_mode & 0o777, 0o700)
                    self.assertEqual(copy.stat().st_mode & 0o777, 0o600)
                    self.assertFalse(copy.samefile(host))
                    self.assertEqual(copy.read_text(), original)
                self.assertNotEqual(copies[0], copies[1])
                copies[0].write_text('{"access_token":"fixture-refreshed"}')
                self.assertEqual(host.read_text(), original)
                self.assertEqual(copies[1].read_text(), original)
                # Cleanup must unlink a planted symlink without following it.
                (copies[0].parent / 'planted').symlink_to(host_dir, target_is_directory=True)
                for copy in copies:
                    run = self.run_source(gemini_credential_cleanup_source(), GEMINI_CRED_TMPDIR=str(copy.parent))
                    self.assertEqual(run.returncode, 0, run.stderr)
                    self.assertFalse(copy.parent.exists())
                self.assertEqual(host.read_text(), original)
                host.unlink()
        # API-key mode must not import OAuth, and the original ADC file stays RO.
        (host_dir / 'oauth_creds.json').write_text(original)
        run = self.run_source(gemini_credential_probe_source(), SANDY_GEMINI_AUTH='api_key',
                              GEMINI_API_KEY='fixture-key', TMPDIR=str(self.root))
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout.split('\0')[:2], ['', 'gemini-api-key'])
        self.assertNotIn('oauth_creds.json', run.stdout)
        adc = self.home / '.config/gcloud/application_default_credentials.json'
        adc.parent.mkdir(parents=True)
        adc.write_text('{}')
        run = self.run_source(gemini_credential_probe_source(), SANDY_GEMINI_AUTH='adc', TMPDIR=str(self.root))
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn(str(adc) + ':/home/sandy/.config/gcloud/application_default_credentials.json:ro', run.stdout)

    def test_virtualenv_detection_and_version_precedence(self):
        code = "SANDY_VENV_OVERLAY_ACTIVE=false\n" + span(
            "SANDY_VENV_OVERLAY_ACTIVE=false\n", "# Skill pack persistent state.")
        code += '\nprintf "%s|%s" "$SANDY_VENV_OVERLAY_ACTIVE" "$SANDY_VENV_PYTHON_VERSION"\n'
        venv = self.ws / ".venv"
        self.assertEqual(self.run_source(code).stdout, "false|")
        venv.mkdir()
        for cfg, expected in (("version_info = 3.10.16.final.0", "3.10"),
                              ("version = 3.11.5", "3.11"), ("home = /usr/bin", "")):
            (venv / "pyvenv.cfg").write_text(cfg + "\n")
            run = self.run_source(code)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout, "true|" + expected)
        (self.ws / ".python-version").write_text("3.12\n")
        self.assertEqual(self.run_source(code).stdout, "true|3.12")
        (self.ws / ".python-version").write_text("3.11; touch INJECTED\n")
        self.assertEqual(self.run_source(code).stdout, "true|")
        self.assertEqual(self.run_source(code, SANDY_VENV_OVERLAY="0").stdout, "false|")
        shutil.rmtree(venv)
        venv.symlink_to(self.sb)
        self.assertEqual(self.run_source(code).stdout, "false|")
        self.assertFalse((self.ws / "INJECTED").exists())
        # Removing the actual production opt-out must change this observation.
        venv.unlink()
        venv.mkdir()
        mutant = code.replace('[ "${SANDY_VENV_OVERLAY:-1}" != "0" ]', 'true', 1)
        self.assertNotEqual(mutant, code)
        self.assertNotEqual(self.run_source(mutant, SANDY_VENV_OVERLAY="0").stdout, "false|")

    def test_world_open_lan_refusal_and_positive_control(self):
        code = span('# Sanity: reject world-open SANDY_ALLOW_LAN_HOSTS values.',
                    '# Validate SANDY_LOCAL_LLM_HOST (host:port).')
        # The first line after the anchor is prose continuing its comment.
        code = code[code.index('\nif ['):]
        for value in ("0.0.0.0/0", "::/0", "10.0.0.1, ::/0"):
            run = self.run_source(code, SANDY_ALLOW_LAN_HOSTS=value)
            self.assertEqual(run.returncode, 1, run.stderr)
            self.assertIn("world-open entry", run.stderr)
        for value in ("", "10.0.0.1", "192.168.1.0/24"):
            self.assertEqual(self.run_source(code, SANDY_ALLOW_LAN_HOSTS=value).returncode, 0)
        mutant = code.replace("exit 1 ;;", "true ;;")
        self.assertNotEqual(mutant, code)
        self.assertEqual(self.run_source(mutant, SANDY_ALLOW_LAN_HOSTS="::/0").returncode, 0)

    def test_screenshot_directory_rejects_home_through_symlink_aliases(self):
        code = span('# Validate SANDY_SCREENSHOT_DIR.', '# D3 (2.0.0): SANDY_FEATURES_DIR')
        code = code[code.index('\nif ['):]
        alias = self.root / 'home-alias'
        alias.symlink_to(self.home, target_is_directory=True)
        for home in (self.home, alias):
            for screenshot in (self.home, alias, Path('/')):
                with self.subTest(home=home, screenshot=screenshot):
                    run = self.run_source(code, HOME=str(home), SANDY_SCREENSHOT_DIR=str(screenshot))
                    self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
                    self.assertIn('too broad', run.stderr)
            specific = alias / 'screenshots'
            specific.mkdir(exist_ok=True)
            run = self.run_source(code + '\nprintf "%s" "$SANDY_SCREENSHOT_DIR"',
                                  HOME=str(home), SANDY_SCREENSHOT_DIR=str(specific))
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout, str(specific.resolve()))

    def test_python_version_drives_the_real_startup_install(self):
        code = span('# Auto-install Python version if .python-version exists (uv is idempotent & fast)',
                    '# Workspace .venv overlay. When SANDY_VENV_OVERLAY_ACTIVE=1, sandy has bind-')
        bindir = self.root / 'bin'
        bindir.mkdir()
        uv = bindir / 'uv'
        uv.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$UV_CALLS"\nexit "${UV_EXIT:-0}"\n')
        uv.chmod(0o755)
        calls = self.root / 'uv-calls'
        env = {'PATH': str(bindir) + os.pathsep + os.environ['PATH'],
               'WORKSPACE': str(self.ws), 'UV_CALLS': str(calls)}
        run = self.run_source(code, **env)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse(calls.exists())
        (self.ws / '.python-version').write_text(' 3.12\n')
        run = self.run_source(code, **env)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(calls.read_text(), 'python install 3.12\n')
        self.assertIn('Python 3.12 ready', run.stdout)
        run = self.run_source(code, UV_EXIT='1', **env)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn('ready', run.stdout)
        calls.unlink()
        (self.ws / '.python-version').write_text('\n')
        self.assertEqual(self.run_source(code, **env).returncode, 0)
        self.assertFalse(calls.exists())

    def cleanup_code(self):
        body = span("# Pre-existing-debris auto-cleanup:", "# Protected dirs: existence-gated.")
        return function("_sandy_protected_dirs") + "_sandy_is_git_repo=false" + body.split("_sandy_is_git_repo=false", 1)[1]

    def test_cleanup_non_git_empty_and_populated_directories(self):
        code = self.cleanup_code()
        (self.ws / ".vscode").mkdir()
        (self.ws / ".idea").mkdir()
        (self.ws / ".idea/keep").write_text("keep")
        (self.ws / "unrelated").mkdir()
        run = self.run_source(code)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse((self.ws / ".vscode").exists())
        self.assertEqual((self.ws / ".idea/keep").read_text(), "keep")
        self.assertTrue((self.ws / "unrelated").is_dir())
        # Mutation proves that the assertion above depends on the real rmdir.
        (self.ws / ".vscode").mkdir()
        mutant = code.replace('if rmdir "$_p"', 'if false "$_p"')
        self.assertNotEqual(mutant, code)
        self.run_source(mutant)
        self.assertTrue((self.ws / ".vscode").exists())

    def test_cleanup_git_preserves_tracked_and_hidden_content(self):
        subprocess.run(["git", "init", "-q", str(self.ws)], check=True)
        (self.ws / ".vscode").mkdir()
        (self.ws / ".vscode/tracked").write_text("tracked")
        subprocess.run(["git", "-C", str(self.ws), "add", ".vscode/tracked"], check=True)
        (self.ws / ".idea").mkdir()
        (self.ws / ".idea/.hidden").write_text("keep")
        (self.ws / ".devcontainer").mkdir()
        run = self.run_source(self.cleanup_code())
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue((self.ws / ".vscode/tracked").exists())
        self.assertTrue((self.ws / ".idea/.hidden").exists())
        self.assertFalse((self.ws / ".devcontainer").exists())

    def test_symlinks_use_the_production_resolver(self):
        names = ("_sandy_protected_files", "_sandy_protected_git_files", "_sandy_protected_dirs",
                 "_sandy_is_protected_rel", "_sandy_resolve_symlinks")
        code = "".join(function(name) for name in names)
        code += '\n_sandy_resolve_symlinks\nprintf "%s\\n" "${SYMLINK_HOST_PATHS[@]+"${SYMLINK_HOST_PATHS[@]}"}"\n'
        (self.home / "outside").mkdir()
        (self.ws / "internal").mkdir()
        (self.ws / "safe").symlink_to(self.ws / "internal")
        run = self.run_source(code)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn(str(self.ws / "internal"), run.stdout)
        (self.ws / "escape").symlink_to(self.home / "outside")
        run = self.run_source(code)
        self.assertEqual(run.returncode, 1)
        self.assertIn("Dangerous symlinks need interactive approval", run.stderr)
        self.assertIn(str(self.home / "outside"), run.stderr)
        (self.sb / ".sandy-approved-symlinks.list").write_text("escape -> " + str(self.home / "outside") + "\n")
        run = self.run_source(code)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn(str(self.home / "outside"), run.stdout)

    def settings_code(self):
        staging = span('_sandy_launch_id=""   # minted once per launch, right after the sandbox dir exists\n',
                       '\njson_merge() {')
        seed = 'if _sandy_agent_has claude; then\n    SEED_SETTINGS="$SANDBOX_DIR/claude/settings.json"' + span(
            'if _sandy_agent_has claude; then\n    SEED_SETTINGS="$SANDBOX_DIR/claude/settings.json"',
            'fi  # end Claude settings seeding') + 'fi\n'
        return (staging + '\n_sandy_launch_id=T1\n_sandy_agent_has() { return 0; }\n'
                + seed + '\n_sandy_launch_apply_staged "$SANDBOX_DIR"\n')

    def test_current_project_path_preserves_unrelated_history(self):
        code = '_sandy_has_claude() { return 0; }\n' + span(
            '# Ensure project-level config dirs exist (Claude only — Gemini uses .gemini/)',
            '# Plugin marketplace configuration is merged into settings.json host-side at')
        workspace = self.ws / 'project.with_under score'
        workspace.mkdir()
        old = self.home / '.claude/projects/old-project/history.jsonl'
        old.parent.mkdir(parents=True)
        old.write_text('history\n')
        run = self.run_source(code, WORKSPACE=str(workspace))
        self.assertEqual(run.returncode, 0, run.stderr)
        normalized = re.sub('[^a-zA-Z0-9]', '-', str(workspace))
        self.assertTrue((self.home / '.claude/projects' / normalized).is_dir())
        self.assertTrue((workspace / '.claude').is_dir())
        self.assertEqual(old.read_text(), 'history\n')

    def test_multi_agent_headless_dispatches_to_first_agent(self):
        block = span('# --- Multi-agent launch (2-4 panes) ---',
                     '    _agent_names="$(IFS=\' + \'; echo "${_SANDY_AGENTS[*]}")"')
        prefix = ('_sandy_is_headless=true\nsandy_log() { :; }\n'
                  '_sandy_build_agent_cmd() { printf "printf ROUTED:%s" "$1"; }\n')
        for agents in ('claude codex', 'gemini claude codex', 'codex gemini opencode grok'):
            code = prefix + '_SANDY_AGENTS=(' + agents + ')\n' + block
            run = self.run_source(code)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout, 'ROUTED:' + agents.split()[0])
            mutant = code.replace('_SANDY_AGENTS[0]', '_SANDY_AGENTS[1]')
            self.assertNotEqual(self.run_source(mutant).stdout, run.stdout)

    def test_real_settings_seed_preserves_plugins_and_false_on_both_parsers(self):
        for parser in ("node", "jq"):
            with self.subTest(parser=parser):
                if not shutil.which(parser):
                    self.skipTest("requires " + parser)
                # Use an explicit tool directory to force each production branch.
                bindir = self.root / ("bin-" + parser)
                bindir.mkdir()
                for tool in ("bash", parser, "cat", "rm", "mv", "mktemp", "cmp", "diff", "readlink"):
                    executable = shutil.which(tool)
                    if executable:
                        (bindir / tool).symlink_to(executable)
                host = self.home / ".claude/settings.json"
                target = self.sb / "claude/settings.json"
                target.unlink(missing_ok=True)
                host.write_text(json.dumps({"flavor": "A", "skipAutoPermissionPrompt": False}))
                code = self.settings_code()
                run = self.run_source(code, PATH=str(bindir))
                self.assertEqual(run.returncode, 0, run.stderr)
                first = json.loads(target.read_text())
                self.assertEqual(first["flavor"], "A")
                self.assertIs(first["skipAutoPermissionPrompt"], False)
                first["enabledPlugins"] = {"fixture-plugin": True}
                target.write_text(json.dumps(first))
                host.write_text(json.dumps({"flavor": "B"}))
                run = self.run_source(code, PATH=str(bindir), SANDBOX_IS_NEW="false")
                self.assertEqual(run.returncode, 0, run.stderr)
                second = json.loads(target.read_text())
                self.assertEqual(second["flavor"], "B")
                self.assertTrue(second["enabledPlugins"]["fixture-plugin"])
                self.assertIs(second["skipAutoPermissionPrompt"], True)


if __name__ == "__main__":
    unittest.main()
