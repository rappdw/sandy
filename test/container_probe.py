#!/usr/bin/env python3
"""Deterministic agent fixture; runs through Sandy's real generated entrypoint."""
import errno
import json
import os
from pathlib import Path
import shutil
import re
import subprocess
import sys


def main():
    if '--version' in sys.argv:
        print('99.0.0 (Sandy test fixture)')
        return
    if '-p' not in sys.argv and '--print' not in sys.argv:
        return  # Incidental plugin/config invocations are not probe completions.
    workspace = Path(os.environ['SANDY_WORKSPACE'])
    request = json.loads((workspace / '.probe-request.json').read_text())
    checks = []

    def check(name, condition):
        if not condition:
            raise AssertionError(name)
        checks.append(name)

    def run(*args, cwd=None, env=None):
        result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True, timeout=180)
        if result.returncode != 0:
            raise AssertionError('command failed (exit=' + str(result.returncode) + '): '
                                 + ' '.join(args) + '\n' + result.stdout + result.stderr)
        check('command: ' + ' '.join(args), result.returncode == 0)
        return result.stdout

    def ro_write(path):
        try:
            with path.open('a') as output:
                output.write('unexpected write\n')
        except OSError as error:
            check('read-only mount: ' + str(path), error.errno == errno.EROFS)
        else:
            raise AssertionError('write escaped: ' + str(path))

    mounts = {}
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        fields = line.split()
        mounts[fields[4].replace('\\040', ' ')] = fields[5].split(',')
    check('root mount is read-only', 'ro' in mounts['/'])
    check('host uid preserved', os.getuid() == request['uid'])
    status = dict(line.split(':', 1) for line in Path('/proc/self/status').read_text().splitlines() if ':' in line)
    check('no new privileges', status['NoNewPrivs'].strip() == '1')
    check('no effective capabilities', int(status['CapEff'].strip(), 16) == 0)
    for name in ('.pip-packages', '.local/share/uv', '.npm-global', 'go', '.cargo'):
        target = Path.home() / name
        check('persistent mount: ' + name, 'rw' in mounts.get(str(target), []))
        sentinel = target / 'sandy-test-persistence'
        if request['phase'] == 'verify':
            check('persistent contents: ' + name, sentinel.read_text() == 'retained')
        else:
            check('fresh sandbox: ' + name, not sentinel.exists())
            sentinel.write_text('retained')
    for target in (Path('/tmp/sandy-test-write'), Path.home() / 'sandy-test-write', workspace / 'ordinary-file'):
        target.write_text('writable')
        check('positive write control: ' + str(target), target.read_text() == 'writable')
    for relative in request['protected']:
        target = workspace / relative
        check('protected content readable: ' + relative, target.read_text() == request['protected'][relative])
        ro_write(target)
    for relative in request['protected_directories']:
        target = workspace / relative
        check('directory mount is read-only: ' + relative, 'ro' in mounts.get(str(target), []))
        ro_write(target / 'sandy-test-new-file')
    head = workspace / '.git/HEAD'
    original_head = head.read_text()
    head.write_text(original_head)
    check('Git HEAD remains writable', head.read_text() == original_head)
    for relative in request['absent']:
        target = workspace / relative
        if request['phase'] != 'verify':
            check('absent path has no overlay: ' + relative, str(target) not in mounts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('created by fixture')
        else:
            check('new protected content survives', target.read_text() == 'created by fixture')
            ro_write(target)
    for name in ('commands', 'agents', 'plugins'):
        target = workspace / '.claude' / name
        expected = 'sandbox-copy' if request['phase'] == 'verify' else 'host'
        check('workspace ' + name + ' seeded once', (target / 'host-only').read_text() == expected)
        if request['phase'] == 'verify':
            check('workspace overlay persists: ' + name, (target / 'agent-only').read_text() == 'sandbox')
        else:
            (target / 'host-only').write_text('sandbox-copy')
            (target / 'agent-only').write_text('sandbox')
    check('staged context excludes config', not Path('/opt/sandy-test-context/config').exists())
    check('staged context excludes secrets', not Path('/opt/sandy-test-context/.secrets').exists())
    check('local bin first', os.environ['PATH'].split(':')[0] == str(Path.home() / '.local/bin'))
    for command in (('python3', '--version'), ('node', '--version'), ('go', 'version'),
                    ('rustc', '--version'), ('cargo', '--version'), ('uv', '--version'),
                    ('gcc', '--version'), ('git', '--version'), ('git', 'lfs', 'version')):
        run(*command)
    check('real startup configures LFS', 'git-lfs smudge' in run('git', 'config', '--get', 'filter.lfs.smudge'))
    socket = '/tmp/sandy-test-tmux.sock'
    try:
        run('tmux', '-S', socket, '-f', '/etc/tmux.conf', 'new-session', '-d', '-s', 'fixture', 'sleep 30')
        keys = run('tmux', '-S', socket, 'list-keys', '-T', 'prefix')
        for key, direction in (('H', 'L'), ('J', 'D'), ('K', 'U'), ('L', 'R')):
            check('real tmux resize binding: ' + key, re.search(
                r'^bind-key\s+-r\s+-T prefix\s+' + key + r'\s+resize-pane -' + direction + r' 5$', keys, re.M))
    finally:
        subprocess.run(['tmux', '-S', socket, 'kill-server'], capture_output=True)
    fixture = workspace / 'fixtures'
    if request['phase'] == 'install':
        run('pip', 'install', '--no-index', '--no-deps', str(fixture / 'sandy_fixture-1.0-py3-none-any.whl'))
        run('npm', 'install', '-g', '--offline', '--ignore-scripts', '--no-audit', '--no-fund', str(fixture / 'npm'))
        run('go', 'install', '.', cwd=fixture / 'go', env={**os.environ, 'GOPROXY': 'off', 'GOTOOLCHAIN': 'local'})
        run('cargo', 'install', '--offline', '--path', str(fixture / 'rust'))
        venv = Path('/tmp/sandy-test-venv')
        run('python3', '-m', 'venv', str(venv))
        # Call the production wrapper explicitly, even though activation also
        # adds the virtualenv's own pip to PATH.
        run('bash', '-c', 'source "$1/bin/activate"; "$HOME/.local/bin/pip" install --no-index --no-deps "$2"',
            '_', str(venv), str(fixture / 'sandy_venv_fixture-1.0-py3-none-any.whl'))
        check('venv installs stay in venv', 'sandy_venv_fixture' in run(str(venv / 'bin/python'), '-c',
              'import sandy_venv_fixture; print(sandy_venv_fixture.__file__)'))
        check('venv package absent from user site', subprocess.run(
            ['python3', '-c', 'import sandy_venv_fixture'], capture_output=True).returncode != 0)
    if request['phase'] in ('install', 'verify'):
        check('pip import works', run('python3', '-c', 'import sandy_fixture; print(sandy_fixture.VALUE)').strip() == 'fixture')
        for binary in ('sandy-npm-fixture', 'sandy-go-fixture', 'sandy-rust-fixture'):
            check('installed command works: ' + binary, run(binary).strip() == 'fixture')
    else:
        check('pip isolated across workspaces', subprocess.run(
            ['python3', '-c', 'import sandy_fixture'], capture_output=True).returncode != 0)
        for binary in ('sandy-npm-fixture', 'sandy-go-fixture', 'sandy-rust-fixture'):
            check('binary isolated: ' + binary, shutil.which(binary) is None)
    print('SANDY_PROBE:' + json.dumps({'phase': request['phase'], 'checks': checks}))


if __name__ == '__main__':
    main()
