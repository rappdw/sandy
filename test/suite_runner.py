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
# A group is one command or a list of commands run in order into one log.
# contracts runs every host-run Python file, each in its own process. The three
# that are not test_production_contracts.py used to be `check` lines in the host
# group, where a passing check discards its output: a unittest skip ("OK
# (skipped=4)" without jq) reached no log and the group said passed. And the
# macOS job runs harness and contracts only, so it never ran them.
CONTRACT_FILES = ("test_production_contracts.py", "test_claude_usage_statusline.py",
                  "test_claude_activity.py", "test_codex_activity.py")
GROUPS = {
    "harness": [sys.executable, "test/test_harness.py", "-v"],
    "contracts": [[sys.executable, "test/" + name, "-v"] for name in CONTRACT_FILES],
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

# --- The host group, one section per process ----------------------------------
# test/run-tests.sh is a preamble (helpers and shared fixtures), then sections,
# then an epilogue (the summary). A section starts at a line matching
# SECTION_START and runs to the next such line; the epilogue starts at the last
# line that is exactly SECTION_CLOSE. A section can therefore run alone, as
# preamble + section + epilogue, and several can run side by side.
SECTION_START = re.compile(r'^(section "|info "[0-9])')
SECTION_CLOSE = "_test_section_close"
TIMES_FILE = "host-section-times.json"  # in the log root: seconds per section, from the last run
SECTION_TIMEOUT = 900       # seconds one section may run; SANDY_TEST_SECTION_TIMEOUT overrides
KILL_GRACE = 5              # seconds between SIGTERM and SIGKILL for a section's process group
PROGRESS_SECONDS = 10       # print a progress line when the console has been quiet this long
POLL_SECONDS = 0.02
TAIL_LINES = 15             # how much of an unfinished section's output is repeated above the summary
ESCAPES = r"(?:\x1b\[[0-?]*[ -/]*[@-~]|\x1b[>=])"


class Section:
    """One section of the host script: where it lies and what it is called."""

    def __init__(self, position, start, end, header):
        self.position, self.start, self.end = position, start, end
        quoted = re.match(r'^(?:section|info) "((?:[^"\\]|\\.)*)"', header)
        # The title as the script prints it: the shell's escapes undone.
        self.title = re.sub(r'\\([$`"\\])', r"\1", quoted.group(1)) if quoted else header
        # "§248: ..." is §248 and "9z1. ..." is 9z1; --sections also takes 248.
        self.label = re.split(r"[:.]", self.title, maxsplit=1)[0].strip()
        self.key = self.label.lstrip("§")


class HostScript:
    """The host script split into its preamble, sections and epilogue."""

    def __init__(self, path):
        self.lines = Path(path).read_text(encoding="utf-8").split("\n")
        starts = [index for index, line in enumerate(self.lines) if SECTION_START.match(line)]
        closes = [index for index, line in enumerate(self.lines) if line == SECTION_CLOSE]
        if not starts or not closes or closes[-1] <= starts[-1]:
            raise ValueError("{} has no sections followed by a final {} line".format(path, SECTION_CLOSE))
        self.epilogue = closes[-1]
        self.sections = [Section(position, start, starts[position] if position < len(starts) else self.epilogue,
                                 self.lines[start]) for position, start in enumerate(starts, 1)]
        self._blank = self.lines[:starts[0]] + [""] * (self.epilogue - starts[0]) + self.lines[self.epilogue:]

    def script(self, section=None):
        """The file with every section but this one replaced by empty lines.

        Line numbers are those of the real file, so an error names a real line.
        With no section it is the preamble and the epilogue: the summary run."""
        lines = list(self._blank)
        if section is not None:
            lines[section.start:section.end] = self.lines[section.start:section.end]
        return "\n".join(lines)

    def select(self, names):
        """The sections labelled by a comma-separated list, in file order."""
        wanted = []
        for name in names.split(","):
            name = name.strip().lstrip("§")
            if name and name not in wanted:
                wanted.append(name)
        known = {section.key for section in self.sections}
        unknown = [name for name in wanted if name not in known]
        if not wanted:
            raise ValueError("--sections names no section")
        if unknown:
            raise ValueError("no section is labelled {}; --list-sections prints the labels".format(", ".join(unknown)))
        return [section for section in self.sections if section.key in wanted]


def commands_of(name):
    commands = GROUPS[name]
    return commands if isinstance(commands[0], list) else [commands]


def host_script():
    """(the host group's script, split; None) or (None, why it cannot be split)."""
    commands = commands_of("host") if "host" in GROUPS else []
    if len(commands) != 1 or len(commands[0]) != 2 or Path(commands[0][0]).name != "bash":
        return None, "the host group is not one `bash SCRIPT` command"
    try:
        return HostScript(ROOT / commands[0][1]), None
    except (OSError, ValueError) as error:
        return None, str(error)


def bash_problem(major):
    """Why a bash of this major version cannot run host sections; None when it can."""
    if major >= 5:
        return None
    if major == 0:
        return "could not tell which bash is on PATH (`bash -c` failed or took over 30s)"
    return "the bash on PATH is version {}; host sections need bash 5 or newer".format(major)


def jobs_argument(text):
    if text == "auto":
        return text
    try:
        number = int(text)
    except ValueError:
        number = 0
    if number < 1:
        raise argparse.ArgumentTypeError("expected a number from 1 up, or auto: " + repr(text))
    return number


def process_headroom(cgroup=Path("/sys/fs/cgroup")):
    """How many workers the cgroup's process limit leaves room for; None when it sets none.

    A section's process tree is budgeted at 100 processes, and 100 are left
    for everything else in the cgroup (inside sandy the limit is 512)."""
    try:
        limit = int((cgroup / "pids.max").read_text())
        used = int((cgroup / "pids.current").read_text())
    except (OSError, ValueError):  # no cgroup v2 (macOS), or pids.max is "max"
        return None
    return max(1, (limit - used - 100) // 100)


def auto_jobs(cpus=None, cgroup=Path("/sys/fs/cgroup")):
    """--jobs auto: one worker per CPU, at most 12, and no more than the process limit allows."""
    if cpus is None:
        try:
            cpus = len(os.sched_getaffinity(0))
        except AttributeError:  # macOS
            cpus = os.cpu_count() or 1
    headroom = process_headroom(cgroup)
    return max(1, min(cpus, 12, headroom if headroom is not None else 12))


def start_order(sections, seconds):
    """Longest first, so the long sections do not end up alone at the end.

    A section's length is its time in the last run. One the last run did not
    time is placed by its line count, scaled by what the timed ones took per
    line; with no times at all the order is by line count."""
    timed = [section for section in sections if section.title in seconds]
    lines = sum(section.end - section.start for section in timed)
    rate = sum(seconds[section.title] for section in timed) / lines if lines else 1.0

    def estimate(section):
        return seconds.get(section.title, (section.end - section.start) * rate)
    return sorted(sections, key=lambda section: (-estimate(section), section.position))


def load_times(path, field="seconds", kind=float):
    """One field of the last run's record, by section title: "seconds" (its time) or "checks" (how many ran)."""
    try:
        return {str(title): kind(value) for title, value in json.loads(path.read_text())[field].items()}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return {}


def save_times(path, seconds, sections, checks=None):
    """Keep the times and check counts of the sections that still exist, in file order."""
    record = {"seconds": {section.title: round(seconds[section.title], 2) for section in sections
                          if section.title in seconds}}
    if checks is not None:
        record["checks"] = {section.title: checks[section.title] for section in sections if section.title in checks}
    temporary = path.with_name("{}.{}.tmp".format(path.name, os.getpid()))
    try:
        temporary.write_text(json.dumps(record, indent=1) + "\n")
        os.replace(temporary, path)
    except OSError:  # the cache only orders the next run
        temporary.unlink(missing_ok=True)


def read_counts(path):
    """(passed, failed, skipped, failed-check names) from a counts file; None unless it is complete.

    The script's epilogue writes and reads the same format: NUL-ended fields,
    the three counters, the number of names, then the names."""
    try:
        fields = Path(path).read_bytes().split(b"\0")
        passed, failed, skipped, names = (int(field) for field in fields[:4])
    except (OSError, ValueError):
        return None
    if min(passed, failed, skipped, names) < 0 or len(fields) != names + 5 or fields[-1]:
        return None
    return passed, failed, skipped, fields[4:-1]


def write_counts(path, passed, failed, skipped, names):
    fields = [str(number).encode() for number in (passed, failed, skipped, len(names))] + list(names)
    Path(path).write_bytes(b"".join(field + b"\0" for field in fields))


def whole_lines(text):
    """A section's output as whole lines, ready to be followed by the next section's.

    The script's EXIT trap resets the terminal keypad after its last line. Once
    per run is right (the summary run prints it); between sections it would
    glue an escape sequence to the front of the next header."""
    head, newline, last = text.rpartition("\n")
    if re.fullmatch(ESCAPES + "*", last):
        return head + newline
    return text + "\n"


def bash_major(interpreter):
    """The major version of the bash that would run a section; 0 when it will not say."""
    try:
        run = subprocess.run([interpreter, "-c", 'printf %s "${BASH_VERSINFO[0]}"'], stdin=subprocess.DEVNULL,
                             capture_output=True, text=True, timeout=30)
        return int(run.stdout) if run.returncode == 0 else 0
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0


def isolated_env(root, logs, cache, blockers):
    """A fresh HOME, TMPDIR and SANDY_HOME under root; of the caller's environment only PATH, terminal and locale."""
    home = root / "home"
    home.mkdir()
    scratch = root / "tmp"
    scratch.mkdir()
    env = {key: os.environ[key] for key in ("PATH", "TERM", "LANG", "LC_ALL", "USER", "LOGNAME")
           if key in os.environ}
    env.update(HOME=str(home), TMPDIR=str(scratch), SANDY_HOME=str(home / ".sandy"),
               SANDY_TEST_CHILD="1", SANDY_TEST_LOG_DIR=str(logs),
               SANDY_TEST_BUILD_CACHE=cache, PYTHONDONTWRITEBYTECODE="1")
    if blockers:
        # Existing tests may ask whether Docker is reachable. They
        # cannot contact a real daemon; their explicit stubs still win.
        directory = root / "bin"
        directory.mkdir()
        for tool in ("docker", "tmux"):
            path = directory / tool
            path.write_text('#!/bin/sh\necho "Real runtime disabled in host tests" >&2\nexit 1\n')
            path.chmod(0o755)
        env["PATH"] = str(directory) + os.pathsep + env["PATH"]
    return env


def signal_group(pid, signum):
    try:
        os.killpg(pid, signum)
    except (ProcessLookupError, PermissionError):
        pass


class Job:
    """One section's process, from its start to how it ended."""

    def __init__(self, section):
        self.section = section
        self.process = self.home = None
        self.started = time.monotonic()
        self.term_at = self.kill_at = None  # when its time limit signalled the process group
        self.timed_out = False
        self.seconds = 0.0
        self.counts = None   # what the section reported: passed, failed, skipped, failed-check names
        self.reason = None   # why it counts as failed although no check of its own says so
        self.text = ""

    def failed(self):
        return bool(self.reason or self.counts[1])


class NothingAhead:
    """No group runs beside the host group's sections."""

    def busy(self):
        return 0

    def poll(self):
        return True


class SectionRun:
    """Run sections of the host script, each in its own process, `jobs` at a time.

    Every section gets what a group gets (its own HOME, TMPDIR, SANDY_HOME,
    blocker directory and check-log directory), /dev/null on stdin and its own
    process group. Output is held per section and printed in file order; then
    the script's epilogue runs once on the totals and prints the one summary."""

    def __init__(self, host, chosen, jobs, jobs_label, command, logs, root, cache, output, times_path, limit,
                 ahead=None):
        self.host, self.chosen, self.jobs, self.jobs_label = host, chosen, jobs, jobs_label
        # Groups running beside the sections: they hold slots, and print first.
        self.ahead = ahead or NothingAhead()
        self.opened = False
        self.preface = []
        self.interpreter, self.argv0 = command
        self.logs, self.root, self.cache, self.output = logs, root, cache, output
        self.times_path, self.limit = times_path, limit
        self.workers = min(jobs, len(chosen))
        self.total = len(host.sections)
        self.running, self.finished = [], {}
        self.printed = 0
        self.began = self.quiet_since = time.monotonic()

    def name(self, section):
        return "section ({} of {}) {}".format(section.position, self.total, section.label)

    def paths(self, stem):
        return {kind: self.logs / (stem + suffix) for kind, suffix in
                (("script", ".sh"), ("out", ".out"), ("counts", ".counts"), ("checks", ""))}

    def section_paths(self, section):
        return self.paths("section-{:03d}".format(section.position))

    def emit(self, text):
        """Results go to the console and to the group log."""
        self.output.write(text)
        print(text, end="", flush=True)
        self.quiet_since = time.monotonic()

    def prepare(self, paths, section=None):
        """Write the script and make the isolated root one process of the host script runs in."""
        paths["script"].write_text(self.host.script(section), encoding="utf-8")
        paths["checks"].mkdir(exist_ok=True)
        home = tempfile.TemporaryDirectory(prefix=paths["checks"].name + ".", dir=str(self.root))
        env = isolated_env(Path(home.name), paths["checks"], self.cache, True)
        env["SANDY_TEST_ARGV0"] = self.argv0
        return home, env

    def start(self, section):
        job = Job(section)
        paths = self.section_paths(section)
        try:
            job.home, env = self.prepare(paths, section)
            # --jobs is the budget for everything running at once. A section's
            # own background checks get what the sections leave: 1 in a full run.
            env.update(SANDY_TEST_SECTION_POSITION=str(section.position), SANDY_TEST_SECTION_TOTAL=str(self.total),
                       SANDY_TEST_RESULT_FILE=str(paths["counts"]),
                       SANDY_TEST_INNER_JOBS=str(max(1, self.jobs // self.workers)))
            with paths["out"].open("wb") as sink:
                job.process = subprocess.Popen([self.interpreter, str(paths["script"])], cwd=ROOT, env=env,
                                               stdin=subprocess.DEVNULL, stdout=sink, stderr=subprocess.STDOUT,
                                               start_new_session=True)
        except OSError as error:  # no process to be had (a pids limit), or no room for its files
            job.reason = "could not start: {}".format(error)
            self.finish(job, None)
            return
        self.running.append(job)

    def poll(self):
        """Collect the sections that have ended; signal the ones past their time limit."""
        now = time.monotonic()
        for job in list(self.running):
            code = job.process.poll()
            if code is None:
                if job.term_at is None and now - job.started > self.limit:
                    job.timed_out = True
                    job.term_at = now
                    signal_group(job.process.pid, signal.SIGTERM)
                elif job.term_at is not None and job.kill_at is None and now - job.term_at > KILL_GRACE:
                    job.kill_at = now
                    signal_group(job.process.pid, signal.SIGKILL)
                continue
            self.running.remove(job)
            self.finish(job, code)

    def finish(self, job, code):
        """Read what a section left, decide how it ended, and remove what a passing one needs no more."""
        paths = self.section_paths(job.section)
        job.seconds = time.monotonic() - job.started
        if job.process is not None:
            # Anything the section left running would outlive its HOME.
            signal_group(job.process.pid, signal.SIGKILL)
        job.counts = read_counts(paths["counts"])
        ended = "was killed by signal {}".format(-code) if code is not None and code < 0 else "exited {}".format(code)
        if job.timed_out:
            job.counts = None
            job.reason = "timed out after {:g}s; its process group was killed".format(self.limit)
        elif job.reason is None and job.counts is None:
            job.reason = ended + " without reporting a result (a command failed under set -e, or it called exit)"
        elif job.reason is None and code != 0 and job.counts[1] == 0:
            job.reason = ended + " after reporting no failed check"
        try:
            with paths["out"].open(errors="replace") as source:
                job.text = whole_lines(source.read())
        except OSError:
            job.text = ""
        if job.reason:
            job.text += "  \033[0;31m✗ {}: {}\033[0m\n".format(self.name(job.section), job.reason)
        paths["counts"].unlink(missing_ok=True)
        if not job.failed():
            paths["script"].unlink(missing_ok=True)
            paths["out"].unlink(missing_ok=True)
        self.discard(job.home, paths)
        self.finished[job.section.position] = job

    def discard(self, home, paths):
        try:
            if home is not None:
                home.cleanup()
        except OSError:  # its parent, the group's own directory, is removed at the end
            pass
        try:
            paths["checks"].rmdir()  # kept when a failed check left its log there
        except OSError:
            pass

    def print_ready(self, everything=False):
        """Print finished sections in file order: a later one waits for the earlier ones."""
        while self.printed < len(self.chosen):
            job = self.finished.get(self.chosen[self.printed].position)
            if job is None and not everything:
                break
            if job is not None:
                self.emit(job.text)
            self.printed += 1

    def progress(self):
        now = time.monotonic()
        if now - self.quiet_since < PROGRESS_SECONDS:
            return
        failed = sum(1 for job in self.finished.values() if job.failed())
        print("[host] {}/{} sections finished{} after {:.0f}s; running: {}".format(
            len(self.finished), len(self.chosen), ", {} failed".format(failed) if failed else "", now - self.began,
            ", ".join("{} {:.0f}s".format(job.section.label, now - job.started) for job in self.running) or "none"),
            flush=True)
        self.quiet_since = now

    def totals(self):
        """The counters of every finished section; one that did not finish cleanly adds one failure."""
        passed = failed = skipped = 0
        names = []
        for section in self.chosen:
            job = self.finished.get(section.position)
            if job is None:
                continue
            if job.counts:
                passed, failed, skipped = passed + job.counts[0], failed + job.counts[1], skipped + job.counts[2]
                names += job.counts[3]
            if job.reason:
                failed += 1
                names.append("{}: {}".format(self.name(section), job.reason).encode())
        return passed, failed, skipped, names

    def stop(self):
        """An interrupt: end every running section's process group, then print what there is."""
        stopped = list(self.running)
        for job in stopped:
            signal_group(job.process.pid, signal.SIGTERM)
        deadline = time.monotonic() + KILL_GRACE
        for job in stopped:
            try:
                job.process.wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                signal_group(job.process.pid, signal.SIGKILL)
                job.process.wait()
            job.reason = "interrupted"
            self.finish(job, job.process.returncode)
        del self.running[:]
        self.print_ready(everything=True)
        passed, failed, _, names = self.totals()
        self.emit("\n\033[0;31m✗ host group interrupted: {} of {} sections finished, {} stopped while running, "
                  "{} not started\033[0m\n\033[0;33mPartial results: {} passed, {} failed\033[0m\n".format(
                      len(self.finished) - len(stopped), len(self.chosen), len(stopped),
                      len(self.chosen) - len(self.finished), passed, failed))
        for name in names:
            self.emit("  \033[0;31m- {}\033[0m\n".format(name.decode("utf-8", "replace")))

    def emptied(self, checks):
        """Sections that ran no check although the last run counted some: coverage lost without a failure."""
        found = []
        for section in self.chosen:
            job = self.finished[section.position]
            if job.counts and not job.reason and sum(job.counts[:3]) == 0 and checks.get(section.title, 0) > 0:
                found.append((section, checks[section.title]))
        return found

    def summary(self, emptied=()):
        """Run the script's own epilogue once, on the totals: one source for the summary lines."""
        paths = self.paths("summary")
        totals = self.totals()
        home, env = self.prepare(paths)
        write_counts(paths["counts"], *totals)
        env["SANDY_TEST_TOTALS_FILE"] = str(paths["counts"])
        try:
            run = subprocess.run([self.interpreter, str(paths["script"])], cwd=ROOT, env=env,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, errors="replace", timeout=self.limit, start_new_session=True)
            ended, text = "exited {}".format(run.returncode), run.stdout
        except subprocess.TimeoutExpired as expired:
            ended, text = "timed out", expired.stdout or ""
            text = text if isinstance(text, str) else text.decode(errors="replace")
        body = whole_lines(text)
        self.emit(body)
        for section, before in emptied:
            self.emit("\033[0;31m⚠ Host group: {} ran no check, and the last run counted {} in it; its checks no "
                      "longer run.\033[0m\n".format(self.name(section), before))
        if len(self.chosen) < self.total:
            self.emit("\033[0;33mHost group: {} of the {} sections ran (--sections); the others did NOT run "
                      "here.\033[0m\n".format(len(self.chosen), self.total))
        self.emit(text[len(body):] if text.startswith(body) else "")  # the terminal reset stays last
        complete = ended == "exited {}".format(1 if totals[1] else 0) and "host group complete" in text
        if complete:
            paths["script"].unlink(missing_ok=True)
            paths["counts"].unlink(missing_ok=True)
        else:
            self.emit("\n\033[0;31m✗ host group: the summary step {} without printing the summary; the sections "
                      "reported {} passed, {} failed\033[0m\n".format(ended, totals[0], totals[1]))
        self.discard(home, paths)
        return complete

    def gate(self):
        """True once the groups ahead have printed; then the host block may print."""
        if not self.opened and self.ahead.poll():
            self.opened = True
            for line in self.preface:
                print(line, flush=True)
            self.quiet_since = time.monotonic()
        return self.opened

    def slots(self):
        return min(self.workers, self.jobs - self.ahead.busy())

    def run(self):
        seconds = load_times(self.times_path)
        waiting = start_order(self.chosen, seconds)
        self.preface.append("Host sections: {} of {}, {} at a time (--jobs {}), longest first ({})".format(
            len(self.chosen), self.total, self.workers, self.jobs_label,
            "by the last run's times" if any(section.title in seconds for section in self.chosen)
            else "by line count: no times from an earlier run"))
        self.gate()
        restore = {}

        def interrupt(signum, frame):
            raise KeyboardInterrupt
        for signum in (signal.SIGTERM, signal.SIGHUP):
            try:
                restore[signum] = signal.signal(signum, interrupt)
            except ValueError:  # not the main thread: only Ctrl-C reaches us
                pass
        try:
            while waiting or self.running or not self.gate():
                while waiting and len(self.running) < self.slots():
                    self.start(waiting.pop(0))
                before = len(self.finished)
                self.poll()
                if self.gate():
                    self.print_ready()
                    self.progress()
                if len(self.finished) == before:
                    time.sleep(POLL_SECONDS)
        except KeyboardInterrupt:
            self.stop()
            raise
        finally:
            for signum, handler in restore.items():
                signal.signal(signum, handler)
        # Repeated behind "| ": a tool that counts check lines must not count these twice.
        for section in self.chosen:
            job = self.finished[section.position]
            if job.reason:
                paths = self.section_paths(section)
                self.emit("\n\033[0;31m── {} did not finish: {}\033[0m\n   The last lines of its output:\n{}"
                          "   Full output: {}\n   Script as run: {}\n".format(
                              self.name(section), job.reason,
                              "".join("   | " + line + "\n" for line in job.text.split("\n")[:-2][-TAIL_LINES:]),
                              paths["out"], paths["script"]))
        checks = load_times(self.times_path, "checks", int)
        complete = self.summary(self.emptied(checks))
        for job in self.finished.values():
            if job.counts and not job.reason:
                seconds[job.section.title] = job.seconds
                checks[job.section.title] = sum(job.counts[:3])
        save_times(self.times_path, seconds, self.host.sections, checks)
        return 0 if complete and self.totals()[1] == 0 else 1


class GroupsAlongside:
    """Groups that run while the host group's sections do, each holding one --jobs slot while it runs.

    Each keeps its own isolated root and log, exactly as when it runs alone.
    Its output goes only to its log until it ends; then it is printed whole,
    in group order, and the host block (`then`) prints after the last one."""

    def __init__(self, groups, verbose, report, then):
        self.groups, self.verbose, self.report, self.then = groups, verbose, report, then
        self.printed = 0
        self.opened = False

    def start(self):
        for group in self.groups:
            group["start"] = time.monotonic()
            group["rc"], group["process"], group["done"] = 0, None, False
            if group["missing"]:
                group["log"].write_text("Missing executable: " + group["missing"] + "\n")
                self.end(group)
                continue
            group["output"] = group["log"].open("wb")
            group["queue"] = list(group["commands"])
            self.advance(group)

    def advance(self, group):
        """Start the group's next command; end the group when none is left."""
        if group["queue"]:
            group["process"] = subprocess.Popen(group["queue"].pop(0), cwd=ROOT, env=group["env"],
                                                stdin=subprocess.DEVNULL, stdout=group["output"],
                                                stderr=subprocess.STDOUT, start_new_session=True)
        else:
            group["output"].close()
            self.end(group)

    def end(self, group):
        group["seconds"] = time.monotonic() - group["start"]
        group["done"], group["process"] = True, None
        group["temporary"].cleanup()

    def busy(self):
        return sum(1 for group in self.groups if not group["done"])

    def poll(self):
        """Advance the groups, print each finished one in turn; True once all have printed."""
        for group in self.groups:
            if group["process"] is not None:
                code = group["process"].poll()
                if code is not None:
                    # The first failure decides the exit; later commands still run.
                    group["rc"] = group["rc"] or code
                    self.advance(group)
        while self.printed < len(self.groups) and self.groups[self.printed]["done"]:
            self.show(self.groups[self.printed])
            self.printed += 1
        if self.printed == len(self.groups) and not self.opened:
            self.opened = True
            self.then()
        return self.opened

    def show(self, group):
        print("\n[{}/{}] {} ({})".format(group["index"], group["of"], GROUP_TITLES[group["name"]], group["name"]),
              flush=True)
        in_traceback = False
        for line in group["log"].read_text(errors="replace").splitlines(True):
            show, in_traceback = show_output(line, group["name"], self.verbose, in_traceback)
            if show:
                print(line, end="" if line.endswith("\n") else "\n")
        sys.stdout.flush()
        self.report(group)

    def stop(self):
        """An interrupt: end every group still running."""
        running = [group for group in self.groups if group["process"] is not None]
        for group in running:
            signal_group(group["process"].pid, signal.SIGTERM)
        deadline = time.monotonic() + KILL_GRACE
        for group in running:
            try:
                group["process"].wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                signal_group(group["process"].pid, signal.SIGKILL)
                group["process"].wait()
            group["output"].close()
            self.end(group)


def show_output(line, group, verbose, in_traceback):
    """Keep test names/results visible; full Python failure details stay in logs."""
    if verbose or group not in ("harness", "contracts", "container"):
        return True, in_traceback
    if line.strip() == "=" * 70:
        return False, True
    if not in_traceback:
        return True, False
    return line.startswith(("ERROR: ", "FAIL: ", "Ran ", "FAILED", "OK")), True


def run_command(command, cwd, env, output, group, verbose):
    """Run one command of a group, teeing its output to the group log; return its exit."""
    process = subprocess.Popen(command, cwd=cwd,
                               env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, errors="replace", start_new_session=True)
    in_traceback = False
    try:
        for line in process.stdout:
            output.write(line)
            show, in_traceback = show_output(line, group, verbose, in_traceback)
            if show:
                print(line, end="", flush=True)
        return process.wait()
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
    parser.add_argument("--jobs", type=jobs_argument, metavar="N|auto",
                        help="host group: sections to run at once, each in its own process (default: "
                             "SANDY_TEST_JOBS, else auto = CPUs, at most 12, fewer under a process limit); "
                             "1 runs the whole file in one process")
    parser.add_argument("--sections", metavar="LIST",
                        help="host group: run only these sections, by label: 248, §248, 9z1 (see --list-sections)")
    parser.add_argument("--list-sections", action="store_true", help="print each host section's position, label and title")
    args = parser.parse_args()
    if args.list:
        print("\n".join(GROUPS))
        return 0
    if args.host_only and args.only:
        parser.error("use --host-only or --only, not both")
    chosen = None
    if args.sections is not None or args.list_sections:
        host, why = host_script()
        if host is None:
            parser.error("cannot list or select host sections: " + why)
        try:
            chosen = host.select(args.sections) if args.sections is not None else host.sections
        except ValueError as error:
            parser.error(str(error))
        if args.list_sections:
            for section in chosen:
                print("{:>3}  {:<6}  {}".format(section.position, section.label, section.title))
            return 0
    selected = (args.only.split(",") if args.only else
                ["harness", "contracts", "host"] if args.host_only else
                ["host"] if chosen else list(GROUPS))
    selected = [name.strip() for name in selected]
    if any(name not in GROUPS for name in selected) or len(selected) != len(set(selected)):
        parser.error("unknown or repeated group; use --list")
    if chosen and "host" not in selected:
        parser.error("--sections selects sections of the host group, which --only leaves out")
    bash_major_seen = None
    if chosen:
        # --sections cannot fall back to the whole file: that would run every section.
        bash_major_seen = bash_major(commands_of("host")[0][0])
        problem = bash_problem(bash_major_seen)
        if problem:
            parser.error("--sections: " + problem)
    try:
        jobs = args.jobs if args.jobs is not None else jobs_argument(os.environ.get("SANDY_TEST_JOBS") or "auto")
    except argparse.ArgumentTypeError as error:
        parser.error("SANDY_TEST_JOBS: " + str(error))
    try:
        limit = float(os.environ.get("SANDY_TEST_SECTION_TIMEOUT") or SECTION_TIMEOUT)
    except ValueError:
        limit = 0
    if not limit > 0:
        parser.error("SANDY_TEST_SECTION_TIMEOUT: expected a number of seconds above 0")
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

    def record(name, index, state, rc, log, seconds):
        output_text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", log.read_text(errors="replace"))
        skips = int(state == "skipped") + len(re.findall(r"^\s*– skipped:", output_text, re.M))
        skips += sum(int(count) for count in re.findall(r"OK \(skipped=(\d+)\)", output_text))
        if state == "passed" and skips:
            state = "partial"
        results.append({"group": name, "state": state, "exit": rc,
                        "skips": skips, "seconds": round(seconds, 2), "log": str(log)})
        (logs / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print("{}: {} ({:.2f}s, {} skips)".format(name, state.upper(), results[-1]['seconds'], skips), flush=True)
        if state == "failed":
            print("Full failure details: " + str(log), flush=True)
            if index < len(selected):
                print("Continuing with remaining groups; the overall run will report failure.", flush=True)

    def missing_of(name):
        return next((command[0] for command in commands_of(name) if not shutil.which(command[0])), None)

    def missing_state():
        return ("failed", 1) if args.require_tools else ("skipped", 77)

    # The host group runs one section per process when more than one may run
    # at once, or when sections were chosen; else the whole file in one
    # process, as it always did. Decided first: the groups before it may run
    # beside its sections.
    host, workers, notes, inner = None, 1, [], None
    if "host" in selected and not missing_of("host"):
        workers = auto_jobs() if jobs == "auto" else jobs
        if chosen or workers > 1:
            host, why = host_script()
            if host is None:
                notes.append("\033[0;31m✗ The host script cannot be split into sections ({}); running the whole file "
                             "in one process.\033[0m".format(why))
            else:
                major = bash_major_seen if bash_major_seen is not None else bash_major(commands_of("host")[0][0])
                why = bash_problem(major)
                if why:
                    # Under an old bash the script refuses by itself; one process says so once.
                    notes.append("Not splitting the host group into sections: {}; running the whole file in one "
                                 "process.".format(why))
                    host = None
        elif jobs == "auto":
            # auto came to one worker (a tight process limit): the one process
            # keeps its own background checks to the same budget.
            inner = "1"  # jobs // workers, as a section gets it
        if host is not None:
            headroom = process_headroom()
            if headroom is not None and min(workers, len(chosen or host.sections)) > headroom:
                notes.append("Note: --jobs {} is more than the process limit here leaves room for ({}); a section "
                             "may fail with 'fork: Resource temporarily unavailable'.".format(workers, headroom))
    # Harness and contracts are short and wait on little: while the sections
    # run they share the --jobs slots, so they cost no time of their own.
    before = selected[:selected.index("host")] if host is not None else []
    alongside = before if before and all(name in ("harness", "contracts") for name in before) else []

    def host_header():
        print("\n[{}/{}] {} ({})".format(selected.index("host") + 1, len(selected), GROUP_TITLES["host"], "host"),
              flush=True)
        for note in notes:
            print(note, flush=True)

    beside = None
    if alongside:
        print("{} run beside the host group's sections, each holding one of the {} slots while it runs; each "
              "group's output is printed whole, in the order above.".format(" and ".join(alongside), workers),
              flush=True)
        groups = []
        for name in alongside:
            group_logs = logs / name
            group_logs.mkdir(exist_ok=True)
            temporary = tempfile.TemporaryDirectory(prefix="sandy-test-" + name + ".")
            groups.append({"name": name, "index": selected.index(name) + 1, "of": len(selected),
                           "commands": commands_of(name), "log": logs / (name + ".log"), "temporary": temporary,
                           "env": isolated_env(Path(temporary.name).resolve(), group_logs, cache, True),
                           "missing": missing_of(name)})

        def report(group):
            state, rc = missing_state() if group["missing"] else (
                "passed" if group["rc"] == 0 else "failed", group["rc"])
            record(group["name"], group["index"], state, rc, group["log"], group["seconds"])
        beside = GroupsAlongside(groups, args.verbose, report, host_header)
        beside.start()
    try:
        for index, name in enumerate(selected, 1):
            if name in alongside:
                continue  # running already; printed in its turn by `beside`
            start = time.monotonic()
            log = logs / (name + ".log")
            group_logs = logs / name
            group_logs.mkdir(exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="sandy-test-" + name + ".") as temporary:
                # macOS temp paths may use /var while pwd -P returns /private/var.
                # Give subprocesses a consistent HOME/TMPDIR/SANDY_HOME identity.
                root = Path(temporary).resolve()
                env = isolated_env(root, group_logs, cache, name in ("host", "contracts", "harness"))
                commands = commands_of(name)
                if name == "host":
                    if beside is None:
                        host_header()
                    if inner:
                        env["SANDY_TEST_INNER_JOBS"] = inner
                else:
                    print("\n[{}/{}] {} ({})".format(index, len(selected), GROUP_TITLES[name], name), flush=True)
                missing = missing_of(name)
                if missing:
                    state, rc = missing_state()
                    log.write_text("Missing executable: " + missing + "\n")
                    print(log.read_text(), end="")
                else:
                    rc = 0
                    with log.open("w", buffering=1) as output:
                        if name == "host" and host is not None:
                            rc = SectionRun(host, chosen or host.sections, workers, str(jobs), commands[0], group_logs,
                                            root, cache, output, logs.parent / TIMES_FILE, limit, beside).run()
                            commands = []
                        for command in commands:
                            # The first failure decides the exit; later commands still run.
                            code = run_command(command, ROOT / "proxy" if name == "proxy" else ROOT,
                                               env, output, name, args.verbose)
                            rc = rc or code
                    state = "passed" if rc == 0 else "failed"
                record(name, index, state, rc, log, time.monotonic() - start)
    except BaseException:
        if beside is not None:
            beside.stop()
        raise
    return finish_suite(results)


if __name__ == "__main__":
    sys.exit(main())
