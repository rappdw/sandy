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


if __name__ == '__main__':
    unittest.main()
