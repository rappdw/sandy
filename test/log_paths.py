"""Workspace-visible test logs, retaining the newest three managed runs."""
from datetime import datetime, timezone
import fcntl
import json
from pathlib import Path
import shutil
import sys
import uuid

DEFAULT_ROOT = Path(__file__).resolve().parent.parent / '.test_output'
MARKER = '.sandy-test-run.json'


def start_run(suite, root=None):
    root = Path(root).expanduser().resolve() if root is not None else DEFAULT_ROOT
    root.mkdir(parents=True, exist_ok=True)
    # Serialize directory creation and rotation across simultaneous invocations.
    with (root / '.rotation.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        now = datetime.now(timezone.utc)
        run = root / ('run-' + now.strftime('%Y%m%dT%H%M%S.%fZ-') + uuid.uuid4().hex[:8])
        run.mkdir()
        (run / MARKER).write_text(json.dumps({'suite': suite, 'started': now.isoformat()}) + '\n')
        # Relative target: this link works at both the host and container mount.
        link = root / ('.latest-' + uuid.uuid4().hex)
        try:
            link.symlink_to(run.name, target_is_directory=True)
            link.replace(root / 'latest')
        finally:
            link.unlink(missing_ok=True)
        previous = sorted((path for path in root.glob('run-*')
                           if path != run and not path.is_symlink() and path.is_dir()
                           and (path / MARKER).is_file()), reverse=True)
        for old in previous[2:]:
            shutil.rmtree(old)
    return run


if __name__ == '__main__':
    print(start_run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None))
