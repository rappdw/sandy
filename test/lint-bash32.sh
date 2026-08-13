#!/usr/bin/env bash
# Static lint for bash-3.2 / BSD-userland hazards that CI structurally CANNOT see.
#
#   bash test/lint-bash32.sh              # lint the repo's shell scripts
#   bash test/lint-bash32.sh FILE...      # lint specific files
#   bash test/lint-bash32.sh --self-test  # prove the detectors actually detect
#
# Why this exists. CI runs Ubuntu with bash 5 and GNU userland; the maintainer
# runs macOS with bash 3.2 and BSD userland. Several constructs parse fine on
# the former and break on the latter, so `bash -n` in CI passes and the failure
# only ever appears on one machine, usually mid-task. Every pattern below has
# ALREADY broken this repo at least once — none is speculative:
#
#   SRCSUB  nested `source <(...)` inside `$(...)`. bash 3.2 yields an empty
#           source; the calls that follow exit 127 and the ERR trap aborts the
#           whole run. Hit in run-tests.sh §83 — every section after it silently
#           never executed.
#
#   PYBACK  backticks or $( ) inside a DOUBLE-quoted `python3 -c "..."` body.
#           Bash expands them regardless of Python comment syntax, so the shell
#           runs whatever is in the backticks and splices its stdout into the
#           program. Hit in §68: a `sandy` in a Python comment made the test
#           suite EXECUTE the real sandy binary and corrupt its own script.
#
#   APOSCS  an apostrophe in a comment inside a multi-line `$( )`. bash 3.2
#           scans command substitutions WITHOUT skipping comments, so the
#           apostrophe opens a quote that never closes and the file dies with
#           "unexpected EOF while looking for matching quote". Hit in §86 —
#           and it is a PARSE error, so it killed the entire file while the
#           summary still printed "945 passed, 0 failed".
#
# Deliberately NOT checked: `set -E` ERR traps firing in command-substitution
# subshells (real — see sandy:1043 — but not reliably detectable statically, and
# a false positive here is worse than a miss).

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
# this file, whose --self-test fixtures are deliberate instances of all three
# bugs and would otherwise report themselves.
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
import re, sys

# A block that never terminates within this many lines is abandoned rather than
# reported. Runaway scanning is the main false-positive risk in all three
# detectors, and a lint that cries wolf gets switched off.
MAX_BLOCK = 80

def scan(path):
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    except OSError as e:
        return [(0, "IOERR", str(e))]
    out = []

    # SRCSUB — process substitution fed to source/dot, in code (not comments).
    for i, l in enumerate(lines, 1):
        if re.match(r"^\s*#", l):
            continue
        if re.search(r"(^|[^\w-])(source|\.)\s+<\(", l):
            out.append((i, "SRCSUB", l.strip()[:88]))

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

    # APOSCS — apostrophe in a comment inside a multi-line $( ).
    depth, opened_at = 0, 0
    for i, l in enumerate(lines, 1):
        if re.search(r"\$\(\s*$", l):
            if depth == 0:
                opened_at = i
            depth += 1
        elif re.match(r'^\s*\)"?\s*$', l) and depth > 0:
            depth -= 1
        elif depth > 0:
            if i - opened_at > MAX_BLOCK:
                depth = 0
                continue
            if re.match(r"^\s*#", l) and "'" in l:
                out.append((i, "APOSCS", l.strip()[:88]))
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
    printf '%s\n' '#!/bin/bash' 'x="$(bash -c '"'"'source <(sed -n "1p" f); g'"'"')"' > "$_fx/srcsub.sh"
    printf '%s\n' '#!/bin/bash' 'python3 -c "' '# the `sandy` binary' 'print(1)' '" arg' > "$_fx/pyback.sh"
    printf '%s\n' '#!/bin/bash' 'out="$(' '  # shellcheck can'"'"'t see this' '  echo hi' ')"' > "$_fx/aposcs.sh"
    _fails=0
    for probe in srcsub pyback aposcs; do
        if python3 "$_scanner" "$_fx/$probe.sh" >/dev/null 2>&1; then
            echo "SELF-TEST FAIL: $probe fixture was NOT detected" >&2; _fails=$((_fails + 1))
        else
            echo "  detector OK: $probe"
        fi
    done
    # Negative control: a clean file must produce nothing.
    printf '%s\n' '#!/bin/bash' 'x="$(echo hi)"' '# a normal comment with an apostrophe, outside any $( )' > "$_fx/clean.sh"
    if python3 "$_scanner" "$_fx/clean.sh" >/dev/null 2>&1; then
        echo "  negative control OK: clean file produced no findings"
    else
        echo "SELF-TEST FAIL: clean file produced findings" >&2; _fails=$((_fails + 1))
    fi
    rm -rf "$_fx"
    [ "$_fails" -eq 0 ] || exit 1
    echo "self-test passed"
    exit 0
fi

if python3 "$_scanner" "${FILES[@]}"; then
    echo "bash-3.2 lint: clean (${#FILES[@]} files)"
    exit 0
else
    echo "" >&2
    echo "bash-3.2 lint FAILED — the above parse or expand differently on macOS" >&2
    echo "  SRCSUB  use extract-then-eval: v=\"\$(sed -n '/^f()/,/^}/p' x)\"; bash -c \"\$v; f\"" >&2
    echo "  PYBACK  use a QUOTED heredoc: python3 - arg <<'PY' ... PY" >&2
    echo "  APOSCS  reword the comment to avoid apostrophes" >&2
    exit 1
fi
