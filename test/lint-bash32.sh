#!/usr/bin/env bash
# Static lint for macOS (bash 5 + BSD userland) hazards that CI structurally CANNOT see.
#
#   bash test/lint-bash32.sh              # lint the repo's shell scripts
#   bash test/lint-bash32.sh FILE...      # lint specific files
#   bash test/lint-bash32.sh --self-test  # prove the detectors actually detect
#   bash test/lint-bash32.sh --list       # print the target set, lint nothing
#
# The file name is historical: this began as a bash-3.2 lint. Sandy requires
# bash 5 on the host since 2026-11-21 (macOS: Homebrew bash), and the detectors
# whose hazard existed only in bash 3.2 were retired then (see below).
#
# Why this exists. CI runs Ubuntu with GNU userland and glibc; the maintainer
# runs macOS with BSD userland and Apple's libc. Several constructs behave fine
# on the former and break on the latter, so `bash -n` in CI passes and the
# failure only ever appears on one machine, usually mid-task. Three of the codes
# below (PYBACK, APOSQ, GREPM) are not macOS-specific at all: they break under
# any bash, but quietly or as a race, so CI does not reliably show them either.
# Every pattern below has ALREADY broken this repo at least once:
#
#   VARMB   an UNBRACED `$name` immediately followed by a non-ASCII character,
#           e.g. `"Probing $host…"`. bash ends a variable name at the first byte
#           libc's isalnum() rejects, and on macOS in a UTF-8 locale isalnum()
#           ACCEPTS 0xE2 (the first byte of `…`; Apple's ctype reads the byte as
#           U+00E2, a letter). So the name runs on into the `…`, names a variable
#           that does not exist, and `set -u` aborts:
#           `_rsy_host<?>: unbound variable`. glibc rejects the byte, so CI
#           never sees it. NOT a bash-3.2 bug: bash 5.3 scans names with the same
#           isalnum() test, and bash 5.2 aborts the same way here when 0xE2 is
#           classified alpha. Hit by the first macOS run of `sandy --rsync`
#           (#374). Fix: `${name}…`.
#
#   PYBACK  backticks or $( ) inside a DOUBLE-quoted `python3 -c "..."` body.
#           Bash expands them regardless of Python comment syntax, so the shell
#           runs whatever is in the backticks and splices its stdout into the
#           program. Hit in §68: a `sandy` in a Python comment made the test
#           suite EXECUTE the real sandy binary and corrupt its own script.
#
#   APOSQ   an apostrophe in a comment inside a multi-line SINGLE-quoted program
#           argument (jq/awk/python passed as 'one big string'). The apostrophe
#           closes the string and the shell reinterprets the rest as code. A
#           "jq's" in a jq program broke `bash -n`. Detected via an explicit
#           opener, NOT quote parity: parity was tried and floods false
#           positives on any ordinary "don't" in prose.
#
#   GREPM   `grep -n ... | head` under pipefail (grep dies on EPIPE, exit 2,
#           ERR trap aborts the run — a race, so it passes locally and fails in
#           CI), and a flag cluster whose numeric argument was split by a bulk
#           -m1 conversion (`-nB0` -> `-nB -m10`). Both aborted this repo's
#           harness mid-run; a partial run still prints its passes.
#
#   GNUBIN  host-side use of a GNU-only binary or flag. `timeout` is the worst
#           of these: macOS ships none (homebrew calls it `gtimeout`), so the
#           call exits 127, a `|| true` swallows it, and the assertion that
#           followed then grepped "timeout: command not found" for real output.
#           That shape cost three separate debugging rounds in one session —
#           run-tests.sh §108/§109 and acceptance-handoff-dirs.sh E8 — each
#           passing in CI and failing only on the maintainer's machine. Also
#           covers sha256sum/md5sum/realpath, `date -d`, `grep -P`, `stat -c`
#           without a BSD fallback, `sed -i` with no suffix (BSD needs `-i ''`),
#           `xargs -r`, `find -printf`, and `sleep infinity` (which already had
#           its own one-off guard in run-tests.sh §70).
#
#           SCOPE, stated because it is the whole difficulty of this detector:
#           only HOST-side shell is a hazard. The container is Linux, where GNU
#           tools are correct, so heredoc BODIES are skipped entirely (they are
#           either container-side scripts or another language), as is
#           templates/user-setup.sh.tmpl, the container-side mirror. That is a
#           real blind spot for a host-side fixture written INTO a heredoc, and
#           it is preferred to the alternative: a detector that fires on correct
#           container code gets switched off, and then catches nothing at all.
#           Note the generated mirrors preserve coverage where it matters —
#           doctor.sh is host-side and IS scanned as its own file, even though
#           its heredoc body inside sandy is skipped.
#
# RETIRED 2026-11-21, when bash 5 became the host requirement. Each was a
# bash-3.2 parser bug, and each example runs correctly under bash 5.2 with
# `set -euo pipefail` (bash 4.0 began parsing $( ) with the real parser):
#
#   SRCSUB  nested `source <(...)` inside `$(...)` sourced nothing (§83).
#   APOSCS  an apostrophe or unbalanced paren in a comment inside a multi-line
#           `$( )` opened a quote that never closed: parse abort (§86).
#   CASESUB a `case` pattern's `)` inside a multi-line `$( )` closed the
#           substitution early: parse abort (§119, §126).
#
# Deliberately NOT checked: `set -E` ERR traps firing in command-substitution
# subshells (real — see sandy:1043 — but not reliably detectable statically, and
# a false positive here is worse than a miss). Also not checked: `readlink -f`,
# which macOS has supported since 12.3 — flagging it now would be crying wolf.

set -uo pipefail

SELF_TEST=false
LIST_ONLY=false
FILES=()
for a in "$@"; do
    case "$a" in
        --self-test) SELF_TEST=true ;;
        # --list reports the target set WITHOUT linting, so a caller can assert
        # coverage independently of the pass/fail outcome. Folding the two
        # together would make "we still scan everything" unverifiable on exactly
        # the runs where it matters — the failing ones.
        --list) LIST_ONLY=true ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) FILES+=("$a") ;;
    esac
done

_repo="$(cd "$(dirname "$0")/.." && pwd)"

# Default target set: every shell script the repo ships or tests with — except
# this file, whose --self-test fixtures are deliberate instances of every
# hazard it detects and would otherwise report themselves.
if [ "${#FILES[@]}" -eq 0 ]; then
    FILES=("$_repo/sandy")
    for f in "$_repo"/test/*.sh "$_repo"/*.sh; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "lint-bash32.sh" ] && continue
        FILES+=("$f")
    done
fi

if [ "$LIST_ONLY" = true ]; then
    printf '%s\n' "${FILES[@]}"
    exit 0
fi

_scanner="$(mktemp)"
trap 'rm -f "$_scanner"' EXIT

# Quoted heredoc: nothing here is expanded by bash. (Writing this scanner with
# an UNquoted heredoc would trip the very hazards it detects.)
cat > "$_scanner" <<'SCANNER_PY'
import os, re, sys

# A block that never terminates within this many lines is abandoned rather than
# reported. Runaway scanning is the main false-positive risk in the block
# detectors (PYBACK, APOSQ), and a lint that cries wolf gets switched off.
MAX_BLOCK = 80

# --- GNUBIN tables ---------------------------------------------------------
# Bare GNU-only commands, matched only in COMMAND POSITION (start of line, or
# after ; | & && || then do else { , with any VAR=val prefixes). Requiring
# command position is what keeps prose out: "burns the readiness timeout" and
# echo "timeout 60" are both preceded by ordinary text, not a separator.
GNU_CMDS = ["timeout", "realpath", "sha256sum", "md5sum"]
_SEP = r"(?:^\s*|[;&|(]\s*|&&\s*|\|\|\s*|\bthen\s+|\bdo\s+|\belse\s+|\{\s*)"
_ASSIGN = r"(?:[A-Za-z_][A-Za-z0-9_]*=[^\s]*\s+)*"
# `env -u VAR cmd` and `env VAR=val cmd` are command position too -- missing
# this is why a replay against the pre-fix tree did NOT flag
# acceptance-handoff-dirs.sh E8 (`env -u SANDY_AUTO_APPROVE_PRIVILEGED timeout`).
_ENVP = r"(?:env\s+(?:-u\s+\S+\s+|-\S+\s+|[A-Za-z_][A-Za-z0-9_]*=[^\s]*\s+)*)?"
CMD_POS = _SEP + _ASSIGN + _ENVP + _ASSIGN
# (command-name, regex, allowed-if-the-line-also-matches). The third element
# encodes the CORRECT portable idiom, so a fix is never reported as the bug.
GNU_FLAGS = [
    ("date",  r"\bdate\s+(?:--date\b|-d\b)", None),
    ("grep",  r"\bgrep\s+-[A-Za-z]*P\b", None),
    # BSD sed REQUIRES a suffix argument: `sed -i ''` or `sed -i.bak`.
    ("sed",   r"\bsed\s+-i(?:\s|$)", r"\bsed\s+-i\s+(?:''|\"\")"),
    # `stat -c` is GNU; the portable forms probe it (output discarded, either
    # redirect spelling) or fall back to `stat -f`.
    ("stat",  r"\bstat\s+-c\b", r"(?:stat\s+-f|2>/dev/null|2>&1)"),
    ("xargs", r"\bxargs\b[^|;]*\s-r\b", None),
    ("find",  r"\bfind\b[^|;]*\s-printf\b", None),
    ("sleep", r"\bsleep\s+infinity\b", None),
    # GNU BRE alternation. `\|` (and `\+`, `\?`) are GNU EXTENSIONS to basic
    # regular expressions; POSIX BRE has no alternation at all, so BSD sed
    # matches a LITERAL pipe and the expression silently never fires -- empty
    # output, exit 0, no error. Cost run-tests.sh §127(6-9): four checks that
    # passed in CI and failed on macOS the first time they ran there, because
    # `s/.*"agents":\(\[[^]]*\]\|null\).*/\1/p` matched nothing at all.
    # The fix is POSIX ERE -- `sed -E -n \'s/...(\[[^]]*\]|null).*/\1/p\'` --
    # which BSD sed and GNU sed both accept, so the allow pattern below stands
    # down for any -E/-r invocation.
    ("sed",   r"\bsed\b[^|;]*\\[|+?]", r"\bsed\s+(?:-[A-Za-z]*[Er])"),
    # NOT extended to grep, and that is an evidence call rather than an
    # oversight. The same macOS run that failed the sed form PASSED §109(2),
    # whose `grep -q "sandy own state\|sandy.s own state"` has no fallback and
    # whose FIRST alternative does not occur in the file -- it can only pass if
    # BSD grep honoured the alternation. Flagging grep would have produced 12
    # findings against lines that demonstrably work, which is the crying-wolf
    # failure the GNUBIN header warns about. Revisit only with a macOS run that
    # contradicts it.
]
# The BSD counterpart. Its presence on the SAME line means the call is already
# a portable fallback chain (`shasum -a 256 2>/dev/null || sha256sum`), which is
# the fix, not the bug.
BSD_ALT = {
    "sha256sum": r"\bshasum\b",
    "md5sum":    r"\bmd5\b",
    "timeout":   r"\bgtimeout\b",
    "realpath":  r"\bgrealpath\b|\bpwd -P\b",
}
# An explicit escape hatch, needed because container-side shell is not always in
# a heredoc -- it is also passed as a single-quoted multi-line argument, which
# no heuristic distinguishes from host code. Put the marker on the line or the
# line above.
SUPPRESS = "lint-bash32: allow GNUBIN"

GNUBIN_EXEMPT = {"user-setup.sh.tmpl"}


# A heredoc opener whose terminator is never found must mark NOTHING. The first
# version of this marked every remaining line as heredoc body, which silently
# switched GNUBIN off for the rest of an 11k-line file -- the detector reported
# a clean tree while scanning almost none of it. So: confirm the terminator
# EXISTS first, and mark nothing when it does not. Deliberately unbounded --
# sandy generates whole files (user-setup.sh, Dockerfile.base) from single
# heredocs well over 600 lines, and a bound short enough to feel "safe" simply
# reintroduced the same blind spot from the other end.
def heredoc_body_lines(lines):
    """0-based indices of every line inside a heredoc body."""
    body, i = set(), 0
    while i < len(lines):
        m = None
        if "<<<" not in lines[i]:
            m = re.search(r"<<-?\s*([\'\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", lines[i])
        if m:
            delim, end = m.group(2), None
            for j in range(i + 1, len(lines)):
                if lines[j].strip() == delim:
                    end = j
                    break
            if end is not None:
                body.update(range(i + 1, end))
                i = end
        i += 1
    return body


def scan(path):
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    except OSError as e:
        return [(0, "IOERR", str(e))]
    out = []

    # VARMB — unbraced $name followed directly by a non-ASCII character. Heredoc
    # BODIES are skipped for the GNUBIN reason: they are container-side scripts,
    # run on the image's glibc (which ends the name at a non-ASCII byte), or
    # another language entirely.
    _vb = heredoc_body_lines(lines)
    for i, l in enumerate(lines, 1):
        if (i - 1) in _vb or re.match(r"^\s*#", l):
            continue
        if re.search(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]", l):
            out.append((i, "VARMB", l.strip()[:88]))

    # PYBACK — backticks / $( inside a double-quoted `python3 -c "` body. Only
    # multi-line bodies are considered (the line ends with the opening quote);
    # a single-line `python3 -c "..."` cannot straddle a comment.
    #
    # Terminator: inside a double-quoted bash string every literal quote must be
    # written \" , so the first UNESCAPED " closes the body. It is usually at the
    # END of a line (`... m[0]"' -- "$1"`), not the start — an anchored ^\s*"
    # rule misses it and the scan runs on into unrelated code as false positives.
    i = 0
    while i < len(lines):
        if re.search(r'python3?\s+-c\s+"\s*$', lines[i]):
            j, start = i + 1, i
            while j < len(lines) and j - start < MAX_BLOCK:
                bare = lines[j].replace('\\"', "")
                head = bare.split('"')[0] if '"' in bare else bare
                if "`" in head or "$(" in head:
                    out.append((j + 1, "PYBACK", lines[j].strip()[:88]))
                if '"' in bare:
                    break
                j += 1
            i = j
        i += 1

    # GREPM — two grep hazards that abort a `set -o pipefail` suite mid-run.
    # Both bit this repo's own harness in CI, and `bash -n` saw nothing wrong
    # either time because the SHELL syntax was fine:
    #
    #   a) `grep -n PATTERN f | head -1`. head exits after one line, grep takes
    #      EPIPE and exits 2, the pipeline fails, the ERR trap kills the run. A
    #      RACE — it fires only when grep is still writing, so it passes locally
    #      and fails on CI. Measured on a 400k-match input: 200/200 failures for
    #      the pipe form, 0/200 for `grep -m1`. Fix: -m1, which drops the pipe.
    #
    #   b) a flag cluster ending in a NUMERIC argument immediately before -m,
    #      e.g. `-nB0 ... -m1` rewritten to `-nB -m10`: -B loses its argument and
    #      grep exits 2. Produced by a bulk -m1 conversion.
    #
    # Only the -n (line-number) form of (a) is flagged. `grep -o ... | head` is
    # NOT equivalent to -m1 — with -o, -m1 stops after the first matching LINE
    # but can still print several matches from it — so converting those is wrong
    # and this must not nag about them.
    for i, l in enumerate(lines, 1):
        if re.match(r"^\s*#", l):
            continue
        if re.search(r"grep -n[A-Za-z]*\s[^|]*\|\s*head\b", l):
            out.append((i, "GREPM", l.strip()[:88]))
        # -A/-B/-C/-m REQUIRE a numeric argument. If the next token starts with
        # "-", the argument was lost (this is what a bulk -m1 rewrite does to a
        # cluster like -nB0) and grep exits 2.
        if re.search(r"grep\s+-[A-Za-z]*[ABCm]\s+-", l):
            out.append((i, "GREPM", l.strip()[:88]))

    # APOSQ — apostrophe in a comment inside a multi-line SINGLE-QUOTED program
    # argument (jq / awk / python passed as 'one big quoted string'). Inside that
    # region an apostrophe CLOSES the string and the shell reinterprets the rest
    # as code, in any bash -- a "jq's" in a comment inside a jq program broke
    # bash -n.
    #
    # Deliberately NARROW. A parity-of-quotes approach was tried first and was
    # unusable: any lone apostrophe in ordinary prose ("don't") flips parity and
    # floods the rest of the file with false positives. So this requires an
    # explicit opener — a known program-taking command whose line ENDS with the
    # opening quote — and closes on a line whose first character is that quote.
    i = 0
    while i < len(lines):
        if re.search(r"\b(jq|awk|gawk|sed|perl|python3?|node)\b[^']*'\s*$", lines[i]):
            j, start = i + 1, i
            while j < len(lines) and j - start < MAX_BLOCK:
                if re.match(r"^\s*'", lines[j]):
                    break
                if re.match(r"^\s*#", lines[j]) and "'" in lines[j]:
                    out.append((j + 1, "APOSQ", lines[j].strip()[:88]))
                j += 1
            i = j
        i += 1

    # GNUBIN — see the header for scope and why heredoc bodies are out.
    if os.path.basename(path) not in GNUBIN_EXEMPT:
        body = heredoc_body_lines(lines)
        # A file that DEFINES `timeout()` has shipped its own portability shim;
        # every call in it then resolves to that shim, not to GNU coreutils.
        shims = set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)", "\n".join(lines), re.M))

        def probed(idx, name):
            # A `command -v NAME` / `NAME --version` test within a short window
            # above is the deliberate runtime probe; the branch it guards is
            # allowed to use the GNU form.
            win = "\n".join(lines[max(0, idx - 20): idx + 1])
            return bool(re.search(r"(?:command -v|type|hash|which)\s+" + name + r"\b", win)
                        or re.search(r"\b" + name + r"\s+--version", win))

        for i, l in enumerate(lines, 1):
            idx = i - 1
            if idx in body or re.match(r"^\s*#", l):
                continue
            if SUPPRESS in l or (idx > 0 and SUPPRESS in lines[idx - 1]):
                continue
            hits = []
            for name in GNU_CMDS:
                if re.search(CMD_POS + name + r"\b", l):
                    hits.append(name)
            # Flag rules require COMMAND POSITION too. Without it,
            # `check "no GNU-only 'sleep infinity' ..."` matched its own prose
            # -- a lint that flags the test guarding a hazard is pure noise.
            for name, rx, allow in GNU_FLAGS:
                if re.search(CMD_POS + rx, l) and not (allow and re.search(allow, l)):
                    hits.append(name)
            for name in hits:
                if name in shims:
                    continue
                alt = BSD_ALT.get(name)
                if alt and re.search(alt, l):
                    continue
                if probed(idx, name):
                    continue
                out.append((i, "GNUBIN", l.strip()[:88]))
                break
    return out

rc = 0
for p in sys.argv[1:]:
    for ln, code, txt in scan(p):
        rc = 1
        print("%s:%d: %s: %s" % (p, ln, code, txt))
sys.exit(rc)
SCANNER_PY

if [ "$SELF_TEST" = true ]; then
    # Positive controls. A linter nobody has proven can DETECT is decoration —
    # each fixture below is a real instance of the bug it names.
    _fx="$(mktemp -d)"
    printf '%s\n' '#!/bin/bash' 'python3 -c "' '# the `sandy` binary' 'print(1)' '" arg' > "$_fx/pyback.sh"
    printf '%s\n' '#!/bin/bash' "jq --arg s x '" '  .a //= 1 |' "  # note: jq's //= is odd here" '  .b' "' file" > "$_fx/aposq.sh"
    printf '%s\n' '#!/bin/bash' 'L="$(grep -n PATTERN f | head -1 | cut -d: -f1)"' > "$_fx/grepm.sh"
    # Second GREPM shape: a cluster ending in an argument-taking flag whose
    # numeric argument was split off by a bulk -m1 conversion.
    printf '%s\n' '#!/bin/bash' 'L="$(grep -nB -m10 PATTERN f | cut -d: -f1)"' > "$_fx/grepm2.sh"
    # GNUBIN: the repeat offender (no `timeout` on macOS), and GNU in-place sed.
    printf '%s\n' '#!/bin/bash' 'OUT="$(SANDY_X=1 timeout 60 bash prog </dev/null 2>&1 || true)"' > "$_fx/gnubin.sh"
    printf '%s\n' '#!/bin/bash' "sed -i 's/a/b/' f" > "$_fx/gnubin2.sh"
    # `env -u VAR timeout ...` -- the exact shape a replay against the pre-fix
    # tree proved the first version of this detector MISSED.
    printf '%s\n' '#!/bin/bash' 'env -u SANDY_X timeout 120 "$S" -p x || rc=$?' > "$_fx/gnubin3.sh"
    # An unterminated heredoc opener must not blank the rest of the file: the
    # `timeout` below it still has to be reported.
    printf '%s\n' '#!/bin/bash' 'echo "a string mentioning <<EOF that never ends"' 'timeout 60 prog' > "$_fx/gnubin4.sh"
    # GNUBIN: GNU-only BRE alternation. The exact run-tests.sh §127 shape --
    # silent empty output on BSD sed, never an error.
    printf '%s\n' '#!/bin/bash' 'v="$(prog | sed -n '"'"'s/.*"agents":\\(\\[[^]]*\\]\\|null\\).*/\\1/p'"'"')"' > "$_fx/gnubin5.sh"
    # VARMB: the exact line that aborted the first macOS run of sandy --rsync.
    printf '%s\n' '#!/bin/bash' 'info "Probing $_rsy_host…"' > "$_fx/varmb.sh"
    # ...and the documented fix must NOT fire, nor may the same text inside a
    # heredoc body (container-side, bash 5).
    printf '%s\n' '#!/bin/bash' 'info "Probing ${_rsy_host}…"' 'cat <<EOF' 'Probing $_rsy_host…' 'EOF' > "$_fx/varmbok.sh"
    _fails=0
    for probe in varmb pyback aposq grepm grepm2 gnubin gnubin2 gnubin3 gnubin4 gnubin5; do
        if python3 "$_scanner" "$_fx/$probe.sh" >/dev/null 2>&1; then
            echo "SELF-TEST FAIL: $probe fixture was NOT detected" >&2; _fails=$((_fails + 1))
        else
            echo "  detector OK: $probe"
        fi
    done
    if python3 "$_scanner" "$_fx/varmbok.sh" >/dev/null 2>&1; then
        echo "  negative control OK: \${name} and heredoc bodies do not fire VARMB"
    else
        echo "SELF-TEST FAIL: VARMB flagged the braced fix or a heredoc body" >&2; _fails=$((_fails + 1))
    fi
    # The documented fix -- POSIX ERE -- must NOT fire, in either tool.
    {
        echo '#!/bin/bash'
        echo 'v="$(prog | sed -E -n '"'"'s/.*"agents":(\[[^]]*\]|null).*/\1/p'"'"')"'
        echo 'grep -E '"'"'a|b'"'"' f'
        echo 'grep -F '"'"'a\|b'"'"' f'
    } > "$_fx/gnubin5ok.sh"
    if python3 "$_scanner" "$_fx/gnubin5ok.sh" >/dev/null 2>&1; then
        echo "  negative control OK: POSIX ERE alternation does not fire"
    else
        echo "SELF-TEST FAIL: the -E fix was flagged as a finding" >&2; _fails=$((_fails + 1))
    fi
    # Negative control: a clean file must produce nothing.
    printf '%s\n' '#!/bin/bash' 'x="$(echo hi)"' '# a normal comment with an apostrophe, outside any quoted program' > "$_fx/clean.sh"
    if python3 "$_scanner" "$_fx/clean.sh" >/dev/null 2>&1; then
        echo "  negative control OK: clean file produced no findings"
    else
        echo "SELF-TEST FAIL: clean file produced findings" >&2; _fails=$((_fails + 1))
    fi
    # GNUBIN negative control. This detector's whole risk is crying wolf, so the
    # correct idioms and the container-side heredoc are asserted NOT to fire --
    # a detector that flags the fix as the bug is worse than no detector.
    {
        echo '#!/bin/bash'
        echo '# the --start client burns the full readiness timeout here'
        echo 'echo "timeout 60 is mentioned inside a string"'
        echo "sed -i '' 's/a/b/' f      # the BSD-correct form"
        echo 'sed -i.bak "s/a/b/" f'
        echo 'stat -c "%Y" f 2>/dev/null || stat -f "%m" f'
        echo "cat > /tmp/x <<'CONTAINER'"
        echo 'timeout 30 apt-get update   # runs INSIDE the Linux container'
        echo 'sha256sum /etc/passwd'
        echo 'CONTAINER'
    } > "$_fx/gnuclean.sh"
    if python3 "$_scanner" "$_fx/gnuclean.sh" >/dev/null 2>&1; then
        echo "  negative control OK: GNUBIN does not fire on prose, BSD-correct idioms, or container heredocs"
    else
        echo "SELF-TEST FAIL: GNUBIN false positive" >&2
        python3 "$_scanner" "$_fx/gnuclean.sh" >&2
        _fails=$((_fails + 1))
    fi
    rm -rf "$_fx"
    [ "$_fails" -eq 0 ] || exit 1
    echo "self-test passed"
    exit 0
fi

if python3 "$_scanner" "${FILES[@]}"; then
    echo "portability lint: clean (${#FILES[@]} files)"
    exit 0
else
    echo "" >&2
    echo "portability lint FAILED — the above break on macOS, or under any bash in a way CI does not reliably show" >&2
    echo "  VARMB   brace the variable: \"\${name}…\" -- macOS libc reads a following non-ASCII byte as part of the name" >&2
    echo "  PYBACK  use a QUOTED heredoc: python3 - arg <<'PY' ... PY" >&2
    echo "  APOSQ   reword the comment; an apostrophe closes the single-quoted program" >&2
    echo "  GREPM   use 'grep -m1' instead of 'grep | head -1'; keep numeric flag args clear of -m" >&2
    echo "  GNUBIN  GNU-only on a BSD host: resolve timeout->gtimeout (or drop it), shasum -a 256," >&2
    echo "          sed -i '' / -i.bak, stat -f fallback; container-side code belongs in a heredoc" >&2
    exit 1
fi
