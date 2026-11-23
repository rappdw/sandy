"""Regression tests for false passes in the shell harnesses; no Docker needed."""
import os
import contextlib
import io
import json
import pty
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import unittest
from unittest import mock

import suite_runner
import test_container as container_tests
from log_paths import MARKER, start_run

from result_checks import acceptance_ok, answer_ok, launch_diagnostic, probe_ok, selection_errors

ROOT = Path(__file__).resolve().parent.parent


class CompletionEvidence(unittest.TestCase):
    def test_integration_isolates_state_preserves_auth_and_cleans_up_on_failure(self):
        source = (ROOT / 'test/run-integration-tests.sh').read_text()
        bootstrap = source[:source.index('# --- Preflight ---')]
        credentials = source[source.index('# Detect available credentials.'):source.index(
            '[ -n "${OPENAI_API_KEY:-}" ] && HAS_OPENAI_API_KEY=true')]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            home = root / 'home'
            host_state = home / '.sandy'
            host_state.mkdir(parents=True)
            (host_state / '.secrets').write_text('OPENAI_API_KEY=from-file\nGEMINI_API_KEY=from-default-home\n')
            custom_state = root / 'custom-state'
            custom_state.mkdir()
            for state in (host_state, custom_state):
                (state / 'features/amap.rollout-backups/old').mkdir(parents=True)
                (state / 'sandboxes/real-project').mkdir(parents=True)
                (state / 'config').write_text('SANDY_AGENT=invalid-host-setting\n')
                (state / '.build_hash_claude').write_text('cached-build')
                (state / 'Dockerfile').write_text('cached-dockerfile')
            (custom_state / '.secrets').write_text('OPENAI_API_KEY=from-file\nGEMINI_API_KEY=from-custom-home\n')
            (home / '.codex').mkdir()
            (home / '.codex/auth.json').write_text('{"fixture": true}')
            for configured_state in (None, custom_state):
                with self.subTest(custom_home=configured_state is not None):
                    state = configured_state or host_state
                    before = {str(p): p.read_bytes() for p in home.rglob('*') if p.is_file()}
                    before.update({str(p): p.read_bytes() for p in custom_state.rglob('*') if p.is_file()})
                    env = {'PATH': os.environ['PATH'], 'HOME': str(home), 'TMPDIR': str(root),
                           'OPENAI_API_KEY': 'from-environment', 'SANDY_INTEG_LOG_DIR': str(root / 'logs')}
                    if configured_state:
                        env['SANDY_HOME'] = str(configured_state)
                    program = bootstrap + '\nsweep_leaked_sandy_networks() { :; }\n' + credentials + '''
test "$HOME" = "$1"
test "$SANDY_HOME" != "$2"
test "$OPENAI_API_KEY" = from-environment
test "$GEMINI_API_KEY" = "$3"
test -f "$HOME/.codex/auth.json"
test "$(cat "$SANDY_HOME/.build_hash_claude")" = cached-build
test "$(cat "$SANDY_HOME/Dockerfile")" = cached-dockerfile
test ! -e "$SANDY_HOME/features"
test ! -e "$SANDY_HOME/sandboxes"
test ! -e "$SANDY_HOME/config"
test ! -e "$SANDY_HOME/.secrets"
printf '%s' "$SANDY_HOME" > "$4"
mkdir -p "$SANDY_HOME/sandboxes/fixture"
cd "$HOME"
_run_provenance
exit 7
'''
                    expected_key = 'from-custom-home' if configured_state else 'from-default-home'
                    run = subprocess.run(['bash', '-c', program, 'test/run-integration-tests.sh',
                                          str(home), str(state), expected_key, str(root / 'isolated-path')],
                                         cwd=ROOT, env=env, capture_output=True, text=True, timeout=15)
                    self.assertEqual(run.returncode, 7, run.stdout + run.stderr)
                    isolated = Path((root / 'isolated-path').read_text())
                    self.assertFalse(isolated.exists(), 'fixture state must be removed even after a failure')
                    for name, data in before.items():
                        self.assertEqual(Path(name).read_bytes(), data, name)
                    self.assertTrue((state / 'features/amap.rollout-backups/old').is_dir())
                    self.assertTrue((state / 'sandboxes/real-project').is_dir())
                    sha = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', '--short', 'HEAD'], text=True).strip()
                    self.assertIn('commit ' + sha, run.stdout)
                    self.assertNotIn('commit ?', run.stdout)

    def test_launch_diagnostics_distinguish_host_state_from_provider_timeout(self):
        manifest = '[sandy] A feature manifest could not be applied; no feature was mounted.'
        capacity = 'Attempt 2 failed with status 503: This model is currently experiencing high demand.'
        self.assertIn('feature manifest', launch_diagnostic(1, manifest))
        self.assertIn('HTTP 503', launch_diagnostic(124, capacity))
        self.assertIn('timed out', launch_diagnostic(124, ''))
        self.assertNotIn('503', launch_diagnostic(124, 'generic fetch failed'))
        self.assertNotIn('private-token', launch_diagnostic(1, 'private-token'))
        self.assertEqual(launch_diagnostic(0, capacity), '')
        self.assertFalse(answer_ok(124, 'banana', capacity))
        oauth = launch_diagnostic(1, 'IneligibleTierError UNSUPPORTED_CLIENT EROFS')
        self.assertIn('rejected by the provider', oauth)
        self.assertIn('read-only mount', oauth)
        self.assertIn('Google model', launch_diagnostic(1, 'Google Generative AI API key is missing'))

    def test_opencode_smoke_pairs_model_and_credential_without_writing_secrets(self):
        source = (ROOT / 'test/run-integration-tests.sh').read_text()
        function = re.search(r'^_configure_opencode_smoke\(\) \{\n.*?^\}', source, re.M | re.S)
        self.assertIsNotNone(function)
        cases = (
            ({'ANTHROPIC_API_KEY': 'fixture-anthropic', 'GEMINI_API_KEY': 'fixture-google'},
             'anthropic/claude-haiku-4-5'),
            ({'OPENAI_API_KEY': 'fixture-openai'}, 'openai/gpt-4.1-mini'),
            ({'GEMINI_API_KEY': 'fixture-google'}, 'google/gemini-2.5-flash'),
            ({'ANTHROPIC_API_KEY': 'fixture-anthropic', 'GEMINI_API_KEY': 'fixture-google',
              'OPENCODE_MODEL': 'google/custom-model'}, 'google/custom-model'),
            ({}, ''),  # OAuth-only users retain their own provider/model choice.
        )
        for credentials, model in cases:
            with self.subTest(model=model), tempfile.TemporaryDirectory() as directory:
                run = subprocess.run(['bash', '-c', 'set -euo pipefail\n' + function[0]
                                      + '\n_configure_opencode_smoke\n'], cwd=directory,
                                     env={'PATH': os.environ['PATH'], **credentials},
                                     capture_output=True, text=True, timeout=10)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(run.stdout.strip(), model)
                text = (Path(directory) / 'opencode.json').read_text()
                config = json.loads(text)
                self.assertEqual(config.get('model', ''), model)
                if model.startswith('google/'):
                    self.assertEqual(config['provider']['google']['options']['apiKey'], '{env:GEMINI_API_KEY}')
                for key, value in credentials.items():
                    if key.endswith('_API_KEY'):
                        self.assertNotIn(value, text)

    def test_overall_result_cannot_hide_a_failed_or_skipped_group(self):
        cases = ((['passed', 'failed', 'partial', 'passed', 'passed'], 1, 'SUITE FAILED'),
                 (['passed', 'partial'], 0, 'SUITE COMPLETE WITH SKIPS'),
                 (['passed', 'passed'], 0, 'SUITE PASSED'),
                 (['skipped'], 1, 'SUITE FAILED'))
        for states, expected_rc, expected_status in cases:
            with self.subTest(states=states):
                results = [{'group': 'group' + str(index), 'state': state, 'seconds': 1,
                            'skips': int(state in ('partial', 'skipped')), 'log': 'group' + str(index) + '.log'}
                           for index, state in enumerate(states)]
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(suite_runner.finish_suite(results), expected_rc)
                self.assertIn(expected_status, output.getvalue())
                if 'failed' in states:
                    self.assertIn('failed groups: group1', output.getvalue())
                    self.assertIn('group1 failure details: group1.log', output.getvalue())
                    self.assertNotIn('SUITE PASSED', output.getvalue())

    def test_contract_probes_do_not_inherit_an_interactive_terminal(self):
        master, slave = pty.openpty()
        try:
            program = ('import os; from test_production_contracts import ProductionContracts\n'
                       'assert os.isatty(0), "regression requires a real terminal on parent stdin"\n'
                       'case = ProductionContracts(); case.setUp()\n'
                       'try:\n'
                       '    run = case.run_source("test ! -t 0 && ! read -r line")\n'
                       '    assert run.returncode == 0, run.stderr\n'
                       'finally:\n'
                       '    case.doCleanups()\n')
            run = subprocess.run([suite_runner.sys.executable, '-c', program],
                                 cwd=ROOT / 'test', stdin=slave, capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        finally:
            os.close(slave)
            os.close(master)

    def test_console_identifies_tests_without_dumping_failure_source(self):
        lines = ['test_example (__main__.Contracts.test_example) ... ERROR\n',
                 '=' * 70 + '\n', 'ERROR: test_example (__main__.Contracts.test_example)\n',
                 'Traceback (most recent call last):\n', 'subprocess.TimeoutExpired: huge shell source\n',
                 'Ran 1 test in 20s\n', 'FAILED (errors=1)\n']
        for verbose in (False, True):
            visible = []
            traceback = False
            for line in lines:
                show, traceback = suite_runner.show_output(line, 'contracts', verbose, traceback)
                if show:
                    visible.append(line)
            output = ''.join(visible)
            self.assertIn('test_example', output)
            self.assertIn('FAILED (errors=1)', output)
            self.assertEqual('huge shell source' in output, verbose)

    def test_integration_console_log_preserves_both_streams_on_failure(self):
        source = (ROOT / 'test/run-integration-tests.sh').read_text()
        start = source.index('SANDY_INTEG_LOG_DIR="$(python3')
        block = source[start:source.index('# Identical Linux/macOS', start)]
        with tempfile.TemporaryDirectory() as directory:
            env = {'PATH': os.environ['PATH'], 'HOME': directory,
                   '_INT_SELF_DIR': str(ROOT / 'test'), 'SANDY_INTEG_LOG_DIR': directory}
            run = subprocess.run(['bash', '-c', 'set -euo pipefail\n' + block
                                  + '\nprintf "stdout evidence\\n"\nprintf "stderr evidence\\n" >&2\nexit 7\n'],
                                 env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 7, run.stderr)
            log = (Path(directory) / 'latest/integration.log').read_text()
            self.assertIn('stdout evidence', log)
            self.assertIn('stderr evidence', log)

    def test_log_rotation_retains_three_runs_and_ignores_unmanaged_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'logs'
            root.mkdir()
            unrelated = root / 'run-not-ours'
            unrelated.mkdir()
            (unrelated / 'keep').write_text('unrelated')
            outside = Path(directory) / 'outside'
            outside.mkdir()
            (outside / MARKER).write_text('{}')
            (root / 'run-symlink').symlink_to(outside, target_is_directory=True)
            runs = []
            for suite in ('suite', 'integration', 'suite', 'suite'):
                run = start_run(suite, root)
                (run / 'output.log').write_text(suite)
                runs.append(run)
            self.assertFalse(runs[0].exists())
            for run in runs[1:]:
                self.assertTrue((run / 'output.log').is_file())
            self.assertEqual((root / 'latest').resolve(), runs[-1])
            self.assertEqual(os.readlink(root / 'latest'), runs[-1].name)
            self.assertEqual((unrelated / 'keep').read_text(), 'unrelated')
            self.assertTrue((outside / MARKER).exists())

    def test_portable_timeout_preserves_failure_and_reports_timeout(self):
        helper = str(ROOT / 'test/result_checks.py')
        for seconds, code, expected in (('2', 'raise SystemExit(6)', 6),
                                         ('0.05', 'import time; time.sleep(5)', 124)):
            run = subprocess.run([suite_runner.sys.executable, helper, 'timeout', seconds,
                                  suite_runner.sys.executable, '-c', code], capture_output=True, timeout=12)
            self.assertEqual(run.returncode, expected, run.stderr)

    def test_group_isolation_and_failure_reporting(self):
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory) / 'logs'
            physical = Path(directory) / 'physical'
            physical.mkdir()
            alias = Path(directory) / 'alias'
            alias.symlink_to(physical, target_is_directory=True)
            program = ('import os, subprocess; from pathlib import Path; '
                       'assert not os.isatty(0); assert os.read(0, 1) == b""; '
                       'assert os.environ["HOME"] != ' + repr(str(Path.home())) + '; '
                       'assert Path(os.environ["HOME"]) == Path(os.environ["HOME"]).resolve(); '
                       'assert "FAKE_PROVIDER_TOKEN" not in os.environ; '
                       'r=subprocess.run(["docker", "info"],capture_output=True,text=True); '
                       'assert r.returncode == 1 and "disabled" in r.stderr; print("fixture passed")')
            groups = {'host': [suite_runner.sys.executable, '-c', program],
                      'contracts': [suite_runner.sys.executable, '-c', 'print("failure evidence"); raise SystemExit(6)']}
            with mock.patch.object(suite_runner, 'GROUPS', groups), \
                 mock.patch('sys.argv', ['runner', '--only', 'host,contracts', '--log-dir', str(logs)]), \
                 mock.patch.object(suite_runner.tempfile, 'tempdir', str(alias)), \
                 mock.patch.dict(os.environ, {'FAKE_PROVIDER_TOKEN': 'must-not-leak'}), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(suite_runner.main(), 1)
            run_logs = logs / 'latest'
            result = json.loads((run_logs / 'results.json').read_text())
            self.assertEqual([row['state'] for row in result], ['passed', 'failed'])
            self.assertEqual([row['exit'] for row in result], [0, 6])
            self.assertIn('failure evidence', (run_logs / 'contracts.log').read_text())

    def test_every_command_of_a_group_runs_and_counts(self):
        # A group may be a list of commands. A skip in any of them must make the
        # group partial with its reason in the console, and a failure must fail
        # the group even when a later command passes, which still runs.
        skipping = ('import unittest\nclass T(unittest.TestCase):\n'
                    '    def test_x(self): self.skipTest("needs a tool")\n'
                    'unittest.main(argv=["t", "-v"])\n')
        cases = (  # (name, first, second, suite exit, group state, group exit, skips, text in log)
            ('skip-in-second', 'print("first ran")', skipping, 0, 'partial', 0, 1, 'first ran'),
            ('skip-in-both', skipping, skipping, 0, 'partial', 0, 2, "skipped 'needs a tool'"),
            ('fail-then-pass', 'raise SystemExit(4)', 'print("second ran")', 1, 'failed', 4, 0, 'second ran'),
            # the FIRST failure decides the exit: not the last one, not the larger one
            ('fail-4-then-3', 'raise SystemExit(4)', 'raise SystemExit(3)', 1, 'failed', 4, 0, ''),
            ('fail-3-then-4', 'raise SystemExit(3)', 'raise SystemExit(4)', 1, 'failed', 3, 0, ''),
        )
        for name, first, second, suite_rc, state, group_rc, skips, text in cases:
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                logs = Path(directory) / 'logs'
                groups = {'contracts': [[suite_runner.sys.executable, '-c', first],
                                        [suite_runner.sys.executable, '-c', second]]}
                console = io.StringIO()
                with mock.patch.object(suite_runner, 'GROUPS', groups), \
                     mock.patch('sys.argv', ['runner', '--only', 'contracts', '--log-dir', str(logs)]), \
                     contextlib.redirect_stdout(console):
                    self.assertEqual(suite_runner.main(), suite_rc)
                row, = json.loads((logs / 'latest' / 'results.json').read_text())
                self.assertEqual((row['state'], row['exit'], row['skips']), (state, group_rc, skips))
                self.assertIn(text, (logs / 'latest' / 'contracts.log').read_text())
                if skips:
                    self.assertIn("skipped 'needs a tool'", console.getvalue())

    def test_every_python_test_file_belongs_to_a_group(self):
        # A test file no group runs is coverage that exists but does not run.
        named = {Path(part).name for spec in suite_runner.GROUPS.values()
                 for command in (spec if isinstance(spec[0], list) else [spec]) for part in command}
        files = {path.name for path in (ROOT / 'test').glob('test_*.py')}
        self.assertTrue(files, 'no test files found')
        self.assertEqual(files - named, set())

    def test_container_fixture_is_a_usable_git_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            fixture = container_tests.ContainerContracts()
            fixture.home = root / 'home'
            fixture.home.mkdir()
            fixture.logs = root / 'logs'
            fixture.logs.mkdir()
            fixture.env = {'PATH': os.environ['PATH'], 'HOME': str(fixture.home),
                           'SANDY_HOME': str(fixture.home / '.sandy')}
            project, protected = fixture.project('project')
            for args in (['git', 'symbolic-ref', '-q', 'HEAD'], ['git', 'status', '--porcelain']):
                run = subprocess.run(args, cwd=project, env=fixture.env, capture_output=True, text=True, timeout=10)
                self.assertEqual(run.returncode, 0, run.stderr)
            for relative in protected:
                self.assertTrue((project / relative).stat().st_mode & 0o200)

    def test_stale_image_does_not_hide_a_failed_build(self):
        source = (ROOT / 'test/run-integration-tests.sh').read_text()
        match = re.search(r'^ensure_image_built\(\) \{\n.*?^\}', source, re.M | re.S)
        timeout_function = re.search(r'^timeout\(\) \{\n.*?^\}', source, re.M | re.S)
        self.assertIsNotNone(match)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            builder = root / 'builder'
            builder.write_text('#!/bin/sh\necho broken build\nexit 6\n')
            builder.chmod(0o755)
            program = ('set -euo pipefail\nTEST_DIRS=()\ninfo() { :; }; warn() { echo "$*" >&2; }\n'
                       'docker() { return 0; }\n' + timeout_function[0] + '\n' + match[0]
                       + '\nensure_image_built claude existing-image\n')
            env = {'PATH': os.environ['PATH'], 'HOME': directory, 'TMPDIR': directory,
                   'SANDY_INTEG_LOG_DIR': directory, 'SANDY_SCRIPT': str(builder), '_INT_SELF_DIR': str(ROOT / 'test')}
            run = subprocess.run(['bash', '-c', program], env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 6, run.stderr)
            self.assertIn('Build validation failed', run.stderr)
            self.assertEqual(next(root.glob('build.*')).read_text(), 'broken build\n')

    def test_bad_selection_cannot_produce_a_green_empty_run(self):
        source = (ROOT / 'test/run-integration-tests.sh').read_text()
        self.assertFalse(selection_errors(source, '7,13b', '19,20,21'))
        self.assertFalse(selection_errors(source, '', ''))
        for only, skip in (('999', ''), ('7', '7'), ('7,', ''), ('', '99')):
            self.assertTrue(selection_errors(source, only, skip))

    def test_answer_requires_success_and_an_answer_line(self):
        for text in ("", "Authentication failed", "reply with exactly one word: cherry",
                     "error: expected cherry", "cherry was not returned"):
            self.assertFalse(answer_ok(0, "cherry", text), text)
        for status in (1, 6, 124, 125, 126, 127, 137):
            self.assertFalse(answer_ok(status, "cherry", "cherry\n"))
        self.assertTrue(answer_ok(0, "cherry", "model metadata\n\x1b[32mCherry.\x1b[0m\n"))

    def test_answers_ignore_terminal_controls_but_not_prompt_or_error_text(self):
        for terminator in ('\x07', '\x1b\\'):
            palette = '\x1b]4;4;rgb:61/8f/ff' + terminator
            for word in ('banana', 'cherry', 'first', 'second'):
                output = '[sandy] Launching sandbox...\n\n' + palette + word + '\n'
                self.assertTrue(answer_ok(0, word, output))
                self.assertFalse(answer_ok(1, word, output))
                self.assertFalse(answer_ok(124, word, output))
                self.assertFalse(answer_ok(0, word, palette + 'reply one word: ' + word))
                self.assertFalse(answer_ok(0, word, palette + 'error: expected ' + word))
                # An answer hidden inside a title/control payload is not output.
                self.assertFalse(answer_ok(0, word, '\x1b]0;\n' + word + '\n' + terminator))
            recovered = palette + 'first\nAttempt 1 failed with status 503: UNAVAILABLE\n'
            self.assertTrue(answer_ok(0, 'first', recovered))
        linked = '\x1b]8;;https://example.com\x1b\\\x1b[32mcherry\x1b[0m\x1b]8;;\x1b\\\n'
        self.assertTrue(answer_ok(0, 'cherry', linked))

    def test_isolation_requires_a_completed_probe(self):
        for status, text in ((125, "pull failed"), (127, "command not found"),
                             (0, ""), (1, "BLOCKED"), (0, "REACHABLE")):
            self.assertFalse(probe_ok(status, text, "BLOCKED"))
        self.assertTrue(probe_ok(0, "BLOCKED\n", "BLOCKED"))
        self.assertFalse(probe_ok(0, "BLOCKED\nBLOCKED\n", "BLOCKED"))
        self.assertFalse(probe_ok(0, "SANDY_UDP_BLOCKED\nSANDY_UDP_REACHABLE\n", "SANDY_UDP_BLOCKED"))

    def test_acceptance_requires_assertions_and_completion(self):
        for status, text in ((0, ""), (0, "RESULT: 0 passed, 0 failed"),
                             (0, "RESULT: 3 passed, 1 failed"),
                             (1, "RESULT: 3 passed, 0 failed"),
                             (0, "RESULT: 3 passed, 0 failed\nRESULT: 3 passed, 0 failed")):
            self.assertFalse(acceptance_ok(status, text))
        self.assertTrue(acceptance_ok(0, "RESULT: 3 passed, 0 failed (1 skipped)\n"))

    def test_real_headless_runner_preserves_exit_and_streams(self):
        text = (ROOT / "test/run-integration-tests.sh").read_text()
        match = re.search(r"^run_sandy_headless\(\) \{\n.*?^\}", text, re.M | re.S)
        timeout_function = re.search(r'^timeout\(\) \{\n.*?^\}', text, re.M | re.S)
        self.assertIsNotNone(match)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child = root / "agent"
            child.write_text('#!/bin/bash\nprintf "cherry\\n"\nprintf "diagnostic\\n" >&2\nexit "$CHILD_RC"\n')
            child.chmod(0o755)
            program = ('set -euo pipefail\n' + timeout_function[0] + '\n' + match[0]
                       + '\nreap_test_containers() { return 0; }\n'
                       + 'VERBOSE=0\nrun_sandy_headless CHILD_RC="$1" -- -p test\n')
            for status in (0, 6, 124, 127):
                env = {"PATH": os.environ["PATH"], "HOME": directory,
                       "SANDY_SCRIPT": str(child), "SANDY_INTEG_LOG_DIR": directory, '_INT_SELF_DIR': str(ROOT / 'test')}
                run = subprocess.run(["bash", "-c", program, "test", str(status)],
                                     env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(run.returncode, status, run.stderr)
                self.assertIn("cherry", run.stdout)
                self.assertIn("diagnostic", run.stdout)
            logs = list(root.glob("launch.*"))
            self.assertEqual(len(logs), 4)
            for log in logs:
                self.assertEqual((log / "stdout").read_text(), "cherry\n")
                self.assertEqual((log / "stderr").read_text(), "diagnostic\n")
                self.assertTrue((log / "status").read_text().strip().isdigit())


class HostSections(unittest.TestCase):
    """The host group, one section per process (suite_runner --jobs N, --sections)."""

    REAL = ROOT / 'test/run-tests.sh'
    # Asked once, before any test replaces bash_major with a stand-in.
    BASH_MAJOR = suite_runner.bash_major('bash')

    def fixture(self, directory, sections):
        """A small host script: the real file's helpers and its real epilogue around these sections."""
        real = self.REAL.read_text().split('\n')
        helpers = real[:real.index('}', real.index('_run_provenance() {')) + 1]
        epilogue = real[max(index for index, line in enumerate(real) if line == '_test_section_close'):]
        path = Path(directory).resolve() / 'host-fixture.sh'
        path.write_text('\n'.join(helpers + sections.strip('\n').split('\n') + epilogue))
        return path

    def run_host(self, script, *arguments, env=None):
        if self.BASH_MAJOR < 5:
            self.skipTest('the host group needs bash 5 or newer on PATH')
        logs = script.parent / 'logs'
        console = io.StringIO()
        with mock.patch.object(suite_runner, 'GROUPS', {'host': ['bash', str(script)]}), \
             mock.patch('sys.argv', ['runner', '--only', 'host', '--log-dir', str(logs)] + list(arguments)), \
             mock.patch.dict(os.environ, env or {}), contextlib.redirect_stdout(console):
            code = suite_runner.main()
        return code, self.plain(console.getvalue()), logs / 'latest'

    @staticmethod
    def plain(text):
        return re.sub(suite_runner.ESCAPES, '', text)

    @staticmethod
    def headers(text):
        return [int(number) for number in re.findall(r'^\((\d+) of \d+\) ', text, re.M)]

    def assert_gone(self, pid):
        for _ in range(100):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            # A killed process is a zombie until its new parent collects it.
            stat = Path('/proc/{}/stat'.format(pid))
            if stat.exists() and stat.read_text().rsplit(')', 1)[-1].split()[0] == 'Z':
                return
            time.sleep(0.05)
        self.fail('process {} is still running'.format(pid))

    def test_splitter_agrees_with_the_scripts_own_section_count(self):
        source = self.REAL.read_text()
        pattern = re.search(r"_TEST_SECTION_TOTAL=\"\$\(grep -cE '([^']+)' ", source)
        self.assertIsNotNone(pattern, 'run-tests.sh no longer counts its sections with grep -cE')
        own = int(subprocess.check_output(['grep', '-cE', pattern[1], str(self.REAL)], text=True))
        host = suite_runner.HostScript(self.REAL)
        self.assertGreater(own, 200)
        # A header the file counts and the splitter misses (an indented one) would
        # run inside its neighbour and print a position the runner knows nothing of.
        self.assertEqual(len(host.sections), own)
        self.assertEqual([section.position for section in host.sections], list(range(1, own + 1)))
        for section, following in zip(host.sections, host.sections[1:]):
            self.assertEqual(section.end, following.start)
        self.assertEqual(host.sections[-1].end, host.epilogue)
        self.assertEqual(host.lines[host.epilogue], '_test_section_close')
        self.assertNotIn('_test_section_close', host.lines[host.epilogue + 1:])
        for section in host.sections:
            self.assertRegex(section.label, r'^§?[0-9]+[a-z0-9]*$', section.title)

    def test_generated_script_keeps_every_line_at_its_own_number(self):
        with tempfile.TemporaryDirectory() as directory:
            script = self.fixture(directory, 'section "§1: first"\ncheck "one" true\n'
                                             'section "§2: second"\n# a comment of the second\ncheck "two" true\n'
                                             'info "3. third \\$HOME \\"quoted\\""\ncheck "three" true\n')
            host = suite_runner.HostScript(script)
            self.assertEqual([(section.label, section.title) for section in host.sections],
                             [('§1', '§1: first'), ('§2', '§2: second'), ('3', '3. third $HOME "quoted"')])
            second = host.sections[1]
            copy = host.script(second).split('\n')
            self.assertEqual(len(copy), len(host.lines))
            self.assertEqual(copy[second.start], 'section "§2: second"')
            self.assertEqual(copy[second.start + 1], '# a comment of the second')
            for index, line in enumerate(host.lines):
                own = index < host.sections[0].start or index >= host.epilogue or second.start <= index < second.end
                self.assertEqual(copy[index], line if own else '', index)
            summary = host.script().split('\n')
            self.assertEqual(summary[:host.sections[0].start], host.lines[:host.sections[0].start])
            self.assertEqual(set(summary[host.sections[0].start:host.epilogue]), {''})
            self.assertEqual(summary[host.epilogue:], host.lines[host.epilogue:])

    def test_one_process_and_one_per_section_report_the_same(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory).resolve() / 'host-fixture.sh')
            script = self.fixture(directory, 'section "§1: the script path"\n'
                                             'check "\\$0 is the real script" test "$0" = "' + path + '"\n'
                                             'check "skips are counted" bash -c "exit 77"\n'
                                             'info "2. a numbered section"\ncheck "second" true\n'
                                             'section "§3: no checks"\n'
                                             'section "§4: last"\ncheck "fourth" true\n')
            outputs = []
            for jobs in ('1', '2'):
                code, console, logs = self.run_host(script, '--jobs', jobs)
                self.assertEqual(code, 0, console)
                log = self.plain((logs / 'host.log').read_text())
                self.assertEqual(self.headers(log), [1, 2, 3, 4])
                self.assertIn('Host group: 3 checks passed.', log)
                self.assertIn('Host group: 1 check set(s) skipped', log)
                self.assertEqual(len(re.findall(r'host group complete .* commit ', log)), 1)
                self.assertIn('host: PARTIAL', console)
                row, = json.loads((logs / 'results.json').read_text())
                self.assertEqual((row['state'], row['exit'], row['skips']), ('partial', 0, 1))
                self.assertEqual('Host sections:' in console, jobs == '2')
                # What a reader compares: headers, marks, TIMING lines and the summary.
                outputs.append([re.sub(r'see \S+', 'see LOG', re.sub(r'TIMING \d+s', 'TIMING Ns', line))
                                for line in log.split('\n')
                                if re.match(r'\(\d+ of|\s+[✓✗–] |TIMING |Host group:', line)])
                # A passing section leaves no script behind.
                self.assertEqual(list((logs / 'host').glob('*.sh')), [])
            self.assertEqual(outputs[0], outputs[1])
            self.assertEqual(len(outputs[0]), 4 + 4 + 4 + 2, outputs[0])
            # The last run's times are remembered beside the runs, by title.
            times = json.loads((script.parent / 'logs' / suite_runner.TIMES_FILE).read_text())['seconds']
            self.assertEqual(list(times), ['§1: the script path', '2. a numbered section', '§3: no checks', '§4: last'])

    def test_failing_section_fails_the_run_and_names_the_check(self):
        with tempfile.TemporaryDirectory() as directory:
            left = Path(directory).resolve() / 'left-running'
            script = self.fixture(directory, 'section "§1: passes"\ncheck "fine" true\n'
                                             'sleep 300 >/dev/null 2>&1 &\necho $! > ' + str(left) + '\n'
                                             'section "§2: fails"\ncheck "before" true\n'
                                             'check "the deliberately failing check" bash -c "echo why it failed; exit 3"\n'
                                             'check "after" true\n')
            code, console, logs = self.run_host(script, '--jobs', '2')
            self.assertEqual(code, 1)
            log = self.plain((logs / 'host.log').read_text())
            for text in (console, log):
                self.assertRegex(text, r'✗ the deliberately failing check \(exit=3; log=\S+/host/section-002/check\.\w+\)\n'
                                       r'why it failed\n')
                self.assertIn('✓ after', text)
                self.assertIn('Host group: 1/4 checks failed:\n  - the deliberately failing check (exit=3;', text)
            self.assertIn('host: FAILED', console)
            row, = json.loads((logs / 'results.json').read_text())
            self.assertEqual((row['state'], row['exit']), ('failed', 1))
            self.assertEqual(Path(re.search(r'log=(\S+)\)', log)[1]).read_text(), 'why it failed\n')
            # What a section leaves running does not outlive it: its HOME is gone.
            self.assert_gone(int(left.read_text()))
            # The failed section's script is kept, the passing one's is not.
            self.assertEqual(sorted(path.name for path in (logs / 'host').iterdir()),
                             ['section-002', 'section-002.out', 'section-002.sh'])

    def test_aborting_section_and_missing_result_fail_the_run(self):
        with tempfile.TemporaryDirectory() as directory:
            script = self.fixture(directory, 'section "§1: aborts"\ncheck "before the abort" true\nfalse\n'
                                             'check "never reached" true\n'
                                             'section "§2: leaves early"\necho leaving early\nexit 0\n'
                                             'section "§3: passes"\ncheck "fine" true\n')
            abort_line = script.read_text().split('\n').index('false') + 1
            code, console, logs = self.run_host(script, '--jobs', '2')
            self.assertEqual(code, 1)
            log = self.plain((logs / 'host.log').read_text())
            for text in (console, log):
                # The error names the line of the real file, not of a shorter copy.
                self.assertIn("[err-trap] line {}: 'false' exited 1".format(abort_line), text)
                self.assertIn('✗ section (1 of 3) §1: exited 1 without reporting a result', text)
                self.assertIn('✗ section (2 of 3) §2: exited 0 without reporting a result', text)
                self.assertNotIn('never reached', text)
                # Repeated above the summary, but not as a second check line.
                self.assertEqual(text.count('✓ before the abort'), 2)
                self.assertEqual(len(re.findall(r'^\s+✓ before the abort', text, re.M)), 1)
                self.assertRegex(text, r'── section \(1 of 3\) §1 did not finish: exited 1 [^\n]*\n'
                                       r'   The last lines of its output:\n(   \| [^\n]*\n)+'
                                       r'   Full output: \S+/section-001\.out\n   Script as run: \S+/section-001\.sh\n')
                self.assertRegex(text, r'── section \(2 of 3\) §2 did not finish:[^\n]*\n[^\n]*\n(   \| [^\n]*\n)*'
                                       r'   \| leaving early\n')
                self.assertRegex(text, r'Host group: 2/3 checks failed:\n'
                                       r'  - section \(1 of 3\) §1: exited 1 [^\n]*\n  - section \(2 of 3\) §2: exited 0 ')
                self.assertEqual(self.headers(text), [1, 2, 3])
            self.assertTrue((logs / 'host' / 'section-001.sh').is_file())
            self.assertTrue((logs / 'host' / 'section-002.out').is_file())
            self.assertFalse((logs / 'host' / 'section-003.sh').exists())
            row, = json.loads((logs / 'results.json').read_text())
            self.assertEqual((row['state'], row['exit']), ('failed', 1))

    def test_truncated_or_inconsistent_result_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            counts = Path(directory) / 'counts'
            suite_runner.write_counts(counts, 3, 1, 2, [b'a failed check\nwith a second line'])
            self.assertEqual(suite_runner.read_counts(counts), (3, 1, 2, [b'a failed check\nwith a second line']))
            for data in (b'', b'3\x000\x000\x00', b'3\x000\x000\x000', b'3\x001\x000\x001\x00',
                         b'3\x001\x000\x001\x00name', b'x\x000\x000\x000\x00', b'3\x000\x000\x00-1\x00'):
                counts.write_bytes(data)
                self.assertIsNone(suite_runner.read_counts(counts), data)
            self.assertIsNone(suite_runner.read_counts(Path(directory) / 'absent'))
            # A section that reports no failure and then exits non-zero did not pass.
            script = self.fixture(directory, 'section "§1: reports, then exits 9"\ncheck "fine" true\n'
                                             'trap "exit 9" EXIT\n')
            code, console, _ = self.run_host(script, '--jobs', '2')
            self.assertEqual(code, 1)
            self.assertIn('✗ section (1 of 1) §1: exited 9 after reporting no failed check', console)
            self.assertIn('Host group: 1/2 checks failed:', console)

    def test_timed_out_section_is_killed_and_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            pids = Path(directory).resolve() / 'pids'
            script = self.fixture(directory, 'section "§1: hangs"\ncheck "before the hang" true\n'
                                             'sleep 300 &\necho "$$ $!" > ' + str(pids) + '\nwait\n'
                                             'section "§2: passes"\ncheck "fine" true\n')
            started = time.monotonic()
            code, console, logs = self.run_host(script, '--jobs', '2', env={'SANDY_TEST_SECTION_TIMEOUT': '1'})
            self.assertEqual(code, 1)
            self.assertLess(time.monotonic() - started, 30)
            self.assertIn('✗ section (1 of 2) §1: timed out after 1s; its process group was killed', console)
            self.assertIn('Host group: 1/2 checks failed:\n  - section (1 of 2) §1: timed out after 1s', console)
            self.assertIn('✓ fine', console)
            for pid in pids.read_text().split():
                self.assert_gone(int(pid))
            self.assertIn('before the hang', (logs / 'host' / 'section-001.out').read_text())

    def test_sections_selects_by_label_and_refuses_a_name_that_matches_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            script = self.fixture(directory, 'section "§1: one"\ncheck "one" true\n'
                                             'section "§2: two"\necho "inner=${SANDY_TEST_INNER_JOBS:-unset}"\n'
                                             'check "two" true\n'
                                             'info "7z. three"\ncheck "three" true\n'
                                             'section "§12: four"\ncheck "four" true\n')
            code, console, logs = self.run_host(script, '--jobs', '2', '--sections', '7z, §2,')
            self.assertEqual(code, 0, console)
            # The position is the place in the whole file, and so is the total.
            self.assertEqual(re.findall(r'^\(\d+ of \d+\) \S+', console, re.M), ['(2 of 4) §2:', '(3 of 4) 7z.'])
            self.assertRegex(console, r'TIMING \d+s \(3 of 4\) 7z\. three\n')
            self.assertIn('Host group: 2 checks passed.', console)
            self.assertIn('Host group: 2 of the 4 sections ran (--sections); the others did NOT run here.', console)
            self.assertIn('inner=1', console)
            # One section alone may use the whole budget for its own background checks.
            code, console, _ = self.run_host(script, '--jobs', '4', '--sections', '2')
            self.assertIn('inner=4', console)
            # --jobs 1 with --sections is still one process per section, one at a time.
            code, console, _ = self.run_host(script, '--jobs', '1', '--sections', '12')
            self.assertEqual((code, self.headers(console)), (0, [4]))
            before = sorted(path.name for path in (script.parent / 'logs').iterdir())
            for selection, named in (('2,99', '99'), ('248', '248'), (',', 'names no section')):
                errors = io.StringIO()
                with self.assertRaises(SystemExit) as refused, contextlib.redirect_stderr(errors):
                    self.run_host(script, '--sections', selection)
                self.assertEqual(refused.exception.code, 2)
                self.assertIn(named, errors.getvalue())
            # A refused selection ran nothing: no new run directory.
            self.assertEqual(sorted(path.name for path in (script.parent / 'logs').iterdir()), before)
            listing = io.StringIO()
            with mock.patch.object(suite_runner, 'GROUPS', {'host': ['bash', str(script)]}), \
                 mock.patch('sys.argv', ['runner', '--list-sections']), contextlib.redirect_stdout(listing):
                self.assertEqual(suite_runner.main(), 0)
            self.assertEqual([line.split(None, 2) for line in listing.getvalue().splitlines()],
                             [['1', '§1', '§1: one'], ['2', '§2', '§2: two'], ['3', '7z', '7z. three'],
                              ['4', '§12', '§12: four']])

    def test_merge_prints_in_file_order(self):
        with tempfile.TemporaryDirectory() as directory:
            flag = str(Path(directory).resolve() / 'third-finished')
            # The first section cannot finish before the third has: it waits for it.
            script = self.fixture(directory, 'section "§1: waits for the third"\n'
                                             'check "the third section finished first" bash -c \'for _ in $(seq 200); do '
                                             '[ -e "$1" ] && exit 0; sleep 0.05; done; exit 1\' _ "' + flag + '"\n'
                                             'section "§2: second"\ncheck "second" true\n'
                                             'section "§3: third"\ncheck "third" true\ntouch "' + flag + '"\n')
            code, console, logs = self.run_host(script, '--jobs', '2')
            self.assertEqual(code, 0, console)
            # Each process resets the terminal keypad as it exits; only the last
            # reset is kept, so no header has an escape sequence glued in front.
            raw = (logs / 'host.log').read_text()
            self.assertIn('\x1b>', raw)
            self.assertNotIn('\x1b>', raw[:raw.rindex('\n')])
            for text in (console, self.plain(raw)):
                self.assertEqual(self.headers(text), [1, 2, 3])
                self.assertEqual(re.findall(r'^\s+✓ (.*)', text, re.M),
                                 ['the third section finished first', 'second', 'third'])
                self.assertRegex(text, r'TIMING \d+s \(3 of 3\) §3: third\n\nHost group: 3 checks passed\.')

    def test_interrupt_kills_every_worker_and_prints_what_finished(self):
        if self.BASH_MAJOR < 5:
            self.skipTest('the host group needs bash 5 or newer on PATH')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            script = self.fixture(directory, 'section "§1: passes"\ncheck "fine" true\n'
                                             'section "§2: hangs"\ncheck "before the hang" true\n'
                                             'sleep 300 &\necho "$$ $!" > ' + str(root / 'pids') + '\nwait\n')
            program = ('import sys, suite_runner\n'
                       'suite_runner.GROUPS = {"host": ["bash", sys.argv[1]]}\n'
                       'sys.argv = ["runner", "--only", "host", "--jobs", "2", "--log-dir", sys.argv[2]]\n'
                       'sys.exit(suite_runner.main())\n')
            runner = subprocess.Popen([suite_runner.sys.executable, '-c', program, str(script), str(root / 'logs')],
                                      cwd=ROOT / 'test', stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                      start_new_session=True)
            try:
                # Both sections start at once; the first is done when its script is gone.
                for _ in range(400):
                    if (root / 'pids').exists() and list((root / 'logs').glob('run-*/host/section-002.sh')) \
                            and not list((root / 'logs').glob('run-*/host/section-001.sh')):
                        break
                    time.sleep(0.05)
                os.kill(runner.pid, signal.SIGINT)
                output, errors = runner.communicate(timeout=30)
            finally:
                if runner.poll() is None:
                    os.killpg(runner.pid, signal.SIGKILL)
            output = self.plain(output)
            self.assertNotEqual(runner.returncode, 0)
            self.assertIn('KeyboardInterrupt', errors)
            self.assertEqual(self.headers(output), [1, 2])
            self.assertIn('✓ fine', output)
            self.assertIn('✓ before the hang', output)
            self.assertIn('✗ section (2 of 2) §2: interrupted', output)
            self.assertIn('host group interrupted: 1 of 2 sections finished, 1 stopped while running, 0 not started',
                          output)
            self.assertNotIn('Host group: ', output)
            for pid in (root / 'pids').read_text().split():
                self.assert_gone(int(pid))

    def test_bash_older_than_5_is_refused_once_and_clearly(self):
        with tempfile.TemporaryDirectory() as directory:
            script = self.fixture(directory, 'section "§1: one"\ncheck "one" true\n'
                                             'section "§2: two"\ncheck "two" true\n')
            # The runner asks bash once; an old one gets the whole file in one
            # process, where the script itself refuses, not one refusal per section.
            with mock.patch.object(suite_runner, 'bash_major', return_value=3):
                code, console, _ = self.run_host(script, '--jobs', '2')
            self.assertEqual(code, 0, console)
            self.assertIn('Not splitting the host group into sections: the bash on PATH is version 3; host sections '
                          'need bash 5 or newer; '
                          'running the whole file in one process.', console)
            self.assertNotIn('Host sections:', console)
            self.assertEqual(self.headers(console), [1, 2])
            # The script's own refusal, tried by raising the version it asks for.
            source = script.read_text()
            self.assertEqual(source.count('"${BASH_VERSINFO[0]:-0}" -lt 5 ]'), 1)
            script.write_text(source.replace('"${BASH_VERSINFO[0]:-0}" -lt 5 ]', '"${BASH_VERSINFO[0]:-0}" -lt 99 ]'))
            run = subprocess.run(['bash', str(script)], env={'PATH': os.environ['PATH'], 'SANDY_TEST_CHILD': '1'},
                                 capture_output=True, text=True, timeout=30)
            self.assertEqual((run.returncode, run.stdout), (1, ''))
            self.assertRegex(run.stderr, r'needs bash 5 or newer, and the bash on PATH \(\S+\) is \d+\.\d+')
            self.assertEqual(len(run.stderr.splitlines()), 1)

    def test_sections_never_fall_back_to_the_whole_file(self):
        with tempfile.TemporaryDirectory() as directory:
            script = self.fixture(directory, 'section "§1: one"\ncheck "one" true\n'
                                             'section "§2: two"\ncheck "two" true\n')
            logs = script.parent / 'logs'
            # An old bash, or one whose version could not be read (a probe that
            # timed out under load): --sections refuses before anything runs.
            for major, reason in ((3, 'the bash on PATH is version 3; host sections need bash 5'),
                                  (0, 'could not tell which bash')):
                errors = io.StringIO()
                with mock.patch.object(suite_runner, 'bash_major', return_value=major), \
                     self.assertRaises(SystemExit) as refused, contextlib.redirect_stderr(errors):
                    self.run_host(script, '--sections', '2')
                self.assertEqual(refused.exception.code, 2)
                self.assertIn('--sections: ' + reason, errors.getvalue())
                self.assertFalse(logs.exists(), 'a refused selection must run nothing')
            # A script that cannot be split: --sections refuses with the reason,
            # and --jobs 2 says so loudly before running the file in one process.
            unsplittable = Path(directory).resolve() / 'unsplittable.sh'
            unsplittable.write_text(script.read_text().replace('\n_test_section_close\n', '\n'))
            errors = io.StringIO()
            with self.assertRaises(SystemExit) as refused, contextlib.redirect_stderr(errors):
                self.run_host(unsplittable, '--sections', '2')
            self.assertEqual(refused.exception.code, 2)
            self.assertIn('cannot list or select host sections: ', errors.getvalue())
            self.assertIn('no sections followed by a final _test_section_close line', errors.getvalue())
            code, console, _ = self.run_host(unsplittable, '--jobs', '2')
            self.assertRegex(console, r'✗ The host script cannot be split into sections \(\S+ has no sections followed '
                                      r'by a final _test_section_close line\); running the whole file in one process\.')
            self.assertNotIn('Host sections:', console)
            self.assertEqual(self.headers(console), [1, 2])

    def test_auto_at_one_worker_keeps_the_one_process_to_one_inner_job(self):
        with tempfile.TemporaryDirectory() as directory:
            script = self.fixture(directory, 'section "§1: one"\necho "inner=${SANDY_TEST_INNER_JOBS:-unset}"\n'
                                             'check "one" true\nsection "§2: two"\ncheck "two" true\n')
            with mock.patch.object(suite_runner, 'auto_jobs', return_value=1):
                code, console, _ = self.run_host(script, '--jobs', 'auto')
            self.assertEqual(code, 0, console)
            self.assertNotIn('Host sections:', console)  # the whole file, one process
            self.assertIn('inner=1', console)
            # An explicit --jobs 1 is the run as it always was, untouched.
            code, console, _ = self.run_host(script, '--jobs', '1')
            self.assertIn('inner=unset', console)

    def test_a_section_whose_checks_stopped_running_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            gone = Path(directory).resolve() / 'checks-gone'
            script = self.fixture(directory, 'section "§1: keeps its checks"\ncheck "one" true\n'
                                             'section "§2: loses its checks"\n'
                                             '[ -e "' + str(gone) + '" ] || check "two" true\n'
                                             'section "§3: never had any"\n')
            code, console, logs = self.run_host(script, '--jobs', '2')
            self.assertEqual(code, 0, console)
            self.assertNotIn('ran no check', console)
            self.assertEqual(suite_runner.load_times(script.parent / 'logs' / suite_runner.TIMES_FILE, 'checks', int),
                             {'§1: keeps its checks': 1, '§2: loses its checks': 1, '§3: never had any': 0})
            gone.touch()
            code, console, logs = self.run_host(script, '--jobs', '2')
            self.assertEqual(code, 0, console)
            log = self.plain((logs / 'host.log').read_text())
            for text in (console, log):
                self.assertIn('⚠ Host group: section (2 of 3) §2 ran no check, and the last run counted 1 in it; '
                              'its checks no longer run.', text)
                self.assertNotIn('§3 ran no check', text)
                # Part of the summary: after the totals.
                self.assertLess(text.index('Host group: 1 checks passed.'), text.index('⚠ Host group:'))

    def run_groups(self, groups, *arguments):
        if self.BASH_MAJOR < 5:
            self.skipTest('the host group needs bash 5 or newer on PATH')
        logs = Path(groups['host'][1]).parent / 'logs'
        console = io.StringIO()
        with mock.patch.object(suite_runner, 'GROUPS', groups), \
             mock.patch('sys.argv', ['runner', '--log-dir', str(logs)] + list(arguments)), \
             contextlib.redirect_stdout(console):
            code = suite_runner.main()
        return code, self.plain(console.getvalue()), logs / 'latest'

    def test_short_groups_run_beside_the_sections_and_report_in_group_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            marks = root / 'marks'
            marks.mkdir()
            # Each section records how many of the others (and the groups) run with it.
            probe = ('check "{0}" bash -c \'touch "$1/{0}.start"; sleep 0.4; ls "$1" | grep "\\.start$" '
                     '> "$1/{0}.seen"; rm "$1/{0}.start"\' _ "' + str(marks) + '"\n')
            script = self.fixture(directory, ''.join('section "§{0}: s{0}"\n'.format(n) + probe.format('s' + str(n))
                                                     for n in range(1, 5)))
            group = ('import os, sys, time; from pathlib import Path; m = Path(sys.argv[1]); '
                     '(m / (sys.argv[2] + ".start")).touch(); time.sleep(float(sys.argv[3])); '
                     'print(sys.argv[2], "output", "line", 1); print(sys.argv[2], "output", "line", 2); '
                     '(m / (sys.argv[2] + ".start")).unlink(); raise SystemExit(int(sys.argv[4]))')
            groups = {'harness': [suite_runner.sys.executable, '-c', group, str(marks), 'harness', '1.0', '0'],
                      'contracts': [[suite_runner.sys.executable, '-c', group, str(marks), 'contracts', '0.3', '5'],
                                    [suite_runner.sys.executable, '-c', group, str(marks), 'contracts2', '0.3', '0']],
                      'host': ['bash', str(script)]}
            started = time.monotonic()
            code, console, logs = self.run_groups(groups, '--host-only', '--jobs', '3')
            elapsed = time.monotonic() - started
            # A failing contracts group fails the run, beside the sections as alone.
            self.assertEqual(code, 1, console)
            self.assertIn('SUITE FAILED — failed groups: contracts (exit 1)', console)
            rows = json.loads((logs / 'results.json').read_text())
            self.assertEqual([(row['group'], row['state'], row['exit']) for row in rows],
                             [('harness', 'passed', 0), ('contracts', 'failed', 5), ('host', 'passed', 0)])
            summary = console[console.index('========== SUITE SUMMARY'):]
            self.assertEqual(re.findall(r'^(\w+): (?:passed|failed|partial) ', summary, re.M),
                             ['harness', 'contracts', 'host'])
            self.assertIn('harness and contracts run beside the host group\'s sections, each holding one of the 3 slots',
                          console)
            # Each group's block is whole and in group order; the host block follows them.
            blocks = re.split(r'^(?=\[\d/3\] )', console, flags=re.M)[1:]
            self.assertEqual([block.split('\n', 1)[0] for block in blocks],
                             ['[1/3] Test harness regressions (harness)', '[2/3] Production behavior contracts (contracts)',
                              '[3/3] Host checks (host)'])
            self.assertRegex(blocks[0], r'\nharness output line 1\nharness output line 2\nharness: PASSED [^\n]*\n$')
            self.assertRegex(blocks[1], r'\ncontracts output line 1\ncontracts output line 2\ncontracts2 output line 1\n'
                                        r'contracts2 output line 2\ncontracts: FAILED [^\n]*\nFull failure details: \S+\n'
                                        r'Continuing with remaining groups; the overall run will report failure\.\n$')
            self.assertTrue(blocks[2].startswith('[3/3] Host checks (host)\nHost sections: 4 of 4, 3 at a time'))
            self.assertEqual(self.headers(blocks[2]), [1, 2, 3, 4])
            self.assertIn('contracts output line 1', (logs / 'contracts.log').read_text())
            # They ran at the same time as the sections, and never more than --jobs at once.
            seen = [(marks / ('s{}.seen'.format(n))).read_text().split() for n in range(1, 5)]
            self.assertLessEqual(max(len(names) for names in seen), 3, seen)
            self.assertIn('harness.start', sum(seen, []), 'no section ran while the harness group did')
            # Harness ended last but printed first: the order is the groups', not the finishing order.
            self.assertLess(elapsed, 30)

    def test_groups_run_one_after_another_unless_the_host_group_is_split(self):
        with tempfile.TemporaryDirectory() as directory:
            script = self.fixture(directory, 'section "§1: one"\ncheck "one" true\nsection "§2: two"\ncheck "two" true\n')
            groups = {'harness': [suite_runner.sys.executable, '-c', 'print("harness ran")'],
                      'contracts': [suite_runner.sys.executable, '-c', 'raise SystemExit(4)'],
                      'host': ['bash', str(script)]}
            for arguments in (('--host-only', '--jobs', '1'), ('--only', 'harness,contracts', '--jobs', '4')):
                code, console, logs = self.run_groups(groups, *arguments)
                self.assertEqual(code, 1, console)
                self.assertNotIn('run beside the host group', console)
                self.assertNotIn('Host sections:', console)
                rows = json.loads((logs / 'results.json').read_text())
                self.assertEqual([(row['group'], row['state']) for row in rows][:2],
                                 [('harness', 'passed'), ('contracts', 'failed')])

    def test_jobs_follow_the_cpus_and_a_process_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            cgroup = Path(directory)
            # No cgroup files (macOS): the CPUs decide, twelve at most.
            self.assertEqual(suite_runner.auto_jobs(cpus=10, cgroup=cgroup), 10)
            self.assertEqual(suite_runner.auto_jobs(cpus=32, cgroup=cgroup), 12)
            self.assertEqual(suite_runner.auto_jobs(cpus=0, cgroup=cgroup), 1)
            for limit, used, expected in (('max', '40', 10), ('512', '150', 2), ('512', '29', 3), ('512', '480', 1),
                                          ('150', '100', 1), ('4096', '100', 10), ('100000', '100', 10)):
                (cgroup / 'pids.max').write_text(limit + '\n')
                (cgroup / 'pids.current').write_text(used + '\n')
                self.assertEqual(suite_runner.auto_jobs(cpus=10, cgroup=cgroup), expected, (limit, used))
            self.assertEqual(suite_runner.auto_jobs(cpus=1, cgroup=cgroup), 1)
        self.assertGreaterEqual(suite_runner.auto_jobs(), 1)
        self.assertEqual(suite_runner.jobs_argument('auto'), 'auto')
        self.assertEqual(suite_runner.jobs_argument('3'), 3)
        for bad in ('0', '-2', 'many', ''):
            with self.assertRaises(suite_runner.argparse.ArgumentTypeError):
                suite_runner.jobs_argument(bad)

    def test_long_sections_start_first(self):
        sections = [suite_runner.Section(position, start, end, 'section "§{}: s"'.format(position))
                    for position, (start, end) in enumerate(((0, 10), (10, 400), (400, 450), (450, 460)), 1)]

        def order(seconds):
            return [section.position for section in suite_runner.start_order(sections, seconds)]
        # No times: by line count. All timed: by time. Ties keep file order.
        self.assertEqual(order({}), [2, 3, 1, 4])
        self.assertEqual(order({'§1: s': 9.0, '§2: s': 1.0, '§3: s': 5.0, '§4: s': 5.0}), [1, 3, 4, 2])
        # A section the last run did not time is placed by its lines, at the others' seconds per line.
        self.assertEqual(order({'§1: s': 2.0, '§3: s': 30.0, '§4: s': 1.0}), [2, 3, 1, 4])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / suite_runner.TIMES_FILE
            self.assertEqual(suite_runner.load_times(path), {})
            path.write_text('not json')
            self.assertEqual(suite_runner.load_times(path), {})
            suite_runner.save_times(path, {'§3: s': 30.126, 'a section that was removed': 4.0}, sections)
            self.assertEqual(suite_runner.load_times(path), {'§3: s': 30.13})
            self.assertEqual([entry.name for entry in Path(directory).iterdir()], [suite_runner.TIMES_FILE])


if __name__ == "__main__":
    unittest.main()
