"""Normalise a --print-state document built from make-home.sh for comparison.

Usage: python3 normalize.py RAW ROOT LIVE_PID DEAD_PID > OUT

Replaces the three things make-home.sh cannot fix in advance: the fixture
root (ROOT, a temporary directory), the two lock-holder pids, and each
sandbox's size_bytes when it is a number (a du measurement in full mode,
filesystem-dependent; a null stays null, so a number-to-null change shows).
Works on bytes: the document is compared byte for byte, never re-serialised.
"""
import re
import sys

raw, root, live, dead = sys.argv[1:5]
with open(raw, "rb") as fh:
    data = fh.read()
data = data.replace(root.encode(), b"@ROOT@")
for pid, tag in ((live, b"@LIVE@"), (dead, b"@DEAD@")):
    data = data.replace(b'"lock_holder_pid":"' + pid.encode() + b'"',
                        b'"lock_holder_pid":"' + tag + b'"')
data = re.sub(rb'"size_bytes":[0-9]+', b'"size_bytes":"@SIZE@"', data)
sys.stdout.buffer.write(data)
