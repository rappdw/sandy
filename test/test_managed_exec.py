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
