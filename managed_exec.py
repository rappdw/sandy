#!/usr/bin/env python3
"""Linux sandbox execution supervisor. Host callers keep stdio and exact IDs.

Install read-only; launch as root, drop child to requested uid/gid. Private
root records and a subreaper prevent an agent from forging cleanup evidence.
No model, connector or mailbox knowledge lives here.
"""
import argparse
import ctypes
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ROOT = Path('/run/sandy-managed-exec')
stopping = False


def start_token(pid):
    try:
        raw=Path(f'/proc/{pid}/stat').read_text()
        fields=raw[raw.rindex(')')+2:].split()
        return None if fields[0]=='Z' else fields[19]
    except (OSError,ValueError,IndexError): return None


def descendants(pid):
    parents={}
    for path in Path('/proc').glob('[0-9]*/stat'):
        try:
            text=path.read_text(); fields=text[text.rindex(')')+2:].split()
            parents[int(path.parent.name)]=int(fields[1])
        except (OSError,ValueError,IndexError): pass
    found=set()
    while True:
        new={child for child,parent in parents.items() if parent==pid or parent in found}
        if new <= found: return found
        found |= new


def save(path,doc):
    tmp=path.with_suffix('.tmp')
    with tmp.open('w') as f:
        json.dump(doc,f); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,path)
    fd=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)


def terminate_children(timeout=8):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        children=descendants(os.getpid())
        for pid in children:
            try: os.kill(pid,signal.SIGKILL)
            except ProcessLookupError: pass
        while True:
            try:
                pid,_=os.waitpid(-1,os.WNOHANG)
                if pid==0: break
            except ChildProcessError: break
        if not descendants(os.getpid()): return True
        time.sleep(.02)
    return False


def main(argv=None):
    argv=list(sys.argv[1:] if argv is None else argv)
    command=[]
    if '--' in argv:
        split=argv.index('--'); command=argv[split+1:]; argv=argv[:split]
    parser=argparse.ArgumentParser()
    parser.add_argument('verb',choices=['launch','inspect','stop'])
    parser.add_argument('--namespace',required=True)
    parser.add_argument('--execution-id',required=True)
    parser.add_argument('--uid',type=int); parser.add_argument('--gid',type=int)
    parser.add_argument('--home'); parser.add_argument('--cwd')
    parser.add_argument('--env',action='append',default=[])
    args=parser.parse_args(argv)
    for value in (args.namespace,args.execution_id):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}',value):
            raise ValueError('invalid execution identity')
    if os.geteuid()!=0: raise PermissionError('managed execution requires root control')
    ROOT.mkdir(mode=0o700,exist_ok=True)
    if ROOT.is_symlink() or ROOT.stat().st_uid!=0 or ROOT.stat().st_mode & 0o077:
        raise ValueError('control records must be root-private')
    directory=ROOT/args.namespace; directory.mkdir(mode=0o700,exist_ok=True)
    path=directory/(args.execution_id+'.json')
    lock=os.open(directory/(args.execution_id+'.lock'),os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    if args.verb=='launch':
        if args.uid is None or args.uid<=0 or args.gid is None or args.gid<0 or not args.home or not args.cwd:
            raise ValueError('explicit unprivileged identity, home and cwd required')
        if not command: raise ValueError('command required')
        environment={**os.environ,'HOME':args.home}
        for item in args.env:
            key,sep,value=item.partition('=')
            if not sep or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',key):
                raise ValueError('invalid environment override')
            environment[key]=value
        if ctypes.CDLL(None,use_errno=True).prctl(36,1,0,0,0)!=0:
            raise OSError('subreaper support required')
        def stop(*_):
            global stopping
            stopping=True
        signal.signal(signal.SIGTERM,stop); signal.signal(signal.SIGINT,stop)
        record={'pid':os.getpid(),'start':start_token(os.getpid()),'state':'starting'}
        try:
            fcntl.flock(lock,fcntl.LOCK_EX)
            if path.exists(): raise ValueError('execution identity already used or revoked')
            save(path,record)
        finally: os.close(lock)
        def identity():
            os.setsid(); os.setgroups([args.gid]); os.setgid(args.gid); os.setuid(args.uid)
        try:
            process=subprocess.Popen(command,preexec_fn=identity,cwd=args.cwd,
                                     env=environment)
            save(path,{**record,'state':'running'})
            while process.poll() is None and not stopping: time.sleep(.02)
            returncode=process.returncode
        finally:
            cleaned=terminate_children()
            save(path,{**record,'state':'stopped' if cleaned else 'unknown'})
        return 0 if stopping else (returncode if returncode is not None else 1)
    fcntl.flock(lock,fcntl.LOCK_EX)
    if not path.exists():
        # Inspection alone cannot prove a daemon has no launch in flight.
        # Stop commits a revocation before reporting cleanup. A delayed launch
        # must acquire this same lock and then refuse the used identity.
        state='unknown'
        if args.verb=='stop':
            save(path,{'pid':None,'start':None,'state':'stopped'})
            state='stopped'
        os.close(lock)
    else:
        record=json.loads(path.read_text())
        os.close(lock)
        state=record['state']
        live=start_token(record['pid'])==record['start'] and record['start'] is not None
        if state!='stopped':
            state='running' if live else 'unknown'
            if args.verb=='stop' and live:
                os.kill(record['pid'],signal.SIGTERM)
                deadline=time.monotonic()+9
                while time.monotonic()<deadline:
                    record=json.loads(path.read_text())
                    if record['state']=='stopped': state='stopped'; break
                    time.sleep(.02)
                else: state='unknown'
    print(json.dumps({'execution_id':args.execution_id,'state':state}))
    return 0


if __name__=='__main__':
    try: sys.exit(main())
    except Exception as exc:
        print(type(exc).__name__,file=sys.stderr); sys.exit(1)
