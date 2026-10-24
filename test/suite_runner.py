"""Select isolated test groups, record timings, and retain diagnostic logs."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from log_paths import start_run

ROOT = Path(__file__).resolve().parent.parent
GROUPS = {
    "harness": [sys.executable, "test/test_harness.py", "-v"],
    "contracts": [sys.executable, "test/test_production_contracts.py", "-v"],
    "host": ["bash", "test/run-tests.sh"],
    "container": [sys.executable, "test/test_container.py", "-v"],
    "proxy": ["go", "test", "-race", "./..."],
}
GROUP_TITLES = {
    "harness": "Test harness regressions",
    "contracts": "Production behavior contracts",
    "host": "Host checks",
    "container": "Container launch, persistence, and isolation",
    "proxy": "Go proxy race tests",
}


def show_output(line, group, verbose, in_traceback):
    """Keep test names/results visible; full Python failure details stay in logs."""
    if verbose or group not in ("harness", "contracts", "container"):
        return True, in_traceback
    if line.strip() == "=" * 70:
        return False, True
    if not in_traceback:
        return True, False
    return line.startswith(("ERROR: ", "FAIL: ", "Ran ", "FAILED", "OK")), True


def finish_suite(results):
    print("\n========== SUITE SUMMARY ==========", flush=True)
    for result in results:
        print("{group}: {state} ({seconds}s, {skips} skips) — {log}".format(**result))
    failed = [result for result in results if result['state'] == 'failed']
    partial = [result for result in results if result['state'] in ('partial', 'skipped')]
    if failed:
        print("\nSUITE FAILED — failed groups: " + ', '.join(result['group'] for result in failed) + " (exit 1)", flush=True)
        for result in failed:
            print("  {} failure details: {}".format(result['group'], result['log']), flush=True)
        return 1
    if not results or all(result['state'] == 'skipped' for result in results):
        print("\nSUITE FAILED — no test groups ran (exit 1)", flush=True)
        return 1
    if partial:
        print("\nSUITE COMPLETE WITH SKIPS — no failures; coverage is incomplete in: "
              + ', '.join(result['group'] for result in partial) + " (exit 0)", flush=True)
    else:
        print("\nSUITE PASSED — all {} selected groups passed (exit 0)".format(len(results)), flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="comma-separated groups (see --list)")
    parser.add_argument("--host-only", action="store_true", help="harness, contracts, host; no Docker or tmux")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("-v", "--verbose", action="store_true", help="also print full failure tracebacks (always saved in logs)")
    parser.add_argument("--require-tools", action="store_true", help="fail if the declared CI tool set is missing")
    parser.add_argument("--log-dir", type=Path, help="log root (default: workspace .test_output); retain three runs")
    args = parser.parse_args()
    if args.list:
        print("\n".join(GROUPS))
        return 0
    if args.host_only and args.only:
        parser.error("use --host-only or --only, not both")
    selected = (args.only.split(",") if args.only else
                ["harness", "contracts", "host"] if args.host_only else list(GROUPS))
    selected = [name.strip() for name in selected]
    if any(name not in GROUPS for name in selected) or len(selected) != len(set(selected)):
        parser.error("unknown or repeated group; use --list")
    if args.require_tools:
        required = {"bash", "git", "python3"}
        if "host" in selected:
            required.update(("node", "jq", "shellcheck", "flock", "ssh", "ssh-keygen"))
        if "contracts" in selected:
            required.update(("node", "jq"))
        if "container" in selected:
            required.add("docker")
        if "proxy" in selected:
            required.add("go")
        missing = sorted(tool for tool in required if not shutil.which(tool))
        if missing:
            parser.error("required tools missing: " + ", ".join(missing))
    logs = start_run('suite', args.log_dir)
    print("Test logs: " + str(logs), flush=True)
    print("Running {} groups in order: {}".format(len(selected), ' → '.join(selected)), flush=True)
    print("The overall result appears after all selected groups finish.", flush=True)
    cache = os.environ.get("SANDY_HOME", str(Path.home() / ".sandy"))
    results = []
    for index, name in enumerate(selected, 1):
        start = time.monotonic()
        log = logs / (name + ".log")
        group_logs = logs / name
        group_logs.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="sandy-test-" + name + ".") as temporary:
            # macOS temp paths may use /var while pwd -P returns /private/var.
            # Give subprocesses a consistent HOME/TMPDIR/SANDY_HOME identity.
            root = Path(temporary).resolve()
            home = root / "home"
            home.mkdir()
            scratch = root / "tmp"
            scratch.mkdir()
            env = {key: os.environ[key] for key in ("PATH", "TERM", "LANG", "LC_ALL", "USER", "LOGNAME")
                   if key in os.environ}
            env.update(HOME=str(home), TMPDIR=str(scratch), SANDY_HOME=str(home / ".sandy"),
                       SANDY_TEST_CHILD="1", SANDY_TEST_LOG_DIR=str(group_logs),
                       SANDY_TEST_BUILD_CACHE=cache, PYTHONDONTWRITEBYTECODE="1")
            if name in ("host", "contracts", "harness"):
                # Existing tests may ask whether Docker is reachable. They
                # cannot contact a real daemon; their explicit stubs still win.
                blockers = root / "bin"
                blockers.mkdir()
                for tool in ("docker", "tmux"):
                    path = blockers / tool
                    path.write_text('#!/bin/sh\necho "Real runtime disabled in host tests" >&2\nexit 1\n')
                    path.chmod(0o755)
                env["PATH"] = str(blockers) + os.pathsep + env["PATH"]
            command = GROUPS[name]
            print("\n[{}/{}] {} ({})".format(index, len(selected), GROUP_TITLES[name], name), flush=True)
            if not shutil.which(command[0]):
                state, rc = ("failed", 1) if args.require_tools else ("skipped", 77)
                log.write_text("Missing executable: " + command[0] + "\n")
                print(log.read_text(), end="")
            else:
                with log.open("w", buffering=1) as output:
                    process = subprocess.Popen(command, cwd=ROOT / "proxy" if name == "proxy" else ROOT,
                                               env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                               text=True, errors="replace", start_new_session=True)
                    in_traceback = False
                    try:
                        for line in process.stdout:
                            output.write(line)
                            show, in_traceback = show_output(line, name, args.verbose, in_traceback)
                            if show:
                                print(line, end="", flush=True)
                        rc = process.wait()
                    except KeyboardInterrupt:
                        os.killpg(process.pid, signal.SIGTERM)
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait()
                        raise
                    finally:
                        process.stdout.close()
                state = "passed" if rc == 0 else "failed"
            output_text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", log.read_text())
            skips = int(state == "skipped") + len(re.findall(r"^\s*– skipped:", output_text, re.M))
            skips += sum(int(count) for count in re.findall(r"OK \(skipped=(\d+)\)", output_text))
            if state == "passed" and skips:
                state = "partial"
            results.append({"group": name, "state": state, "exit": rc,
                            "skips": skips, "seconds": round(time.monotonic() - start, 2), "log": str(log)})
            (logs / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print("{}: {} ({:.2f}s, {} skips)".format(name, state.upper(), results[-1]['seconds'], skips), flush=True)
            if state == "failed":
                print("Full failure details: " + str(log), flush=True)
                if index < len(selected):
                    print("Continuing with remaining groups; the overall run will report failure.", flush=True)
    return finish_suite(results)


if __name__ == "__main__":
    sys.exit(main())
