"""Regression tests for false passes in the shell harnesses; no Docker needed."""
import os
import contextlib
import io
import json
import pty
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest import mock

import suite_runner
import test_container as container_tests
from log_paths import MARKER, start_run

from result_checks import acceptance_ok, answer_ok, probe_ok, selection_errors

ROOT = Path(__file__).resolve().parent.parent


class CompletionEvidence(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
