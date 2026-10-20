#!/usr/bin/env bash
# test/spike/mirror-spike.sh -- HOST-RUN measurement for
# decisions/2026-10-20-mirror-agent.md (#463). RUN THIS ON THE HOST, never
# inside a sandy sandbox: it uses docker.
#
# Sandy cannot launch mirror yet, so this builds a throwaway image FROM
# sandy-base with Mirror installed the way the agent image will install it,
# and runs it the way sandy runs an agent: read-only root, a non-root uid,
# HOME on a bind mount, MIRROR_SKIP_UPDATE=1. Each home lives in a temp dir on
# the host, so what Mirror wrote can be listed afterwards.
#
#   M0  The real flag set: mirror --version, mirror --help, mirror exec --help.
#   M1  Headless on a fresh home, before any notice was accepted, offline:
#       the message and exit code (the --start inertness class).
#   M2  Interactive first run in a pty: screens at each stop, Enter pressed
#       between them. Then the files Mirror wrote, config.json with any
#       key/token/secret field redacted, and the cli.db schema. This is where
#       the usage/folder/extension acceptances turn out to be recorded.
#   M3  Seeding: a fresh home holding only M2's config.json, only its
#       cli.db, then both; does `mirror exec` run with no prompt? Same path,
#       then a different path.
#   M4  Approval: does --approval-mode approve override a saved auto?
#   M5  exec exit codes: success, bad key, no network.
#   M6  --continue with no prior conversation, and with one.
#   M7  state.db schema (column names only, plus workspace-like path
#       columns' distinct values) for the auto-continue probe.
#   M8  Startup with no network at all (MIRROR_SKIP_UPDATE=1), interactive.
#
# M3-M6 make real model calls and need REFLECTION_API_KEY in this shell's
# environment; it is passed as `-e REFLECTION_API_KEY` (name only, never in
# argv) and redacted from every transcript. Without it those parts are
# skipped and say so. A few cheap one-word prompts only.
#
# RESULTS, run 1 (2026-10-20, mirror 0.1.0, macOS host):
#   M0  Flags as documented, except --reasoning-effort takes
#       none|low|medium|high|xhigh|max (no `minimal`); `mirror update` exists.
#   M1  exec before acceptance: "open Mirror interactively in this directory
#       to review and accept the usage and folder notices before using
#       exec", exit 1. It already writes ~/.mirror/cli.db.
#   M8/M2  The usage notice and the folder trust are ONE prompt, "Continue
#       and trust this folder? [y/N]", default No: Enter declines and exits
#       1, leaving no config.json, so run 1 never got past it. Run 2 answers
#       y, and answers the terminal's cursor-position query (prompt_toolkit
#       warned "your terminal doesn't support cursor position requests").
#
# It is a measurement, not a pass/fail suite: it prints raw evidence. Paste
# the whole output back. SPIKE_KEEP=1 keeps the temp dir and the image.
set -uo pipefail

MIRROR_VERSION="${MIRROR_VERSION:-0.1.0}"
IMG="sandy-mirror-spike:$MIRROR_VERSION"
D="$(cd "$(mktemp -d)" && pwd -P)"
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   -- %s\n' "$*"; }

cleanup() {
    if [ "${SPIKE_KEEP:-0}" = "1" ]; then
        note "kept: $D and image $IMG"
    else
        rm -rf "$D"
        docker rmi "$IMG" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

docker image inspect sandy-base >/dev/null 2>&1 \
    || { echo "sandy-base image not found: run sandy once on this host first" >&2; exit 1; }

KEY_ENV=()
HAVE_KEY=false
if [ -n "${REFLECTION_API_KEY:-}" ]; then KEY_ENV=(-e REFLECTION_API_KEY); HAVE_KEY=true; fi

# ---------------------------------------------------------------- image
mkdir -p "$D/build"
cat > "$D/build/drive.py" <<'PY'
# Runs a command in a pty, renders its screen with pyte, and follows steps.
# Steps: wait:S | key:TEXT (python escapes, e.g. key:\r) | stable:S (until
# the screen has not changed for 2s, at most S seconds) | snap:LABEL.
# --plain runs it without a pty and just captures output.
# Every byte printed has REFLECTION_API_KEY's value replaced.
import os, pty, re, select, signal, subprocess, sys, time
import pyte

key = os.environ.get("REFLECTION_API_KEY", "")
def red(s):
    if key and len(key) >= 8:
        s = s.replace(key, "[REDACTED]")
    return s

args = sys.argv[1:]
plain = False
if args and args[0] == "--plain":
    plain, args = True, args[1:]
sep = args.index("--")
steps, argv = args[:sep], args[sep + 1:]

if plain:
    p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace")
    sys.stdout.write(red(p.stdout)); sys.stdout.write(red(p.stderr))
    print(f"[exit {p.returncode}]")
    sys.exit(0)

cols, rows = 120, 40
fd = None
class Screen(pyte.Screen):
    # Answer the terminal's own queries (cursor position report, device
    # status): prompt_toolkit asks for CPR and degrades without an answer.
    def write_process_input(self, data):
        if fd is not None:
            os.write(fd, data.encode())
screen = Screen(cols, rows)
stream = pyte.ByteStream(screen)
pid, fd = pty.fork()
if pid == 0:
    os.environ["COLUMNS"], os.environ["LINES"] = str(cols), str(rows)
    os.execvp(argv[0], argv)
import fcntl, struct, termios
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

def pump(t):
    end, changed = time.time() + t, False
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], max(0.0, min(0.2, end - time.time())))
        if r:
            try:
                b = os.read(fd, 65536)
            except OSError:
                return changed, True
            if not b:
                return changed, True
            stream.feed(b); changed = True
    return changed, False

def text():
    return "\n".join(l.rstrip() for l in screen.display).rstrip()

dead = False
for st in steps:
    kind, _, val = st.partition(":")
    if dead:
        break
    if kind == "wait":
        _, dead = pump(float(val))
    elif kind == "stable":
        end = time.time() + float(val)
        while time.time() < end and not dead:
            ch, dead = pump(2.0)
            if not ch:
                break
    elif kind == "key":
        os.write(fd, val.encode().decode("unicode_escape").encode("latin-1"))
    elif kind == "snap":
        print(f"----- screen: {val} -----")
        print(red(text()))
        print("----- end -----")
if not dead:
    for k in (b"\x03", b"\x03", b"\x04"):
        try:
            os.write(fd, k)
        except OSError:
            break
        _, dead = pump(1.5)
        if dead:
            break
if not dead:
    os.kill(pid, signal.SIGTERM); time.sleep(1)
_, status = os.waitpid(pid, 0)
print(f"[exit status {status >> 8}, signal {status & 0x7f}]")
PY
cat > "$D/build/Dockerfile" <<DOCKERFILE
FROM sandy-base
USER root
RUN UV_TOOL_DIR=/opt/mirror UV_TOOL_BIN_DIR=/usr/local/bin \\
        uv tool install --python-preference system "reflection-mirror==${MIRROR_VERSION}" \\
    && uv venv -q /opt/spike --python /usr/bin/python3 \\
    && uv pip install -q --python /opt/spike/bin/python pyte
COPY drive.py /opt/spike/drive.py
DOCKERFILE
say "build $IMG (reflection-mirror==$MIRROR_VERSION FROM sandy-base)"
docker build -q -t "$IMG" "$D/build" || { echo "build failed" >&2; exit 1; }

# ---------------------------------------------------------------- helpers
# mkhome NAME -> creates $D/NAME/{home,ws} (ws is a git repo with one file)
mkhome() {
    mkdir -p "$D/$1/home" "$D/$1/ws"
    ( cd "$D/$1/ws" && git init -q && printf 'hello\n' > README.md )
}
# R NAME [docker flags...] -- CMD...   runs in the spike image like sandy would
R() {
    local n="$1"; shift
    local flags=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do flags+=("$1"); shift; done
    shift
    docker run --rm --read-only --tmpfs /tmp \
        -u "$(id -u):$(id -g)" -e HOME=/w/home -e MIRROR_SKIP_UPDATE=1 -e TERM=xterm-256color \
        -v "$D/$n:/w" -w /w/ws \
        ${flags[@]+"${flags[@]}"} "$IMG" "$@"
}
DRIVE=(/opt/spike/bin/python /opt/spike/drive.py)
# files under a home (no contents), and config.json with secret-looking keys redacted
inventory() {
    note "files under $1/home (size, path):"
    ( cd "$D/$1/home" && find . -type f -exec ls -ln {} + 2>/dev/null | awk '{print "     " $5 "\t" $9}' )
    if [ -f "$D/$1/home/.mirror/config.json" ]; then
        note "config.json (key/token/secret/password fields redacted):"
        python3 - "$D/$1/home/.mirror/config.json" <<'PY'
import json, re, sys
def walk(v):
    if isinstance(v, dict):
        return {k: ("[REDACTED]" if re.search(r"key|token|secret|passw", k, re.I) else walk(x)) for k, x in v.items()}
    if isinstance(v, list):
        return [walk(x) for x in v]
    return v
try:
    print(json.dumps(walk(json.load(open(sys.argv[1]))), indent=2))
except Exception as e:
    print(f"(unparseable: {e})")
PY
    fi
}
# sqlite schema (names only) + distinct values of workspace-like columns
dbschema() {
    python3 - "$1" <<'PY'
import re, sqlite3, sys
p = sys.argv[1]
try:
    c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
except Exception as e:
    print(f"   (cannot open {p}: {e})"); sys.exit(0)
for (t,) in c.execute("select name from sqlite_master where type='table' order by name"):
    cols = [r[1] for r in c.execute(f'pragma table_info("{t}")')]
    n = c.execute(f'select count(*) from "{t}"').fetchone()[0]
    print(f"   {t} ({n} rows): {', '.join(cols)}")
    for col in cols:
        if re.search(r"cwd|workspace|directory|dir$|path|root|project", col, re.I):
            vals = [r[0] for r in c.execute(f'select distinct "{col}" from "{t}" limit 5')]
            print(f"      {col} values: {vals}")
PY
}

# ---------------------------------------------------------------- M0
say "M0 flag set"
mkhome m0
R m0 --network none -- mirror --version
R m0 --network none -- mirror --help
R m0 --network none -- mirror exec --help

# ---------------------------------------------------------------- M1
say "M1 headless on a fresh home, nothing accepted, offline"
mkhome m1
# lint-bash32: allow GNUBIN (timeout runs inside the Linux container)
R m1 --network none -- "${DRIVE[@]}" --plain -- timeout 60 mirror exec --approval-mode auto "Reply with the single word PONG"
inventory m1

# ---------------------------------------------------------------- M8
say "M8 interactive start with no network at all"
mkhome m8
R m8 --network none -t -- "${DRIVE[@]}" stable:20 snap:offline-first-screen \
    key:'y\r' stable:20 snap:offline-after-y -- mirror
inventory m8

# ---------------------------------------------------------------- M2
say "M2 interactive first run: y at the trust prompt, then Enter"
mkhome m2
R m2 -t ${KEY_ENV[@]+"${KEY_ENV[@]}"} -- "${DRIVE[@]}" \
    stable:25 snap:first \
    key:'y\r' stable:25 snap:after-y \
    key:'\r' stable:15 snap:after-enter-1 \
    key:'\r' stable:15 snap:after-enter-2 \
    -- mirror
inventory m2
for db in cli.db state.db; do
    [ -f "$D/m2/home/.mirror/$db" ] && { note "$db schema:"; dbschema "$D/m2/home/.mirror/$db"; }
done

if [ "$HAVE_KEY" != true ]; then
    say "M3-M7 SKIPPED: REFLECTION_API_KEY is not set in this shell"
    exit 0
fi
if [ ! -f "$D/m2/home/.mirror/config.json" ] && [ ! -f "$D/m2/home/.mirror/cli.db" ]; then
    say "M3-M7 SKIPPED: M2 left neither config.json nor cli.db to seed from (see M2's screens)"
    exit 0
fi
# seed NAME WHAT -- a fresh home holding only M2's config.json, cli.db, or both
seed() {
    mkhome "$1"; mkdir -p "$D/$1/home/.mirror"
    case "$2" in
        config|both) [ -f "$D/m2/home/.mirror/config.json" ] && cp "$D/m2/home/.mirror/config.json" "$D/$1/home/.mirror/" ;;
    esac
    case "$2" in
        clidb|both) [ -f "$D/m2/home/.mirror/cli.db" ] && cp "$D/m2/home/.mirror/cli.db" "$D/$1/home/.mirror/" ;;
    esac
    return 0
}

# ---------------------------------------------------------------- M3
for what in config clidb; do
    say "M3-$what seeded $what only, same path"
    seed "m3$what" "$what"
    R "m3$what" "${KEY_ENV[@]}" -- "${DRIVE[@]}" --plain -- timeout 180 mirror exec --approval-mode auto "Reply with the single word PONG"
done
say "M3 seeded config.json + cli.db, same path"
seed m3 both
R m3 "${KEY_ENV[@]}" -- "${DRIVE[@]}" --plain -- timeout 180 mirror exec --approval-mode auto "Reply with the single word PONG"
say "M3b seeded config.json + cli.db, a DIFFERENT workspace path"
mkdir -p "$D/m3/ws2" && ( cd "$D/m3/ws2" && git init -q )
R m3 "${KEY_ENV[@]}" -w /w/ws2 -- "${DRIVE[@]}" --plain -- timeout 180 mirror exec --approval-mode auto "Reply with the single word PONG"
inventory m3

# ---------------------------------------------------------------- M4
say "M4 approval: saved auto, then --approval-mode approve"
seed m4 both
note "4a: exec --approval-mode auto (saves auto?)"
R m4 "${KEY_ENV[@]}" -- "${DRIVE[@]}" --plain -- timeout 180 mirror exec --approval-mode auto "Reply with the single word OK"
note "approval-related config after 4a:"; grep -i approv "$D/m4/home/.mirror/config.json" || note "(no approval key in config.json)"
note "4b: exec --approval-mode approve, asked to create a file"
R m4 "${KEY_ENV[@]}" -- "${DRIVE[@]}" --plain -- timeout 180 mirror exec --approval-mode approve "Use your shell tool to run exactly: touch /w/ws/probe-approve . Then reply DONE."
if [ -e "$D/m4/ws/probe-approve" ]; then note "probe-approve EXISTS: approve did NOT override the saved auto"; else note "probe-approve absent: approve held"; fi
note "4c: exec with NO approval flag, same request"
R m4 "${KEY_ENV[@]}" -- "${DRIVE[@]}" --plain -- timeout 180 mirror exec "Use your shell tool to run exactly: touch /w/ws/probe-noflag . Then reply DONE."
if [ -e "$D/m4/ws/probe-noflag" ]; then note "probe-noflag EXISTS: the saved mode was auto"; else note "probe-noflag absent: saved mode was not auto (or 4b reset it)"; fi
note "approval-related config after 4c:"; grep -i approv "$D/m4/home/.mirror/config.json" || true

# ---------------------------------------------------------------- M5
say "M5 exec exit codes"
note "5a: bad key"
R m4 -e REFLECTION_API_KEY=spike-not-a-real-key -- "${DRIVE[@]}" --plain -- timeout 120 mirror exec --approval-mode auto "Reply OK"
note "5b: no network"
R m4 --network none "${KEY_ENV[@]}" -- "${DRIVE[@]}" --plain -- timeout 120 mirror exec --approval-mode auto "Reply OK"
note "5c: empty prompt, stdin closed"
R m4 "${KEY_ENV[@]}" -- "${DRIVE[@]}" --plain -- timeout 60 mirror exec

# ---------------------------------------------------------------- M6
say "M6a --continue with NO prior interactive conversation (seeded home)"
seed m6 both
R m6 -t "${KEY_ENV[@]}" -- "${DRIVE[@]}" stable:25 snap:continue-empty -- mirror --approval-mode auto --continue
say "M6b one interactive turn, then --continue"
R m6 -t "${KEY_ENV[@]}" -- "${DRIVE[@]}" stable:25 snap:before-turn \
    key:'Reply with the single word MARKER42' key:'\r' stable:60 snap:after-turn \
    -- mirror --approval-mode auto
R m6 -t "${KEY_ENV[@]}" -- "${DRIVE[@]}" stable:25 snap:continue-after-turn -- mirror --approval-mode auto --continue

# ---------------------------------------------------------------- M7
say "M7 database schema after conversations (names and path columns only)"
for n in m3 m4 m6; do
    for db in state.db cli.db; do
        [ -f "$D/$n/home/.mirror/$db" ] && { note "$n/$db:"; dbschema "$D/$n/home/.mirror/$db"; }
    done
done
inventory m6
say "done"
