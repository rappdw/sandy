"""Neutral execution conformance; Docker tests never invoke a model."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

import pytest

HELPER=Path(__file__).parents[1]/'managed_exec.py'


def test_unprivileged_control_is_refused():
    if os.geteuid()==0: pytest.skip('requires an unprivileged caller')
    result=subprocess.run([sys.executable,str(HELPER),'inspect','--namespace','fixture','--execution-id','one'],capture_output=True,text=True)
    assert result.returncode!=0 and 'PermissionError' in result.stderr


@pytest.fixture
def container():
    if shutil.which('docker') is None: pytest.skip('Docker runtime gate is unavailable')
    subprocess.run(['docker','info'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
    name='sandy-exec-test-'+uuid.uuid4().hex[:12]
    subprocess.run(['docker','run','--rm','-d','--name',name,'-v',str(HELPER)+':/managed_exec.py:ro',
                    'python:3.11-slim','sleep','infinity'],capture_output=True,check=True)
    try: yield name
    finally: subprocess.run(['docker','rm','-f',name],capture_output=True,check=True)


def control(container,verb,execution):
    result=subprocess.run(['docker','exec','-u','0',container,'python3','/managed_exec.py',verb,
        '--namespace','fixture','--execution-id',execution],capture_output=True,text=True,check=True,timeout=12)
    return json.loads(result.stdout)['state']


def test_stop_revokes_a_delayed_launch(container):
    assert control(container,'inspect','delayed')=='unknown'
    assert control(container,'stop','delayed')=='stopped'
    result=subprocess.run(['docker','exec','-u','0',container,'python3','/managed_exec.py','launch',
        '--namespace','fixture','--execution-id','delayed','--uid','1000','--gid','1000',
        '--home','/tmp','--cwd','/tmp','--','python3','-c','print("should never execute")'],capture_output=True,text=True)
    assert result.returncode!=0
    assert 'should never execute' not in result.stdout


def test_host_attach_death_preserves_execution_and_stop_reaps_escaped_child(container):
    code='import os,time; p=os.fork(); os.setsid() if p==0 else None; print("escaped-ready",flush=True) if p==0 else None; time.sleep(120)'
    attach=subprocess.Popen(['docker','exec','-i','-u','0',container,'python3','/managed_exec.py','launch',
        '--namespace','fixture','--execution-id','orphan','--uid','1000','--gid','1000',
        '--home','/tmp','--cwd','/tmp','--','python3','-c',code],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            if control(container,'inspect','orphan')=='running': break
            time.sleep(.1)
        else: pytest.fail('owned execution did not start')
        assert attach.stdout.readline().strip()==b'escaped-ready'
        attach.kill(); attach.wait(timeout=5)
        assert control(container,'inspect','orphan')=='running'
        assert control(container,'stop','orphan')=='stopped'
        assert control(container,'inspect','orphan')=='stopped'
        # No unprivileged descendant survived with a new process group.
        scan='from pathlib import Path; print(sum(1 for p in Path("/proc").glob("[0-9]*/status") if "Uid:\\t1000\\t" in p.read_text()))'
        assert subprocess.check_output(['docker','exec',container,'python3','-c',scan],text=True).strip()=='0'
    finally:
        if attach.poll() is None: attach.kill(); attach.wait()
        attach.stdout.close(); attach.stderr.close()


def test_protected_child_mounts_reject_real_uid_mutations(container, tmp_path):
    # The fixture establishes a real daemon; the probe uses an inert image and
    # the host UID that owns the writable parent, so mode bits cannot fake RO.
    parent=tmp_path/'parent'; parent.mkdir()
    results=parent/'results'; results.mkdir()
    (results/'fixture').write_text('retained')
    config=tmp_path/'trusted.toml'; config.write_text('trusted=true')
    code='''import os
open('/data/writable','w').write('parent remains writable')
for call in [lambda:open('/data/results/new','w'),
             lambda:os.rename('/data/results/fixture','/data/results/moved'),
             lambda:os.chmod('/data/results/fixture',0o600),
             lambda:os.symlink('/tmp','/data/results/link'),
             lambda:os.open('/data/config.toml',os.O_WRONLY)]:
 try: call()
 except OSError: continue
 raise RuntimeError('protected child allowed mutation')
print('protected')
'''
    result=subprocess.check_output(['docker','run','--rm','--user',str(os.getuid())+':'+str(os.getgid()),
        '-v',str(parent)+':/data:rw','-v',str(results)+':/data/results:ro',
        '-v',str(config)+':/data/config.toml:ro','python:3.11-slim','python3','-c',code],text=True)
    assert result.strip()=='protected'
    assert (results/'fixture').read_text()=='retained'
    assert config.read_text()=='trusted=true'
