"""Run the shared helper and real Codex registration/runtime blocks (§211).

The state payloads mirror Codex 0.164.0 PTY and exec probes. Docker and the
Codex CLI are stubbed here; managed-layer execution belongs to integration.
SANDY_SCRIPT may point at a scratch mutant, never mutate the working tree.
"""
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import test_claude_activity as claude

EVENTS = ('SessionStart SessionEnd UserPromptSubmit PreToolUse PermissionRequest '
          'PostToolUse PreCompact PostCompact SubagentStart SubagentStop Stop Interrupt').split()


def block(start, end):
    text = claude.SANDY.read_text()
    assert text.count(start) == 1 and text.count(end) == 1, (start, end)
    return text.split(start, 1)[1].split(end, 1)[0]


class Codex(claude.States, claude.Subagents, claude.Retention, claude.Robustness):
    agent = 'codex'
    helper_args = ('--agent', 'codex')

    def test_session_name_from_sandys_record(self):
        self.tsv.write_text('launch\tL1\tdone\nctl\tup\ts1\tController\tyes\tnone\t-\n')
        self.hook('UserPromptSubmit')
        self.assertIsNone(self.entry()['session_name'], 'Codex must not pick up a Claude session name')

    def test_interrupt_permission_and_compaction(self):
        self.hook('UserPromptSubmit')
        self.hook('PermissionRequest', tool_name='Bash')
        self.assertEqual(self.entry()['state'], 'waiting')
        self.hook('Interrupt', turn_id='turn-1')
        self.assertEqual(self.entry()['state'], 'idle')
        self.hook('UserPromptSubmit')
        self.hook('SubagentStart', agent_id='child')
        for ev in ('PreCompact', 'PostCompact'):
            self.hook(ev)
            self.assertEqual((self.entry()['state'], self.entry()['subagents_active']), ('working', 1))
            self.assertEqual(self.entry()['last_event'], ev)
        self.hook('Interrupt')
        self.assertEqual((self.entry()['state'], self.entry()['subagents_active']), ('idle', 1))
        self.hook('SubagentStop', agent_id='child')
        self.hook('SessionEnd')
        self.assertEqual(self.entry()['state'], 'ended')

    def test_record_bytes_match_claude_except_agent(self):
        for ev in ('SessionStart', 'UserPromptSubmit', 'Stop', 'SessionEnd'):
            self.hook(ev)
        expected = [p.read_bytes().replace(b'"agent":"codex"', b'"agent":"claude"')
                    for p in sorted(self.out.glob('activity-*'))]
        self.assertEqual(len(expected), 2, 'the byte comparison must include latest and history files')
        self.out = self.td / 'claude-activity'
        self.helper_args = ()
        for ev in ('SessionStart', 'UserPromptSubmit', 'Stop', 'SessionEnd'):
            self.hook(ev)
        self.assertEqual(expected, [p.read_bytes() for p in sorted(self.out.glob('activity-*'))])

    def test_default_homes_and_invalid_agent(self):
        env = {'PATH': os.environ['PATH'], 'HOME': str(self.td)}
        payload = json.dumps({'hook_event_name': 'UserPromptSubmit', 'session_id': 'home-test'})
        def run(args, extra=None):
            r = subprocess.run([sys.executable, '-I', str(self.helper), *args], input=payload,
                               env={**env, **(extra or {})}, capture_output=True, text=True, timeout=10)
            self.assertEqual((r.returncode, r.stdout, r.stderr), (0, '', ''))
        run(['--agent', '../../escape'])
        self.assertFalse((self.td / '.claude').exists())
        run(self.helper_args)
        self.assertTrue((self.td / '.codex/activity/activity-latest.json').is_file())
        run(self.helper_args, {'CODEX_HOME': str(self.td / 'custom')})
        self.assertTrue((self.td / 'custom/activity/activity-latest.json').is_file())
        self.assertFalse((self.td / '.claude').exists())
        run([])
        self.assertTrue((self.td / '.claude/activity/activity-latest.json').is_file())


class Registration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.d = Path(self.temp.name).resolve()
        self.env = {**os.environ, 'HOME': str(self.d), 'D': str(self.d)}

    def shell(self, code, **env):
        r = subprocess.run(['bash', '-c', 'set -euo pipefail\n' + code], env={**self.env, **env},
                           capture_output=True, text=True, timeout=20, stdin=subprocess.DEVNULL)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def policy(self, agent='codex', activity='', launch='L1', skip='true'):
        return self.shell('''
_sandy_agent_has(){ case ",$AGENTS," in *",$1,"*) return 0;; *) return 1;; esac; }
_sandy_launch_dir(){ printf '%s/launch/%s' "$D" "$LAUNCH"; }
info(){ echo "$*" >&2; }
RUN_FLAGS=(); umask 077
''' + block('# BEGIN codex managed requirements', '# END codex managed requirements') + '''
printf '%s\\n' "${RUN_FLAGS[@]+"${RUN_FLAGS[@]}"}"
echo "ACTIVE=$_sandy_codex_policy_act"
''', AGENTS=agent, SANDY_CODEX_ACTIVITY=activity, LAUNCH=launch, SANDY_SKIP_PERMISSIONS=skip)

    def test_gates_fresh_mount_permissions_and_only_hooks(self):
        for agent, value, enabled in [('claude', '1', False), ('gemini', '', False),
                                       ('codex', '0', False), ('claude,codex', '', True),
                                       ('codex', '1', True)]:
            for skip in ('true', 'false'):
                with self.subTest(agent=agent, activity=value, skip=skip):
                    launch = 'case-' + agent + value + skip
                    r = self.policy(agent, value, launch, skip)
                    d = self.d / 'launch' / launch / 'codex-policy'
                    f = d / 'requirements.toml'
                    self.assertEqual(f.exists(), enabled)
                    self.assertIn('ACTIVE=' + str(enabled).lower(), r.stdout)
                    if not enabled:
                        self.assertNotIn('/etc/codex', r.stdout)
                        self.assertEqual('SANDY_CODEX_ACTIVITY=0' in r.stderr, agent == 'codex')
                        continue
                    self.assertIn(str(d) + ':/etc/codex:ro\n', r.stdout)
                    self.assertIn('SANDY_CODEX_ACTIVITY=1\n', r.stdout)
                    self.assertEqual(f.stat().st_mode & 0o777, 0o644)
                    self.assertEqual(d.stat().st_mode & 0o777, 0o755)
                    # Parse the small generated TOML structurally without requiring
                    # Python 3.11/tomllib on a host. Every line must be accounted for;
                    # no other constraint or feature pin can hide between hooks.
                    text = f.read_text()
                    chunks = text.strip().split('\n\n')
                    self.assertEqual(chunks[0], '[hooks]\nmanaged_dir = "/usr/local/bin"')
                    self.assertEqual(len(chunks), len(EVENTS) + 1)
                    seen = []
                    for chunk in chunks[1:]:
                        lines = chunk.splitlines()
                        m = re.fullmatch(r'\[\[hooks\.(\w+)\]\]', lines[0])
                        self.assertIsNotNone(m)
                        event = m[1]; seen.append(event)
                        self.assertEqual(lines[1], '[[hooks.' + event + '.hooks]]')
                        attrs = dict(line.split(' = ', 1) for line in lines[2:])
                        self.assertEqual(set(attrs), {'type', 'command', 'timeout'})
                        self.assertEqual(json.loads(attrs['type']), 'command')
                        self.assertEqual(int(attrs['timeout']), 3)
                        command = json.loads(attrs['command'])
                        self.assertEqual(command, '/usr/local/bin/sandy-claude-activity --agent codex 2>/dev/null; exit 0')
                    self.assertEqual(set(seen), set(EVENTS))
                    before = f.read_bytes()
                    self.policy(agent, '1', launch + '-next', skip)
                    self.assertEqual(f.read_bytes(), before)

    def test_missing_helper_command_is_silent_and_nonblocking(self):
        self.policy()
        text = (self.d / 'launch/L1/codex-policy/requirements.toml').read_text()
        command = json.loads(re.search(r'^command = (.+)$', text, re.M)[1])
        # Force a missing executable even on an image that already has the helper.
        command = command.replace('/usr/local/bin/sandy-claude-activity', str(self.d / 'missing'))
        r = subprocess.run(['sh', '-c', command], input='{}', capture_output=True, text=True, timeout=10)
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, '', ''))

    def test_stale_warning_label_and_gate(self):
        warning = block('# --- BEGIN stale-image codex activity warning', '# --- END stale-image codex activity warning')
        # Markers have trailing comment text; strip that first line.
        warning = warning.split('\n', 1)[1]
        for enabled, label, expect in [('true', '', True), ('true', '1', False), ('false', '', False)]:
            r = self.shell('''
warn(){ echo "$*"; }
docker(){ printf '%s\\n' "$*" >> "$D/calls"; printf '%s' "$LABEL"; }
IMAGE_NAME=fixture
''' + warning + '\necho DONE\n', _sandy_codex_policy_act=enabled, LABEL=label)
            self.assertIn('DONE', r.stdout)
            self.assertEqual('predates SANDY_CODEX_ACTIVITY' in r.stdout, expect)
            calls = self.d / 'calls'
            self.assertEqual(calls.exists(), enabled == 'true')
            if calls.exists():
                self.assertIn('sandy.agent_activity', calls.read_text()); calls.unlink()
        base = claude.SANDY.read_text().split("<<'DOCKERFILE_BASE'\n", 1)[1].split('\nDOCKERFILE_BASE', 1)[0]
        self.assertIn('\nLABEL sandy.agent_activity=1\n', base)
        self.assertIn('\nLABEL sandy.claude_activity=1\n', base)
        self.assertIn('RUN cat > /usr/local/bin/sandy-claude-activity', base)

    def test_runtime_version_disabled_hooks_and_operator_overrides(self):
        code = block('# BEGIN codex activity runtime check', '# END codex activity runtime check')
        for enabled, version, feature, args, warning in [
                ('1', '0.164.0', 'true', [], ''),
                ('1', '1.0.0', 'true', [], ''),
                ('1', '0.163.9', 'true', [], '>= 0.164.0'),
                ('1', 'unknown', 'true', [], '>= 0.164.0'),
                ('1', '0.164.0', 'false', [], 'disabled'),
                ('1', '0.164.0', '', [], 'status could not'),
                ('0', '0.100.0', 'false', [], ''),
                ('1', '0.164.0', 'true', ['--disable', 'hooks'], 'disabled'),
                ('1', '0.164.0', 'true', ['-c', 'features.hooks=false'], 'disabled'),
                ('1', '0.164.0', 'true', ['--disable=hooks'], 'disabled')]:
            with self.subTest(enabled=enabled, version=version, feature=feature, args=args):
                r = self.shell('''
codex(){
    echo called >> "$D/calls"
    if [ "$1" = --version ]; then echo "codex-cli $VERSION"; return; fi
    local value="$FEATURE"
    case "$*" in *"--disable hooks"*|*"--disable=hooks"*|*"features.hooks=false"*) value=false;; esac
    printf 'hooks stable %s\\n' "$value"
}
probe(){
''' + code + '\n}\nprobe ' + shlex.join(args) + '\necho DONE\n',
                               SANDY_CODEX_ACTIVITY=enabled, VERSION=version, FEATURE=feature)
                self.assertEqual(r.stdout, 'DONE\n', 'warnings must never contaminate the agent command')
                if warning: self.assertIn(warning, r.stderr)
                else: self.assertEqual(r.stderr, '')
                calls = self.d / 'calls'
                self.assertEqual(calls.exists(), enabled == '1')
                if calls.exists(): calls.unlink()

    def test_real_command_builder_preserves_arguments(self):
        text = claude.SANDY.read_text()
        builder = text.split('build_codex_cmd() {', 1)[1].split('\nbuild_opencode_cmd()', 1)[0]
        r = self.shell("""
codex(){
    case "$1" in
        --version) echo 'codex-cli 0.164.0';;
        --help) echo '--no-daemon';;
        features) echo 'hooks stable false';;
        *) echo 'unexpected Codex invocation' >&2; return 1;;
    esac
}
_sandy_translate_args(){ shift; printf ' %q' "$@"; }
_sandy_wrap_cmd_exit_pause(){ printf '%s\\n' "$2"; }
_sandy_codex_resume_mode(){ :; }
build_codex_cmd() {
""" + builder + '\nbuild_codex_cmd -p "a prompt with spaces" --disable hooks\n',
                       SANDY_CODEX_ACTIVITY='1', CODEX_MODEL='', SANDY_EFFORT='', SANDY_LOGIN_AGENT='')
        self.assertIn('disabled', r.stderr)
        self.assertEqual(shlex.split(r.stdout), ['codex', 'exec', '--sandbox', 'danger-full-access',
                         '--skip-git-repo-check', '-p', 'a prompt with spaces', '--disable', 'hooks'])

    def test_passive_key_and_default_metadata(self):
        text = claude.SANDY.read_text()
        keys = text.split('SANDY_PASSIVE_KEYS=(', 1)[1].split(')', 1)[0].split()
        self.assertIn('SANDY_CODEX_ACTIVITY', keys)
        self.assertRegex(text, r'(?m)^SANDY_CODEX_ACTIVITY\|bool\|1\|')


if __name__ == '__main__':
    unittest.main(verbosity=2)
