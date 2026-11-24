"""Host-only Docker acceptance, using the production launcher and local packages.

No provider credentials or registry package downloads are needed by the probes.
The real image build can need network access. Never run inside a Sandy session.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
import zipfile

import test_production_contracts as production_contracts

ROOT = Path(__file__).resolve().parent.parent


def wheel(directory, name):
    metadata = name + '-1.0.dist-info/'
    path = directory / (name + '-1.0-py3-none-any.whl')
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr(name + '.py', 'VALUE = "fixture"\n')
        archive.writestr(metadata + 'METADATA', 'Metadata-Version: 2.1\nName: ' + name + '\nVersion: 1.0\n')
        archive.writestr(metadata + 'WHEEL', 'Wheel-Version: 1.0\nGenerator: sandy-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n')
        archive.writestr(metadata + 'RECORD', '')


class ContainerContracts(unittest.TestCase):
    def check_gemini_refresh_mounts(self):
        """Exercise production mount flags without contacting an OAuth provider."""
        host_dir = self.home / '.gemini'
        host_dir.mkdir()
        original = '{"access_token":"fixture-old","refresh_token":"fixture-refresh"}'
        probe = '''import errno, json, sys
from pathlib import Path
path = Path('/home/sandy/.gemini') / sys.argv[1]
expected_ro = sys.argv[2] == 'ro'
assert path.stat().st_mode & 0o777 == 0o600
credentials = json.loads(path.read_text())
assert credentials['access_token'] == 'fixture-old'
credentials['access_token'] = 'fixture-refreshed'
try:
    path.write_text(json.dumps(credentials))
except OSError as error:
    assert expected_ro and error.errno == errno.EROFS, error
    print('GEMINI_REFRESH_READONLY_CONTROL_OK')
else:
    assert not expected_ro, 'read-only negative control unexpectedly allowed a write'
    assert json.loads(path.read_text())['refresh_token'] == 'fixture-refresh'
    # Newer CLI versions try rename first, then direct-write on a file mount.
    staging = path.with_name('.refresh.tmp')
    staging.write_text(json.dumps(credentials))
    try:
        staging.replace(path)
    except OSError as error:
        assert error.errno == errno.EBUSY, error
        path.write_text(staging.read_text())
        staging.unlink()
    print('GEMINI_REFRESH_OK')
'''
        for filename in ('oauth_creds.json', 'tokens.json'):
            host = host_dir / filename
            host.write_text(original)
            copies = []
            try:
                for index in range(2):
                    env = {**self.env, 'TMPDIR': str(self.home), 'SANDY_GEMINI_AUTH': 'oauth',
                           'SANDBOX_DIR': str(self.home / 'gemini-probe' / filename / str(index))}
                    run = subprocess.run(['bash', '-c', production_contracts.gemini_credential_probe_source()],
                                         env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
                    self.assertEqual(run.returncode, 0, run.stderr)
                    directory, auth, *flags = run.stdout.rstrip('\0').split('\0')
                    copies.append((Path(directory) / filename, flags))
                    self.assertEqual(auth, 'oauth-personal')
                first, flags = copies[0]
                # This direct probe bypasses Sandy's entrypoint, which normally
                # chowns the tmpfs home to HOST_UID. The image's own home can be
                # 0700/UID 1001, so a macOS UID (usually 501) cannot traverse it.
                # Give the probe its own correctly owned home, as a launch does.
                home_tmpfs = '/home/sandy:rw,nosuid,nodev,mode=700,uid={},gid={}'.format(os.getuid(), os.getgid())
                base = ['docker', 'run', '--rm', '--network', 'none', '--read-only',
                        '--tmpfs', home_tmpfs,
                        '--user', str(os.getuid()) + ':' + str(os.getgid())]
                command = ['--entrypoint', 'python3', 'sandy-claude-code', '-c', probe, filename]
                control = [value[:-3] + ':ro' if value.endswith(':rw') else value for value in flags]
                out = self.command('gemini-' + filename + '-readonly', base + control + command + ['ro'], self.home)
                self.assertIn('GEMINI_REFRESH_READONLY_CONTROL_OK', out)
                out = self.command('gemini-' + filename + '-refresh', base + flags + command + ['rw'], self.home)
                self.assertIn('GEMINI_REFRESH_OK', out)
                self.assertEqual(json.loads(first.read_text())['access_token'], 'fixture-refreshed')
                self.assertEqual(copies[1][0].read_text(), original)
                self.assertEqual(host.read_text(), original)
                print('PASS Gemini ' + filename + ': refresh writes only the private launch copy', flush=True)
            finally:
                for copy, _ in copies:
                    run = subprocess.run(['bash', '-c', production_contracts.gemini_credential_cleanup_source()],
                                         env={**self.env, 'GEMINI_CRED_TMPDIR': str(copy.parent)},
                                         capture_output=True, text=True, timeout=10)
                    self.assertEqual(run.returncode, 0, run.stderr)
                    self.assertFalse(copy.parent.exists())
                self.assertEqual(host.read_text(), original)
                host.unlink()

    def check_tini_forwards_signals_to_the_dropped_child(self):
        """#493: a signal delivered to PID 1 must reach the agent, not end the container."""
        start = 'RUN_FLAGS+=(--security-opt no-new-privileges:true)\n'
        end = 'RUN_FLAGS+=(--pids-limit "$SANDY_PIDS_LIMIT")\n'
        flags_source = 'RUN_FLAGS=()\n' + start + production_contracts.span(start, end) + 'printf "%s\\0" "${RUN_FLAGS[@]}"\n'
        run = subprocess.run(['bash', '-c', flags_source], capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        flags = run.stdout.rstrip('\0').split('\0')
        self.assertIn('--cap-drop', flags)
        name = 'sandy-test-tini-signal-' + str(os.getpid())
        # PID 1 is tini (--init, as in production); its child gosu-drops to a
        # non-root uid exactly as the entrypoint does, then traps WINCH.
        child = 'trap "echo GOT_WINCH" WINCH; echo READY; while :; do sleep 0.2; done'
        args = (['docker', 'run', '-d', '--name', name, '--init', '--network', 'none'] + flags
                + ['--entrypoint', 'bash', 'sandy-claude-code', '-c', 'exec gosu 4242:4242 bash -c ' + repr(child)])
        try:
            self.command('tini-signal-start', args, self.home, 60)
            for _ in range(50):
                logs = subprocess.run(['docker', 'logs', name], capture_output=True, text=True, timeout=10)
                if 'READY' in logs.stdout:
                    break
                time.sleep(0.2)
            self.assertIn('READY', logs.stdout, logs.stdout + logs.stderr)
            self.command('tini-signal-send', ['docker', 'kill', '--signal=WINCH', name], self.home, 30)
            for _ in range(25):
                logs = subprocess.run(['docker', 'logs', name], capture_output=True, text=True, timeout=10)
                if 'GOT_WINCH' in logs.stdout or 'FATAL' in logs.stderr:
                    break
                time.sleep(0.2)
            state = subprocess.run(['docker', 'inspect', '-f', '{{.State.Running}}', name],
                                   capture_output=True, text=True, timeout=10).stdout.strip()
            self.assertNotIn('Unexpected error when forwarding signal', logs.stderr)
            self.assertEqual(state, 'true', 'container ended on a forwarded signal: ' + logs.stderr)
            self.assertIn('GOT_WINCH', logs.stdout, 'the dropped child never received the signal')
            print('PASS tini: a signal sent to PID 1 reaches the uid-dropped child and the container survives', flush=True)
        finally:
            subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=30)

    # B5: the feature-entry startup window runs alongside the agent. Measured
    # with a real image and a real tmux; the agent is a stand-in (the project
    # image replaces claude) that records when its pane started.
    # Design B5 section 8: --start reports the failure (exit 6) within 8s.
    # Measured from when the agent's pane STARTED, not from the invocation, so
    # host-side setup (config, image freshness, network, proxy; slow on
    # macOS) is excluded: entry exits at +2s, the supervisor poll and the
    # teardown (<=3s grace) follow.
    ENTRY_FAIL_START_BOUND = 8

    def entry_window_fixture(self, entry_body):
        project = self.home / 'entrywin'
        if not project.exists():
            project.mkdir()
            self.command('entrywin-git-init', ['git', 'init', '-q'], project)
            context = project / '.sandy'
            context.mkdir()
            (context / 'fake-agent').write_text(
                '#!/bin/sh\n'
                'case "${1:-}" in plugin|mcp|config|update|doctor|--version|-v) exit 0 ;; esac\n'
                'date +%s > "$PWD/.agent-started.$(cat /etc/hostname).$$"\n'
                'exec sleep 600\n')
            (context / 'Dockerfile').write_text(
                'ARG BASE_IMAGE=sandy-claude-code\nFROM ${BASE_IMAGE}\nUSER root\n'
                'COPY fake-agent /usr/local/bin/sandy-fake-agent\n'
                'RUN chmod 755 /usr/local/bin/sandy-fake-agent && rm -f /usr/local/bin/claude '
                '&& ln -s /usr/local/bin/sandy-fake-agent /usr/local/bin/claude\n')
        feature = self.home / '.sandy' / 'features' / 'ew'
        (feature / 'payload').mkdir(parents=True, exist_ok=True)
        # A new file per fixture, and no host-side delete of the marker a
        # container wrote: on macOS file sharing a host that rewrites or
        # deletes a file a container used can make the next container read it
        # at a stale length, or fail to create it again (ENOENT) -- the same
        # rule sandy itself follows (#400).
        self._ew_n = getattr(self, '_ew_n', 0) + 1
        name = 'entry-%d' % self._ew_n
        (feature / 'payload' / name).write_text('#!/bin/sh\n' + entry_body)
        (feature / 'payload' / name).chmod(0o755)
        (feature / 'feature.json').write_text(json.dumps({
            'sandboxes': {'include': ['*']}, 'agents': {'include': ['*']},
            'mounts': [{'name': 'payload', 'from': 'payload'}], 'entry': 'payload/' + name}))
        self._ew_markers = set(project.glob('.agent-started.*'))
        return project

    def new_agent_marker(self, project, wait=0):
        """The marker the stand-in agent wrote since the last fixture or
        launch (one per container: the name carries its hostname and pid)."""
        for _ in range(max(1, int(wait / 0.5))):
            new = sorted(set(project.glob('.agent-started.*')) - self._ew_markers)
            new = [m for m in new if m.read_text().strip()]
            if new:
                return new
            if wait:
                time.sleep(0.5)
        return []

    def workspace_containers(self, project):
        return subprocess.run(['docker', 'ps', '-aq', '--filter', 'label=sandy.workspace_path=' + str(project)],
                              capture_output=True, text=True, timeout=30).stdout.split()

    def check_entry_window(self):
        import pty
        import select
        feature = self.home / '.sandy' / 'features' / 'ew'
        self.addCleanup(shutil.rmtree, feature, True)
        # (1) interactive, on a pty: the entry exits 3 two seconds after it
        # starts. The agent's pane must already be running by then, the launch
        # exits 1, and the entry's message is printed once, after tmux has
        # left the alternate screen.
        project = self.entry_window_fixture('date +%s > "$SANDY_FEATURE_STATE/exited"\nsleep 2\nexit 3\n')
        master, slave = pty.openpty()
        process = subprocess.Popen(['bash', str(ROOT / 'sandy')], stdin=slave, stdout=slave, stderr=slave,
                                   cwd=str(project), env={**self.env, 'TERM': 'xterm'})
        os.close(slave)
        output = b''
        deadline = time.time() + 600
        while time.time() < deadline:
            ready, _, _ = select.select([master], [], [], 30)
            if not ready:
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
        rc = process.wait(timeout=60)
        os.close(master)
        text = output.decode(errors='replace')
        (self.logs / 'entry-window-pty.log').write_text(text)
        message = 'sandy-entry ew exited 3 within 5s of starting'
        self.assertEqual(rc, 1, 'interactive launch with a failing entry: ' + text[-3000:])
        self.assertEqual(text.count(message), 1, text[-3000:])
        self.assertIn(message, text.rsplit('\x1b[?1049l', 1)[-1], 'the message must follow tmux leaving the screen')
        markers = self.new_agent_marker(project, wait=10)
        exited = list((self.home / '.sandy/sandboxes').glob('entrywin-*/feature-state/ew/exited'))
        self.assertEqual(len(markers), 1, 'the agent pane never started (markers: %s)' % markers)
        started = markers[0]
        self.assertEqual(len(exited), 1, exited)
        self.assertLessEqual(int(started.read_text()), int(exited[0].read_text()) + 2,
                             'the agent must start while the window is still open')
        print('PASS entry window: interactive failure tears down, exits 1, message after tmux', flush=True)
        # (2) --start with the same entry: exit 6, quickly, and nothing left.
        self._ew_markers = set(project.glob('.agent-started.*'))
        run = subprocess.run(['bash', str(ROOT / 'sandy'), '--start', '--workspace', str(project)],
                             env=self.env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=600)
        done = time.time()
        markers = self.new_agent_marker(project, wait=10)
        self.assertEqual(len(markers), 1, 'the agent pane never started under --start (markers: %s)' % markers)
        elapsed = done - int(markers[0].read_text())
        (self.logs / 'entry-window-start-fail.log').write_text(run.stdout + run.stderr)
        self.assertEqual(run.returncode, 6, run.stdout[-3000:] + run.stderr[-3000:])
        self.assertIn(message, run.stdout + run.stderr)
        self.assertLess(elapsed, self.ENTRY_FAIL_START_BOUND, 'took %.1fs after the agent started' % elapsed)
        for _ in range(15):
            if not self.workspace_containers(project):
                break
            time.sleep(1)
        self.assertEqual(self.workspace_containers(project), [], 'a failed --start left a container')
        print('PASS entry window: --start failure exits 6 %.1fs after the agent started, and leaves nothing' % elapsed, flush=True)
        # (3) --start with an entry that stays up: exit 0, the verdict is
        # passed, and the window ended at least 4s after the agent started.
        project = self.entry_window_fixture('exec sleep 600\n')
        try:
            self.command('entry-window-start-ok', ['bash', str(ROOT / 'sandy'), '--start', '--workspace', str(project)],
                         self.home, 600)
            container = self.workspace_containers(project)[0]
            verdict = subprocess.run(['docker', 'exec', '-u', str(os.getuid()), container, 'sh', '-c',
                                      'cat /home/sandy/.sandy-entry-window; stat -c %Y /home/sandy/.sandy-entry-window'],
                                     capture_output=True, text=True, timeout=30).stdout.split()
            self.assertEqual(verdict[0], 'passed', verdict)
            # The marker is written by the stand-in agent through the
            # workspace mount; wait for it rather than reading it once, so a
            # late or missing agent start fails with evidence, not a
            # FileNotFoundError (and before --stop destroys the container).
            markers = self.new_agent_marker(project, wait=30)
            if len(markers) != 1:
                def probe(*cmd):
                    out = subprocess.run(['docker', 'exec', '-u', str(os.getuid()), container] + list(cmd),
                                         capture_output=True, text=True, timeout=30)
                    return (out.stdout + out.stderr)[-2000:]
                evidence = {
                    'verdict': verdict,
                    'pane': probe('tmux', 'capture-pane', '-p', '-t', 'sandy'),
                    'panes': probe('tmux', 'list-panes', '-a', '-F', '#{pane_id} #{pane_pid} #{pane_current_command} dead=#{pane_dead}'),
                    'ps': probe('ps', '-eo', 'pid,ppid,etimes,args'),
                    'workspace': probe('sh', '-c', 'pwd; ls -la "$SANDY_WORKSPACE" 2>/dev/null || ls -la ~'),
                    'host_project': sorted(p.name for p in project.iterdir()),
                }
                (self.logs / 'entry-window-start-ok-evidence.log').write_text(json.dumps(evidence, indent=1))
                self.fail('the agent never wrote .agent-started within 30s of --start returning ready: '
                          + json.dumps(evidence)[-3000:])
            started = markers[0]
            self.assertGreaterEqual(int(verdict[1]) - int(started.read_text()), 4,
                                    'the window must end >=4s after the agent started (verdict %s, agent %s)'
                                    % (verdict, started.read_text().strip()))
            print('PASS entry window: a long-running entry -> ready only after the 5s window, agent already up', flush=True)
        finally:
            subprocess.run(['bash', str(ROOT / 'sandy'), '--stop', '--workspace', str(project)],
                           env=self.env, stdin=subprocess.DEVNULL, capture_output=True, timeout=120)

    def command(self, name, args, cwd, timeout=600):
        log = self.logs / (name + '.log')
        with log.open('w') as output:
            process = subprocess.Popen(args, cwd=cwd, env=self.env, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                rc = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                self.fail(name + ' timed out; log: ' + str(log))
        text = log.read_text(errors='replace')
        self.assertEqual(rc, 0, name + ': ' + str(log) + '\n' + text[-12000:])
        return text

    def cleanup_runtime(self):
        # Names come only from this test's isolated home. Shared base images
        # remain cached; temporary project layers and timed-out probes do not.
        for sandbox in (self.home / '.sandy/sandboxes').glob('*'):
            if sandbox.is_dir() and not sandbox.name.startswith('.'):
                for args in (['docker', 'rm', '-f', 'sandy-' + sandbox.name],
                             ['docker', 'image', 'rm', 'sandy-project-' + sandbox.name.lower()]):
                    try:
                        subprocess.run(args, env=self.env, capture_output=True, timeout=30)
                    except subprocess.TimeoutExpired:
                        print('Cleanup timed out: ' + ' '.join(args), flush=True)

    def project(self, name):
        project = self.home / name
        project.mkdir()
        self.command(name + '-git-init', ['git', 'init', '-q'], project)
        listing = self.command(name + '-protected-list', ['bash', str(ROOT / 'sandy'), '--print-protected-paths'], project)
        protected = {}
        for line in listing.splitlines():
            kind, separator, relative = line.partition(':')
            if not separator or kind not in ('file', 'gitfile', 'dir'):
                continue
            # Leave one protected file + directory absent for existence gating.
            if relative in ('.envrc', '.idea') or relative == '.sandy':
                continue
            path = project / relative
            if kind == 'dir':
                path = path / 'fixture'
            path.parent.mkdir(parents=True, exist_ok=True)
            # Use valid inert config. Empty version pins avoid downloads; Git's
            # generated config must remain intact for real startup operations.
            content = ('# pack-refs with: peeled fully-peeled sorted\n' if relative == '.git/packed-refs' else
                       '.\n' if relative == '.git/commondir' else  # the gitdir itself: a no-op redirect
                       '{"crossSessionInbound":"refuse"}\n' if relative == '.claude/settings.local.json' else
                       '{}\n' if relative.endswith('.json') else
                       '' if relative in ('.python-version', '.nvmrc', '.node-version', '.ruby-version') else
                       path.read_text() if relative == '.git/config' else '# host fixture\n')
            path.write_text(content)
            path.chmod(0o644)  # owner can write; no permission-bit backstop
            with path.open('a'):
                pass  # host-side positive control before the read-only bind
            protected[str(path.relative_to(project))] = content
        # Git's launch-time HEAD lookup must work before any image is built.
        self.command(name + '-git-head', ['git', 'symbolic-ref', '-q', 'HEAD'], project)
        self.command(name + '-git-status', ['git', 'status', '--porcelain'], project)
        # Exercise nested submodule mounts without relying on network clones.
        for relative in ('.git/modules/child/config', '.git/modules/child/hooks/pre-commit', '.git/modules/child/info/attributes'):
            path = project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('# host fixture\n')
            protected[relative] = '# host fixture\n'
        # A submodule gitdir is recognized by what git requires of one.
        child = project / '.git/modules/child'
        (child / 'objects').mkdir(exist_ok=True)
        (child / 'refs').mkdir(exist_ok=True)
        (child / 'HEAD').write_text('ref: refs/heads/main\n')
        for directory in ('commands', 'agents', 'plugins'):
            path = project / '.claude' / directory
            path.mkdir(parents=True, exist_ok=True)
            (path / 'host-only').write_text('host')
        (project / '.gitattributes').write_text('*.bin filter=lfs diff=lfs merge=lfs -text\n')
        native = project / 'node_modules/foreign.node'
        native.parent.mkdir()
        native.write_bytes(bytes.fromhex('cffaedfe') + bytes(60))
        context = project / '.sandy'
        context.mkdir(exist_ok=True)
        (context / 'config').write_text('# excluded from project build context\n')
        (context / '.secrets').write_text('# excluded from project build context\n')
        shutil.copyfile(ROOT / 'test/container_probe.py', context / 'probe.py')
        (context / 'Dockerfile').write_text(
            'ARG BASE_IMAGE=sandy-claude-code\nFROM ${BASE_IMAGE}\nUSER root\n'
            'COPY . /opt/sandy-test-context/\n'
            'RUN test ! -e /opt/sandy-test-context/config && test ! -e /opt/sandy-test-context/.secrets '
            '&& chmod 755 /opt/sandy-test-context/probe.py '
            '&& rm -f /usr/local/bin/claude '
            '&& ln -s /opt/sandy-test-context/probe.py /usr/local/bin/claude\n')
        return project, protected

    def launch(self, project, protected, phase):
        (project / '.probe-request.json').write_text(json.dumps({
            'phase': phase, 'uid': os.getuid(), 'protected': protected,
            'protected_directories': [str(Path(path).parent) for path in protected if path.endswith('/fixture')]
                                     + ['.sandy', '.git/modules/child/hooks', '.git/modules/child/info'],
            'absent': ['.envrc', '.idea/new-file']}))
        text = self.command(project.name + '-' + phase, ['bash', str(ROOT / 'sandy'), '-p', 'run fixture'], project)
        markers = [line.removeprefix('SANDY_PROBE:') for line in text.splitlines() if line.startswith('SANDY_PROBE:')]
        self.assertEqual(len(markers), 1, 'expected exactly one completed probe; see ' + str(self.logs))
        result = json.loads(markers[0])
        self.assertEqual(result['phase'], phase)
        self.assertIn('native addons built for a different platform', text)
        if phase != 'verify':
            self.assertIn('Protected paths appeared during this session', text)
        self.assertGreater(len(result['checks']), 20)
        for check in result['checks']:
            print('PASS ' + phase + ': ' + check, flush=True)
        for name in ('commands', 'agents', 'plugins'):
            self.assertFalse((project / '.claude' / name / 'agent-only').exists())
            self.assertEqual((project / '.claude' / name / 'host-only').read_text(), 'host')
        for relative in protected:
            self.assertEqual((project / relative).read_text(), protected[relative])

    def test_real_launch_persistence_protection_and_isolation(self):
        self.assertFalse(Path('/etc/sandy-session.json').exists(), 'Run container tests on the host, outside Sandy.')
        self.assertIsNotNone(shutil.which('docker'), 'Docker is required for the container group')
        self.logs = Path(os.environ['SANDY_TEST_LOG_DIR'] if 'SANDY_TEST_LOG_DIR' in os.environ
                         else tempfile.mkdtemp(prefix='sandy-container-logs.'))
        self.logs.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix='sandy-container.')
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve()
        self.env = {key: os.environ[key] for key in ('PATH', 'TERM', 'LANG') if key in os.environ}
        self.env.update(HOME=str(self.home), SANDY_HOME=str(self.home / '.sandy'),
                        SANDY_AUTO_APPROVE_PRIVILEGED='1', SANDY_OFFLINE='1', SANDY_AGENT='claude',
                        SANDY_EGRESS='off', CLAUDE_CODE_OAUTH_TOKEN='sandy-test-fixture-not-a-credential')
        cache = Path(os.environ.get('SANDY_TEST_BUILD_CACHE', str(self.home / 'no-cache')))
        generated = self.home / '.sandy'
        generated.mkdir()
        self.addCleanup(self.cleanup_runtime)
        # Only build fingerprints; never copy credentials/config/sandboxes.
        for name in ('.base_build_hash', '.build_hash'):
            if (cache / name).is_file():
                shutil.copyfile(cache / name, generated / name)
        self.command('docker-info', ['docker', 'info'], self.home, 30)
        self.command('build-current-source', ['bash', str(ROOT / 'sandy'), '--build-only'], self.home, 1200)
        identity = self.command('image-identity', ['docker', 'image', 'inspect', '--format', '{{.Id}}', 'sandy-claude-code'], self.home)
        print('Validated production image: ' + identity.strip(), flush=True)
        project, protected = self.project('primary')
        fixture = project / 'fixtures'
        fixture.mkdir()
        for name in ('sandy_fixture', 'sandy_venv_fixture'):
            wheel(fixture, name)
        npm = fixture / 'npm'
        npm.mkdir()
        (npm / 'package.json').write_text(json.dumps({'name': 'sandy-npm-fixture', 'version': '1.0.0', 'bin': {'sandy-npm-fixture': 'cli.js'}}))
        (npm / 'cli.js').write_text('#!/usr/bin/env node\nconsole.log("fixture");\n')
        (npm / 'cli.js').chmod(0o755)
        go = fixture / 'go'
        go.mkdir()
        (go / 'go.mod').write_text('module sandy-go-fixture\n\ngo 1.20\n')
        (go / 'main.go').write_text('package main\nimport "fmt"\nfunc main() { fmt.Println("fixture") }\n')
        rust = fixture / 'rust/src'
        rust.mkdir(parents=True)
        (rust.parent / 'Cargo.toml').write_text('[package]\nname="sandy-rust-fixture"\nversion="1.0.0"\nedition="2021"\n')
        (rust / 'main.rs').write_text('fn main() { println!("fixture"); }\n')
        self.launch(project, protected, 'install')
        self.launch(project, protected, 'verify')
        other, other_protected = self.project('independent')
        self.launch(other, other_protected, 'isolated')
        self.check_gemini_refresh_mounts()
        self.check_tini_forwards_signals_to_the_dropped_child()
        self.check_entry_window()


if __name__ == '__main__':
    unittest.main()
