#!/usr/bin/env python3
"""Mutation audit for §211. Only a temporary copy of sandy is ever changed."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT / 'sandy').read_text()
GATES = 'Registration.test_gates_fresh_mount_permissions_and_only_hooks'
RUNTIME = 'Registration.test_runtime_version_disabled_hooks_and_operator_overrides'
STALE = 'Registration.test_stale_warning_label_and_gate'
STATE = 'Codex.test_interrupt_permission_and_compaction'
MUTATIONS = [
    ('agent gate', 'if _sandy_agent_has codex; then', 'if true; then', GATES, '# BEGIN codex managed requirements'),
    ('activity gate', '[ "${SANDY_CODEX_ACTIVITY:-1}" != "0" ]', '[ 1 = 1 ]', GATES, ''),
    ('default on', '${SANDY_CODEX_ACTIVITY:-1}', '${SANDY_CODEX_ACTIVITY:-0}', GATES, ''),
    ('fresh launch', '$(_sandy_launch_dir)/codex-policy', '$D/codex-policy', GATES, ''),
    ('read-only mount', ':/etc/codex:ro', ':/etc/codex:rw', GATES, ''),
    ('readable policy', 'chmod 0644 "$_sandy_codex_policy_dir/requirements.toml"', ':', GATES, ''),
    ('searchable policy directory', 'chmod 0755 "$_sandy_codex_policy_dir"', ':', GATES, ''),
    ('feature pin forbidden', "printf '[hooks]", "printf '[features]\\nhooks = true\\n[hooks]", GATES, ''),
    ('all events', 'Stop Interrupt; do', 'Stop; do', GATES, ''),
    ('runtime check enabled', 'SANDY_CODEX_ACTIVITY=1)', 'SANDY_CODEX_ACTIVITY=0)', GATES, ''),
    ('nonblocking hook', '--agent codex 2>/dev/null; exit 0', '--agent codex 2>/dev/null', 'Registration.test_missing_helper_command_is_silent_and_nonblocking', ''),
    ('silent missing helper', '--agent codex 2>/dev/null; exit 0', '--agent codex; exit 0', 'Registration.test_missing_helper_command_is_silent_and_nonblocking', ''),
    ('stale gate', '[ "${_sandy_codex_policy_act:-false}" = true ]', '[ 1 = 1 ]', STALE, ''),
    ('stale label check', '[ "$_sandy_codex_act_label" != 1 ]', '[ 0 = 1 ]', STALE, ''),
    ('image label', 'LABEL sandy.agent_activity=1', 'LABEL sandy.agent_activity=0', STALE, ''),
    ('runtime gate', '[ "${SANDY_CODEX_ACTIVITY:-0}" = 1 ]', '[ 1 = 1 ]', RUNTIME, ''),
    ('version floor', '"${BASH_REMATCH[2]}" -ge 164', '"${BASH_REMATCH[2]}" -ge 163', RUNTIME, ''),
    ('feature off diagnostic', '$1 == "hooks" && $NF == "true"', '$1 == "hooks"', RUNTIME, ''),
    ('CLI override forwarding', 'codex features list ${_cx_feature_args[@]+"${_cx_feature_args[@]}"}', 'codex features list', RUNTIME, ''),
    ('interrupt mapping', 'AGENT == "codex" and event == "Interrupt"', 'AGENT == "never" and event == "Interrupt"', STATE, ''),
    ('permission mapping', 'AGENT == "codex" and event == "PermissionRequest"', 'AGENT == "never" and event == "PermissionRequest"', STATE, ''),
    ('null session name', 'session_name(sid) if AGENT == "claude" else None', 'session_name(sid)', 'Codex.test_session_name_from_sandys_record', ''),
    ('Codex home', 'or Path.home() / ".codex") if AGENT', 'or Path.home() / ".claude") if AGENT', 'Codex.test_default_homes_and_invalid_agent', ''),
    ('unknown agent refused', 'if AGENT is None:', 'if False:', 'Codex.test_default_homes_and_invalid_agent', ''),
    ('passive tier', '    SANDY_CODEX_ACTIVITY\n', '', 'Registration.test_passive_key_and_default_metadata', ''),
    ('directory symlink guard', 'if out.is_symlink():', 'if False:', 'Codex.test_symlinked_activity_dir_is_refused', ''),
    ('file symlink guards', ' | os.O_NOFOLLOW', '', 'Codex.test_never_writes_through_a_planted_link', ''),
    ('atomic replacement', 'os.replace(tmp, out / name)', '(out / name).write_text(text)', 'Codex.test_never_writes_through_a_planted_link', ''),
    ('lock', 'fcntl.flock(lock, fcntl.LOCK_EX)', 'pass', 'Codex.test_concurrent_hooks_lose_no_session', ''),
    ('session id validation', 'if not event or not sid:', 'if not event:', 'Codex.test_bad_input_prints_nothing_and_records_nothing', ''),
]


def run(source, *tests):
    return subprocess.run([sys.executable, str(ROOT / 'test/test_codex_activity.py'), *tests],
                          env={**os.environ, 'SANDY_SCRIPT': str(source)},
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)


with tempfile.TemporaryDirectory(prefix='sandy-codex-mutations-') as td:
    scratch = Path(td) / 'sandy'
    scratch.write_text(SOURCE)
    baseline = run(scratch)
    if baseline.returncode:
        sys.exit('Baseline failed; no mutations attempted:\n' + baseline.stdout)
    survived = []
    for name, old, new, test, anchor in MUTATIONS:
        start = SOURCE.index(anchor) if anchor else 0
        before, tail = SOURCE[:start], SOURCE[start:]
        if old not in tail:
            sys.exit('Mutation anchor missing: ' + name)
        scratch.write_text(before + tail.replace(old, new, 1))
        result = run(scratch, test)
        if result.returncode == 0:
            survived.append(name)
        print(('SURVIVED ' if result.returncode == 0 else 'caught ') + name, flush=True)
    if survived:
        sys.exit('Surviving mutations: ' + ', '.join(survived))
    print('%d/%d mutations caught; production files untouched.' % (len(MUTATIONS), len(MUTATIONS)))
