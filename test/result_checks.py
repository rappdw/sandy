"""Independent completion evidence for shell test harnesses (stdlib only)."""
import re
import sys
from pathlib import Path
import os
import signal
import subprocess


def answer_ok(status, word, output):
    """A successful process must emit the answer, not just echo its prompt."""
    if status != 0:
        return False
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", output)
    return any(line.strip().strip("`* .!\r").casefold() == word.casefold()
               for line in text.splitlines())


def probe_ok(status, output, expected):
    # Infrastructure failure, an empty probe, or contradictory results cannot
    # count as an isolation success. The probe reports after attempting I/O.
    prefix = expected.rsplit('_', 1)[0] + '_'
    markers = [line for line in output.splitlines() if line == expected or line.startswith(prefix)]
    return status == 0 and markers == [expected]


def acceptance_ok(status, output):
    results = re.findall(r"^RESULT: (\d+) passed, (\d+) failed(?: .*)?$",
                         re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", output), re.M)
    return (status == 0 and len(results) == 1
            and int(results[0][0]) > 0 and int(results[0][1]) == 0)


def selection_errors(source, only, skip):
    known = set(re.findall(r'^\s*section "([0-9]+[a-z]?)\.', source, re.M))
    if not known:
        return ['could not find integration section IDs']
    errors = []
    for name, values in (('ONLY', only), ('SKIP', skip)):
        if values:
            for token in values.split(','):
                if token.strip() not in known:
                    errors.append('SANDY_INTEG_' + name + ': unknown section ' + repr(token.strip()))
    if only and not (set(only.replace(' ', '').split(',')) - set(skip.replace(' ', '').split(','))):
        errors.append('selection would run no sections')
    return errors


def run_with_timeout(seconds, command):
    """Portable timeout: terminate the process group and retain command status."""
    try:
        process = subprocess.Popen(command, start_new_session=True)
    except FileNotFoundError:
        return 127
    try:
        status = process.wait(timeout=seconds)
        return status if status >= 0 else 128 - status
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        return 124


if __name__ == "__main__":
    if sys.argv[1] == 'timeout':
        sys.exit(run_with_timeout(float(sys.argv[2]), sys.argv[3:]))
    if sys.argv[1] == 'selection':
        errors = selection_errors(Path(sys.argv[2]).read_text(), sys.argv[3], sys.argv[4])
        for error in errors:
            print(error, file=sys.stderr)
        sys.exit(2 if errors else 0)
    mode, status, *args = sys.argv[1:]
    text = sys.stdin.read()
    checks = {"answer": answer_ok, "probe": lambda rc, marker, text: probe_ok(rc, text, marker)}
    ok = (acceptance_ok(int(status), text) if mode == "acceptance"
          else checks[mode](int(status), args[0], text))
    sys.exit(0 if ok else 1)
