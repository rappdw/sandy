#!/usr/bin/env bash
# test/measure-settings-inbound.sh — HOST-RUN MEASUREMENT for issue #379.
#
# RUN THIS ON THE HOST. NEVER from inside a sandy sandbox (this repo's own
# CLAUDE.md rule: tmux / sandy --start|--stop|--attach / docker must never run
# from inside sandy — this harness does all three).
#
# WHAT IT MEASURES, and why a sandy launch alone cannot answer it: sandy
# writes the SAME resolved crossSessionInbound value into both userSettings
# ($SANDBOX_DIR/claude/settings.json) and the workspace settings.local.json
# (docs/security/CROSS_SESSION_INBOUND.md §6a), so a real `sandy` launch can
# never set the three Claude Code precedence layers INDEPENDENTLY. This
# harness uses a sandy container only as a known Linux box with the shipped
# `claude` binary, then drives Claude Code's own resolver directly through a
# SEPARATE receiver process (started via `sandy --exec`, never through the
# agent pane sandy's own launch would seed) so each layer can be set on its
# own:
#
#   Q1/Q2   does --settings (Claude Code's "flagSettings" layer) still rank
#           where §6a's single-layer probe measured it (able to deliver
#           `accept`) once the OTHER layers are also set to something that
#           disagrees, or is it tighten-only like the workspace files once
#           they are in the mix?
#   Q3a/b   is --settings repeatable, and if two occurrences disagree, does
#           the LAST one win, or do all of them apply?
#   Q3c     if --settings is repeatable, is a second occurrence a per-key
#           MERGE onto the first, or does it REPLACE the whole object? (Q0,
#           below, is the control this reading depends on.)
#   Q3d     the #363 file-existence method: pass an existing settings file
#           and a nonexistent one, in both orders, and see which order (if
#           either) errors on the missing path. This tells you whether a
#           flag consults every occurrence or silently only the last, WITHOUT
#           needing to inspect Claude Code's resolved config at all -- unless
#           NEITHER order errors, which this harness reports as INCONCLUSIVE
#           rather than as evidence either way (`--version` may short-circuit
#           before --settings is fully parsed).
#
# K1/K2/Q0 are RIG-VALIDITY / baseline controls, not questions about Claude
# Code's own precedence: K1 proves the whole apparatus (container, --exec,
# seeded config, socket wait, the inject frame) can deliver at all; K2 proves
# the workspace `refuse` layer still blocks in this same rig -- several Q
# cases depend on that layer actually tightening to isolate --settings from
# userSettings, so K2 gates exactly like K1 does; Q0 measures the unset
# default (no crossSessionInbound key in ANY layer) so Q3c's "does a later
# --settings file MERGE or REPLACE" reading has something to compare against
# other than a guess about what "unset" resolves to. If K1 or K2 does not
# come back as expected, every Q result below it is meaningless and the run
# prints RIG-INVALID, dumps whatever diagnostic evidence it captured (never
# silently discarded), and stops rather than reporting Q-results that would
# look like real findings.
#
# RESULTS ARE MEASURED, NEVER INFERRED. Every case is classified from the
# receiver's own `--debug --debug-file` log, using the SAME success
# signatures test/acceptance-uds-delivery.sh already established against a
# real Claude Code build (docs/security/CROSS_SESSION_INBOUND.md §6a):
#
#   ROUTED (accept)  -> "[uds-messaging] Routed user message to queue"
#   HELD             -> "[cross-session-inbound] held ..."
#   REFUSED          -> "refused inbound peer message"
#   UNKNOWN          -> the frame was confirmed SENT but no signature line
#                        appeared in the debug log within the poll window
#   TRANSPORT-FAIL   -> the frame was never confirmed sent (a harness/socket
#                        problem, not a policy result) — always SKIPPED, never
#                        reported as a case outcome, matching
#                        acceptance-uds-delivery.sh's own SENDER CONTROL rule
#
# The single most important asymmetry from §6a, repeated here because it is
# exactly backwards from what a first read expects: the ACCEPT path emits NO
# "[cross-session-inbound]" line at all — only HELD and REFUSED log there. An
# empty grep for that prefix is the SUCCESS signature, never evidence of
# non-delivery.
#
# The injector authenticates with the session key file's JSON `peerToken`
# field — NEVER `CLAUDE_CODE_MESSAGING_TOKEN` (the `childToken`, which
# BYPASSES crossSessionInbound entirely and would make every case report
# ROUTED regardless of policy — see docs/security/CROSS_SESSION_INBOUND.md
# §6a "Correction 2"). And because a peer/self classification is at least
# partly ancestry-based (docs §1: agent-spawned code is already "selfSent"),
# the injector — even though it lives inside driver.py, which is what
# actually spawned the receiver — escapes that ancestry with the same
# double-fork + setsid mechanics as acceptance-uds-delivery.sh's inject.py
# before it ever opens the socket, so what we measure is genuinely the PEER
# path, not an ancestry shortcut around it.
#
# BSD/bash-3.2 SAFE ON THE HOST SIDE (the maintainer's actual machine): no GNU
# `timeout`, no GNU-only `sed -i`/`realpath`, no `grep -P`, every `mktemp -d`
# canonicalized with `cd ... && pwd -P`, no unbraced `$var` beside non-ASCII,
# no `case` or apostrophe-bearing comment inside a multi-line `$( )`. The
# CONTAINER-SIDE python/bash driver files below are written through QUOTED
# heredocs (the PYBACK fix) directly to disk, never through `python3 -c
# "..."`, and never nested inside a `$( )` substitution — so lint-bash32's
# host-only detectors do not apply to them, and they run under the
# container's own bash 5 / python3, where GNU semantics are correct.
#
# EXIT: 0 whenever the rig ran far enough to print a result table (this is a
# measurement, not a pass/fail suite) or to print a loud, honest SKIP; 2 only
# for RIG-INVALID (K1 did not route, so nothing after it can be trusted).
#
# NOT wired into run-integration-tests.sh: it has no pass/fail verdict to
# aggregate, only a table meant to be pasted into
# docs/security/CROSS_SESSION_INBOUND.md §9. Run it by hand:
#
#   bash test/measure-settings-inbound.sh
#
# Structural coverage (existence, sourcing lib-isolated-home.sh, the
# peerToken/CLAUDE_CODE_MESSAGING_TOKEN properties, lint-bash32 cleanliness)
# is pinned by test/run-tests.sh §174, which — like this file — needs no
# Docker and asserts none of the actual measurement.
set -uo pipefail

SANDY="${SANDY:-./sandy}"

# Same isolation contract as every other acceptance harness (see
# test/lib-isolated-home.sh's own header): a killed run still leaks a fixture
# sandbox, so isolate first rather than rely on teardown running.
# shellcheck source=/dev/null
. "$(dirname "$0")/lib-isolated-home.sh"
[ "${SANDY_TEST_NO_ISOLATE:-0}" = "1" ] || _isolate_sandy_home
SANDY_HOME_DIR="${SANDY_HOME:-$HOME/.sandy}"

# ---------------------------------------------------------------------------
# Credential gate — identical to test/acceptance-uds-delivery.sh's, and for
# the same reason: ANTHROPIC_API_KEY alone parks the receiver on the
# custom-API-key modal (it never drains its queue), which reads exactly like
# "the setting did not deliver" from the outside. Unset it before the gate so
# a host that also happens to export it is not silently misjudged as ready.
unset ANTHROPIC_API_KEY
_HAS_CRED=false
[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && _HAS_CRED=true
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && _HAS_CRED=true
[ -f "$HOME/.claude/.credentials.json" ] && _HAS_CRED=true
if [ "$_HAS_CRED" != true ] && [ "$(uname -s)" = "Darwin" ]; then
    if security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w >/dev/null 2>&1; then
        _HAS_CRED=true
    fi
fi
if [ "$_HAS_CRED" != true ]; then
    echo "=== #379: --settings precedence / repeatability measurement ==="
    echo "SKIP: no non-API-key Claude credentials (OAuth credentials.json, macOS Keychain 'Claude Code-credentials', or CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_AUTH_TOKEN). ANTHROPIC_API_KEY alone does not qualify -- see the acceptance-uds-delivery.sh header for why."
    _cleanup_sandy_home || true
    exit 0
fi

if ! command -v docker >/dev/null 2>&1 || ! docker ps >/dev/null 2>&1; then
    echo "=== #379: --settings precedence / repeatability measurement ==="
    echo "SKIP: docker is not reachable from this host."
    _cleanup_sandy_home || true
    exit 0
fi

# ---------------------------------------------------------------------------
WS="$(mktemp -d)/settings-inbound-$$"
mkdir -p "$WS/.sandy" "$WS/.sandy/probe" && (cd "$WS" && git init -q)
WS="$(cd "$WS" && pwd -P)"

_STARTED=false
_msi_cleanup() {
    if [ "$_STARTED" = true ]; then
        "$SANDY" --stop --workspace "$WS" >/dev/null 2>&1 || true
    fi
    rm -rf "$(dirname "$WS")" 2>/dev/null || true
    _cleanup_sandy_home || true
}
trap _msi_cleanup EXIT

echo "=== #379: --settings precedence / repeatability measurement ==="
echo "workspace: $WS"

if ! "$SANDY" --start --workspace "$WS" >/tmp/msi-start-log.$$ 2>&1; then
    echo "FATAL: sandy --start failed; log follows:"
    sed 's/^/  | /' "/tmp/msi-start-log.$$"
    rm -f "/tmp/msi-start-log.$$"
    exit 2
fi
rm -f "/tmp/msi-start-log.$$"
_STARTED=true

if ! "$SANDY" --exec --workspace "$WS" -- true >/dev/null 2>&1; then
    echo "FATAL: sandy --exec cannot reach the daemon container just started."
    exit 2
fi

# ---------------------------------------------------------------------------
# Container-side driver files. Written through QUOTED heredocs straight to a
# file under $WS/.sandy/probe/ — $WS is under /tmp (outside $HOME), so sandy
# mounts it at its own real path verbatim (same reasoning
# test/acceptance-uds-delivery.sh records for its own workspace), and these
# files are therefore visible inside the container at the SAME path with no
# extra copy step.

cat > "$WS/.sandy/probe/inject.py" <<'MSI_INJECT_PY'
# Adapted, mechanics unchanged, from test/acceptance-uds-delivery.sh's
# inject.py. argv: sock_path key_path marker logfile
import json, os, socket, sys, threading, time, traceback

sock_path, key_path, marker, logfile = sys.argv[1:5]

_raw = open(key_path).read().strip()
try:
    token = json.loads(_raw)["peerToken"]   # peer path -- NEVER childToken
except Exception:
    token = _raw

# Double fork + setsid: escape the caller's ancestry entirely (ppid=1),
# matching acceptance-uds-delivery.sh's inject.py and the probe rig it cites.
if os.fork() > 0:
    sys.exit(0)
os.setsid()
if os.fork() > 0:
    os._exit(0)


def log(msg):
    with open(logfile, "a") as fh:
        fh.write(msg + "\n")


try:
    reply_path = "/tmp/cc-socks/%d.sock" % os.getpid()
    body = marker + ": measurement probe, no action requested."
    receipts = []
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        os.unlink(reply_path)
    except OSError:
        pass
    srv.bind(reply_path)
    srv.listen(4)
    srv.settimeout(15)

    def _accept_loop():
        while True:
            try:
                conn, _ = srv.accept()
                conn.settimeout(8)
                receipts.append(conn.recv(8192).decode("utf8", "replace").strip())
                conn.close()
            except Exception:
                return

    threading.Thread(target=_accept_loop, daemon=True).start()

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(sock_path)
    log("connect: ok %s" % sock_path)
    s.sendall((json.dumps({"type": "auth", "token": token}) + "\n").encode())
    log("auth: sent (%d-char token)" % len(token))
    time.sleep(0.2)
    frame = json.dumps({
        "type": "user",
        "from": "uds:" + reply_path,
        "msg_id": "msi-%d" % os.getpid(),
        "message": {"role": "user", "content": body},
    })
    s.sendall((frame + "\n").encode())
    log("user-frame: sent (%d bytes)" % len(frame))
    try:
        s.settimeout(5)
        data = s.recv(4096)
        log("inbound: closed by receiver" if data == b"" else "inbound: data %r" % data[:200])
    except socket.timeout:
        log("inbound: stalled open (no bytes, not closed)")
    except Exception as e:
        log("inbound: error %s" % type(e).__name__)
    for _ in range(20):
        if receipts:
            break
        time.sleep(0.1)
    for r in receipts:
        log("receipt: %s" % r.replace("\n", " ")[:600])
    if not receipts:
        log("receipt: NONE")
    s.close()
    log("send: OK")
except Exception:
    log("send: FAILED\n" + traceback.format_exc())
try:
    os.unlink(reply_path)
except Exception:
    pass
os._exit(0)
MSI_INJECT_PY

cat > "$WS/.sandy/probe/driver.py" <<'MSI_DRIVER_PY'
# Container-side driver, run inside the sandy sandbox via `sandy --exec`.
# Never run this file on the host directly -- it execs `claude` and opens the
# cross-session UDS socket, which is meaningful only inside the sandbox.
#
# argv: driver.py <spec_dir> <run_dir> <mode> [order]
#   spec_dir/spec.json describes the layers for this case (written by the
#   host-side bash below, straight to the HOST filesystem before this
#   process ever runs). spec_dir lives under $WS/.sandy/probe/<case> --
#   `.sandy` is a protected workspace directory (CLAUDE.md "Protected
#   Files"), mounted READ-ONLY in-container, so this process only ever
#   READS spec.json (and the sibling driver.py/inject.py) from there; it
#   never writes into spec_dir. (An earlier version of this file wrote
#   cfg/, proj/, debug.log etc. straight into spec_dir and every one of
#   those os.makedirs/open(..., "w") calls raised EROFS the first time it
#   ran against a real container -- every case came back empty, which
#   _msi_case's own `2>/dev/null` then hid, so it read as a broken frame
#   rather than a read-only filesystem.)
#   run_dir is a container-only path (NOT under the workspace mount, so it
#   is writable) where every file this run actually CREATES lives: the
#   seeded CLAUDE_CONFIG_DIR (cfg/), the receiver's project dir (proj/),
#   debug.log, inject.log, and any --settings files this case writes.
#   mode is "deliver" or "argcheck". "argcheck" additionally takes an
#   order token, "AB" or "BA".
#
# Prints exactly one final line to stdout:
#   deliver:  OUTCOME:<ROUTED|HELD|REFUSED|UNKNOWN|TRANSPORT-FAIL> signature=<...>
#   argcheck: RC=<n> STDERR=<first non-empty stderr line, or (none)>
import glob, json, os, pty, shutil, signal, subprocess, sys, time

SPEC_DIR, RUN_DIR, MODE = sys.argv[1], sys.argv[2], sys.argv[3]
ORDER = sys.argv[4] if len(sys.argv) > 4 else ""

with open(os.path.join(SPEC_DIR, "spec.json")) as fh:
    SPEC = json.load(fh)

os.makedirs(RUN_DIR, exist_ok=True)
CFG = os.path.join(RUN_DIR, "cfg")
PROJ = os.path.join(RUN_DIR, "proj")
os.makedirs(CFG, exist_ok=True)
os.makedirs(PROJ, exist_ok=True)
os.makedirs(os.path.join(PROJ, ".claude"), exist_ok=True)

HOME = os.environ.get("HOME", "/home/sandy")


def seed_config():
    # First-run prompts (theme picker, trust dialog) make a session inert --
    # the same class CLAUDE.md documents for #256/#151. Seed past them.
    src_cred = os.path.join(HOME, ".claude", ".credentials.json")
    if os.path.exists(src_cred):
        shutil.copyfile(src_cred, os.path.join(CFG, ".credentials.json"))
        os.chmod(os.path.join(CFG, ".credentials.json"), 0o600)
    claude_json = {
        "hasCompletedOnboarding": True,
        "theme": "dark",
        "projects": {PROJ: {"hasTrustDialogAccepted": True}},
    }
    with open(os.path.join(CFG, ".claude.json"), "w") as fh:
        json.dump(claude_json, fh)
    if SPEC.get("user_settings") is not None:
        with open(os.path.join(CFG, "settings.json"), "w") as fh:
            json.dump(SPEC["user_settings"], fh)
    if SPEC.get("local_settings") is not None:
        with open(os.path.join(PROJ, ".claude", "settings.local.json"), "w") as fh:
            json.dump(SPEC["local_settings"], fh)


def settings_argv():
    args = []
    for f in SPEC.get("settings_flags", []):
        path = os.path.join(RUN_DIR, f["name"] + ".json")
        with open(path, "w") as fh:
            json.dump(f["content"], fh)
        args += ["--settings", path]
    return args


def _msi_classify(debug_log, pre_off, iters=30, sleep_s=0.5):
    # Isolated on purpose: test/run-tests.sh section 174(a5) extracts and
    # EXECUTES this exact function against fixture debug logs (one with no
    # signature line, one with the ROUTED signature) to prove the
    # no-signature fallback really is UNKNOWN -- rather than grepping this
    # file's TEXT for the string "UNKNOWN", which a mutated default of
    # "ROUTED" would still satisfy (the string still appears, in this very
    # comment). That grep-only check shipped once and was shown not to
    # catch this exact mutation.
    outcome, sig = "UNKNOWN", "(no decision line within poll window)"
    for _ in range(iters):
        with open(debug_log) as fh:
            fh.seek(pre_off)
            tail = fh.read()
        if "Routed user message to queue" in tail:
            for line in tail.splitlines():
                if "Routed user message to queue" in line:
                    outcome, sig = "ROUTED", line.strip()[:160]
                    break
            break
        if "held inbound peer message" in tail:
            for line in tail.splitlines():
                if "held inbound peer message" in line:
                    outcome, sig = "HELD", line.strip()[:160]
                    break
            break
        if "refused inbound peer message" in tail:
            for line in tail.splitlines():
                if "refused inbound peer message" in line:
                    outcome, sig = "REFUSED", line.strip()[:160]
                    break
            break
        time.sleep(sleep_s)
    return outcome, sig


def run_deliver():
    seed_config()
    args = settings_argv()
    debug_log = os.path.join(RUN_DIR, "debug.log")
    open(debug_log, "a").close()
    pre_off = os.path.getsize(debug_log)

    env = dict(os.environ)
    env["CLAUDE_CONFIG_DIR"] = CFG
    env.pop("ANTHROPIC_API_KEY", None)
    # The receiver's own childToken (handed to ITS children as an env var --
    # see inject.py's header comment) is never read anywhere in this file:
    # the injector authenticates with the session key file's peerToken
    # instead, which is what puts it on the peer path crossSessionInbound
    # actually governs.

    pid, master_fd = pty.fork()
    if pid == 0:
        os.chdir(PROJ)
        os.environ.update(env)
        argv = ["claude", "--debug", "--debug-file", debug_log] + args
        os.execvp("claude", argv)
        os._exit(127)

    # Drain the pty so the child never blocks on a full output buffer.
    def _drain():
        while True:
            try:
                chunk = os.read(master_fd, 4096)
                if not chunk:
                    return
            except OSError:
                return

    import threading
    threading.Thread(target=_drain, daemon=True).start()

    sock_path = "/tmp/cc-socks/%d.sock" % pid
    key_glob = os.path.join(CFG, "sessions", "%d.*.key" % pid)
    waited = 0
    keyfile = ""
    while waited < 60:
        if os.path.exists(sock_path):
            hits = glob.glob(key_glob)
            if hits:
                keyfile = hits[0]
                break
        time.sleep(1)
        waited += 1

    if not keyfile:
        print("OUTCOME:UNKNOWN signature=no-socket-or-keyfile-after-%ds" % waited)
        try:
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
        return

    inject_log = os.path.join(RUN_DIR, "inject.log")
    open(inject_log, "w").close()
    marker = "MSI-%s-%d" % (os.path.basename(RUN_DIR), os.getpid())
    subprocess.run([
        "python3", os.path.join(os.path.dirname(os.path.abspath(__file__)), "inject.py"),
        sock_path, keyfile, marker, inject_log,
    ])

    ilog = ""
    for _ in range(20):
        try:
            ilog = open(inject_log).read()
        except Exception:
            ilog = ""
        if "user-frame: sent" in ilog or "send: FAILED" in ilog:
            break
        time.sleep(0.5)

    if "user-frame: sent" not in ilog:
        print("OUTCOME:TRANSPORT-FAIL signature=frame-never-confirmed-sent")
        try:
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
        return

    outcome, sig = _msi_classify(debug_log, pre_off)

    print("OUTCOME:%s signature=%s" % (outcome, sig))
    try:
        os.kill(pid, signal.SIGKILL)
    except Exception:
        pass


def run_argcheck():
    seed_config()
    exists_path = os.path.join(RUN_DIR, "exists.json")
    with open(exists_path, "w") as fh:
        json.dump({}, fh)
    missing_path = os.path.join(RUN_DIR, "definitely-missing.json")
    if ORDER == "AB":
        flags = ["--settings", exists_path, "--settings", missing_path]
    else:
        flags = ["--settings", missing_path, "--settings", exists_path]
    env = dict(os.environ)
    env["CLAUDE_CONFIG_DIR"] = CFG
    env.pop("ANTHROPIC_API_KEY", None)
    try:
        proc = subprocess.run(
            ["claude"] + flags + ["--version"],
            cwd=PROJ, env=env, capture_output=True, text=True, timeout=30,
        )
        rc = proc.returncode
        first_err = "(none)"
        for line in (proc.stderr or "").splitlines():
            if line.strip():
                first_err = line.strip()[:160]
                break
    except subprocess.TimeoutExpired:
        rc, first_err = -1, "(timed out)"
    print("RC=%d STDERR=%s" % (rc, first_err))


if MODE == "deliver":
    run_deliver()
elif MODE == "argcheck":
    run_argcheck()
else:
    print("OUTCOME:UNKNOWN signature=unrecognized-mode-%s" % MODE)
MSI_DRIVER_PY

# ---------------------------------------------------------------------------
# _msi_case <case> <mode> [order] [user_json] [local_json] [settings_json...]
# Writes SPEC_DIR/spec.json (spec_dir is the READ-ONLY-in-container
# $WS/.sandy/probe/<case> -- see driver.py's own header for why) from the
# layer arguments (any of user/local may be the literal string "-" for "not
# set"), runs the driver via `sandy --exec` against a container-only,
# WRITABLE run_dir (/tmp/msi-probe/<case>, never under the workspace mount),
# and echoes its one result line back to the caller. --settings files are
# named ext0, ext1, ... in ARGUMENT order, which is the ORDER passed on the
# claude command line -- the thing Q3a/Q3b/Q3c/Q3d are measuring.
#
# The driver's stderr goes to spec_dir/stderr.log rather than /dev/null --
# this redirect runs in the HOST shell (it is the host-side `sandy --exec`
# invocation's own stderr), so it lands on the host filesystem regardless of
# what is read-only inside the container, and gives a RIG-INVALID something
# to show instead of a bare refusal.
_msi_case() {
    local case="$1" mode="$2" order="$3" user_json="$4" local_json="$5"
    shift 5
    local spec_dir="$WS/.sandy/probe/$case"
    local run_dir="/tmp/msi-probe/$case"
    mkdir -p "$spec_dir"

    local spec="{"
    if [ "$user_json" != "-" ]; then spec="${spec}\"user_settings\":$user_json,"; fi
    if [ "$local_json" != "-" ]; then spec="${spec}\"local_settings\":$local_json,"; fi
    spec="${spec}\"settings_flags\":["
    local first=true i=0
    for ext_json in "$@"; do
        [ "$first" = true ] || spec="${spec},"
        spec="${spec}{\"name\":\"ext${i}\",\"content\":${ext_json}}"
        first=false
        i=$((i + 1))
    done
    spec="${spec}]}"
    printf '%s' "$spec" > "$spec_dir/spec.json"

    "$SANDY" --exec --workspace "$WS" -- \
        python3 "$WS/.sandy/probe/driver.py" "$spec_dir" "$run_dir" "$mode" "$order" \
        2>"$spec_dir/stderr.log"
}

# _msi_dump_evidence <case> -- prints the driver's own stderr and whatever is
# in the in-container debug.log for a case, so a RIG-INVALID leaves something
# to read instead of nothing. Best-effort: both sources may be empty or
# gone, and that is reported as such rather than treated as an error.
_msi_dump_evidence() {
    local case="$1"
    echo "  -- driver stderr ($case), from $WS/.sandy/probe/$case/stderr.log --"
    sed 's/^/    | /' "$WS/.sandy/probe/$case/stderr.log" 2>/dev/null
    echo "  -- in-container debug.log ($case), from /tmp/msi-probe/$case/debug.log, if any --"
    "$SANDY" --exec --workspace "$WS" -- cat "/tmp/msi-probe/$case/debug.log" 2>/dev/null | sed 's/^/    | /'
}

# _msi_row <label> <layers> <raw> -- splits a raw "OUTCOME:<X> signature=<...>"
# (or "RC=<n> STDERR=<...>") result string into real outcome/signature table
# columns, rather than putting the whole raw string in one column next to a
# static placeholder in the other.
_msi_row() {
    local label="$1" layers="$2" raw="$3"
    local outcome sig rest
    case "$raw" in
        OUTCOME:*)
            rest="${raw#OUTCOME:}"
            outcome="${rest%% signature=*}"
            sig="${rest#*signature=}"
            ;;
        *)
            outcome="UNPARSED"
            sig="$raw"
            ;;
    esac
    printf '| %s | %s | %s | %s |\n' "$label" "$layers" "$outcome" "$sig"
}

# _msi_q3d_reading <ab_raw> <ba_raw> -- COMPUTES the Q3d conclusion from the
# two argcheck exit codes instead of leaving static prose that assumes one
# of only two possible shapes. A third shape is real: `--version` may
# short-circuit before --settings is fully parsed, in which case NEITHER
# order errors on the missing file and the case is inconclusive rather than
# evidence of repeatability either way.
_msi_q3d_reading() {
    local ab="$1" ba="$2" ab_rc ba_rc
    ab_rc="${ab#RC=}"; ab_rc="${ab_rc%% *}"
    ba_rc="${ba#RC=}"; ba_rc="${ba_rc%% *}"
    if [ "$ab_rc" = "0" ] && [ "$ba_rc" = "0" ]; then
        echo "INCONCLUSIVE: neither order errored on the missing file. --version likely"
        echo "short-circuits before --settings is fully parsed on this build -- rerun Q3d"
        echo "with a subcommand that forces full settings resolution instead of --version"
        echo "before reading this either way."
    elif [ "$ab_rc" != "0" ] && [ "$ba_rc" != "0" ]; then
        echo "Both orders errored on the missing file -- --settings is REPEATABLE (every"
        echo "occurrence is read, not only the last one); see Q3c for merge-vs-replace."
    elif [ "$ab_rc" != "0" ]; then
        echo "Only exists-then-missing (AB) errored -- --settings is LAST-WINS (only the"
        echo "final occurrence is ever consulted)."
    else
        echo "Only missing-then-exists (BA) errored -- --settings is LAST-WINS (only the"
        echo "final occurrence is ever consulted); the missing file surfaces only when it"
        echo "is that final occurrence."
    fi
}

# ---------------------------------------------------------------------------
echo ""
echo "-- running rig-validity controls --"

_MSI_K1="$(_msi_case k1 deliver "" '{"crossSessionInbound":"accept"}' - )"
echo "  K1 (userSettings accept, nothing else): $_MSI_K1"
case "$_MSI_K1" in
    OUTCOME:ROUTED*) ;;
    *)
        echo ""
        echo "RIG-INVALID: K1 (userSettings accept, no local, no --settings) did not ROUTE."
        echo "  Every other result below would be meaningless, so nothing further ran."
        echo "  This means the rig itself is broken (container/exec/config-seeding/socket-wait/"
        echo "  inject-frame), not that sandy's own posture regressed -- re-derive the frame"
        echo "  against the current Claude Code build the way docs/security/"
        echo "  CROSS_SESSION_INBOUND.md §6a did, before assuming a Claude Code change."
        _msi_dump_evidence k1
        exit 2
        ;;
esac

_MSI_K2="$(_msi_case k2 deliver "" - '{"crossSessionInbound":"refuse"}' )"
echo "  K2 (no userSettings key, local refuse): $_MSI_K2"
case "$_MSI_K2" in
    OUTCOME:REFUSED*) ;;
    *)
        echo ""
        echo "RIG-INVALID: K2 (no userSettings key, local refuse) did not REFUSE."
        echo "  Several Q cases below rely on the workspace tighten-only layer actually"
        echo "  blocking so that --settings can be isolated from userSettings -- if it does"
        echo "  not block here, those readings cannot be trusted either, so nothing further ran."
        _msi_dump_evidence k2
        exit 2
        ;;
esac

echo ""
echo "-- baseline: no crossSessionInbound key in ANY layer --"
_MSI_Q0="$(_msi_case q0 deliver "" '{}' - )"
echo "  Q0 (no key anywhere): $_MSI_Q0"

echo ""
echo "-- running Q1/Q2/Q3 --"

_MSI_Q1="$(_msi_case q1 deliver "" '{}' '{"crossSessionInbound":"refuse"}' '{"crossSessionInbound":"accept"}')"
_MSI_Q2="$(_msi_case q2 deliver "" '{"crossSessionInbound":"refuse"}' - '{"crossSessionInbound":"accept"}')"
_MSI_Q3A="$(_msi_case q3a deliver "" - - '{"crossSessionInbound":"accept"}' '{"crossSessionInbound":"refuse"}')"
_MSI_Q3B="$(_msi_case q3b deliver "" - - '{"crossSessionInbound":"refuse"}' '{"crossSessionInbound":"accept"}')"
_MSI_Q3C="$(_msi_case q3c deliver "" - - '{"crossSessionInbound":"accept"}' '{"cleanupPeriodDays":30}')"
_MSI_Q3D_AB="$(_msi_case q3d-ab argcheck AB - - )"
_MSI_Q3D_BA="$(_msi_case q3d-ba argcheck BA - - )"

echo ""
echo "==================================================="
echo "RESULT TABLE (paste into docs/security/CROSS_SESSION_INBOUND.md §9)"
echo "==================================================="
_MSI_CC_VER="$("$SANDY" --exec --workspace "$WS" -- claude --version 2>/dev/null || echo unknown)"
_MSI_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
echo "Claude Code version (in-container): $_MSI_CC_VER"
echo "Measured: $_MSI_DATE"
echo ""
echo "| case | layers | outcome | signature line |"
echo "|---|---|---|---|"
_msi_row "K1" "userSettings=accept" "$_MSI_K1"
_msi_row "K2" "userSettings=(absent), local=refuse" "$_MSI_K2"
_msi_row "Q0" "baseline: no crossSessionInbound key in any layer" "$_MSI_Q0"
_msi_row "Q1" "userSettings={}, local=refuse, --settings=accept" "$_MSI_Q1"
_msi_row "Q2" "userSettings=refuse, --settings=accept" "$_MSI_Q2"
_msi_row "Q3a" "--settings accept, --settings refuse (A then B)" "$_MSI_Q3A"
_msi_row "Q3b" "--settings refuse, --settings accept (B then A)" "$_MSI_Q3B"
_msi_row "Q3c" "--settings accept, --settings {cleanupPeriodDays:30}" "$_MSI_Q3C"
echo "| Q3d-AB | --settings exists --settings /nonexistent --version | $_MSI_Q3D_AB | n/a |"
echo "| Q3d-BA | --settings /nonexistent --settings exists --version | $_MSI_Q3D_BA | n/a |"
echo ""
echo "Reading Q0: it is the unset-default control the Q3c reading depends on -- if Q0"
echo "does NOT route, the unset default here is not accept, which is what makes a"
echo "ROUTED Q3c legible as 'merge onto the earlier file', not 'replaced by the unset"
echo "default'."
echo ""
echo "Reading Q3d:"
_msi_q3d_reading "$_MSI_Q3D_AB" "$_MSI_Q3D_BA"
echo "==================================================="

exit 0
