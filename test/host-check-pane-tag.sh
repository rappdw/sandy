#!/usr/bin/env bash
# test/host-check-pane-tag.sh — host-only, live-tmux acceptance for #378's
# single-agent pane tagging (decisions.md, fix pass on #378).
#
# WHAT THIS PROVES that a fixture-based unit test (run-tests.sh §171) cannot:
# that the EXACT tmux command forms sandy's daemon and foreground single-agent
# launch paths now use really do set @sandy_pane_agent on the pane sandy
# itself creates, that a pane sandy did NOT create (a user split) is left
# untagged, and that the foreground form's attach-then-exit behavior — the
# session ends and the launching command returns once the agent exits — is
# unchanged from before 2.4.0.
#
# PRIVATE SERVER. Every tmux command below goes through a private socket
# (`-L sandy-pane-tag-check-$$`) AND `-f /dev/null`, so this can never touch
# the operator's own tmux server or config, nor collide with a live sandy
# session that might be hosting this very shell.
#
# ⚠️ DO NOT RUN THIS INSIDE A SANDY SANDBOX. tmux inside a sandy container
# shares that container's tmux server with the live agent session — see
# CLAUDE.md "Never run tmux ... from inside the sandy sandbox". This script
# refuses outright (see the /etc/sandy-session.json check below).
#
# Usage: bash test/host-check-pane-tag.sh   (on the HOST, needs a real tmux)
set -uo pipefail

if [ -f /etc/sandy-session.json ]; then
    echo "REFUSING: /etc/sandy-session.json is present -- this looks like a sandy" >&2
    echo "sandbox. Running tmux here would collide with the live session's own" >&2
    echo "tmux server. Run this script on the HOST instead." >&2
    exit 2
fi

command -v tmux >/dev/null 2>&1 || { echo "tmux not found -- run this on a host with tmux" >&2; exit 2; }

PASS=0
FAIL=0
ck() { if eval "$2" >/dev/null 2>&1; then printf '  PASS %s\n' "$1"; PASS=$((PASS + 1));
       else printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); fi; }

SOCK="sandy-pane-tag-check-$$"
# -f /dev/null on every private-server invocation: without it a NEW server
# (the first tmux -L "$SOCK" call, which starts it) loads the OPERATOR's own
# ~/.tmux.conf, and settings there (remain-on-exit on, destroy-unattached,
# exit-empty off) can make the "session ends" / "driver session ends" checks
# below fail spuriously, or pass for the wrong reason (#378 fix-pass
# verifier finding). -f is a client/server startup option and is harmless on
# a call that only attaches to an already-running private server.
TM() { tmux -L "$SOCK" -f /dev/null "$@"; }

WSTMP="$(mktemp -d)"
cleanup() {
    TM kill-server >/dev/null 2>&1
    rm -rf "$WSTMP"
}
trap cleanup EXIT

# Trivial stand-in for the real agent, per decisions.md item 5.
AGENT_CMD="sh -c 'sleep 3'"
FAKE_AGENT="testagent"
NAME="sandy: host-check-pane-tag"

# _pane_tag PANE -> the pane's @sandy_pane_agent value, or "" if unset.
_pane_tag() { TM show-options -p -v -t "$1" @sandy_pane_agent 2>/dev/null; }

# ------------------------------------------------------------------
echo "== daemon form (tmux new-session -d -P -F '#{pane_id}' -s sandy ...; tmux set-option -p ...) =="
# ------------------------------------------------------------------
_p_id="$(TM new-session -d -P -F '#{pane_id}' -s sandy -n "$NAME" -- bash -c "$AGENT_CMD 2>&1")"
ck "daemon: the session comes up" "TM has-session -t sandy"
TM set-option -p -t "$_p_id" @sandy_pane_agent "$FAKE_AGENT" 2>/dev/null
ck "daemon: @sandy_pane_agent is set on the pane sandy created" \
    "[ \"\$(_pane_tag \"$_p_id\")\" = \"$FAKE_AGENT\" ]"

# A pane sandy did NOT create (a user split) must be left untagged.
TM split-window -t sandy -- bash -c "sleep 5" >/dev/null 2>&1
_split_pane="$(TM list-panes -t sandy -F '#{pane_id}' | sed -n '2p')"
ck "daemon: a second, user-split pane has NO @sandy_pane_agent" \
    "[ -z \"\$(_pane_tag \"$_split_pane\")\" ]"

TM kill-session -t sandy >/dev/null 2>&1

# ------------------------------------------------------------------
echo "== foreground form (create detached, tag, then attach -- matches sandy's actual form, no exec) =="
# ------------------------------------------------------------------
# tmux's attach needs a real controlling terminal to behave like a live
# foreground launch, not just error out immediately for lack of one. Rather
# than depend on `script`, whose flag syntax diverges between BSD (macOS) and
# util-linux (Linux) -- exactly the portability trap this repo's own
# lint-bash32 exists to catch -- this wraps the foreground form in ANOTHER
# pane on the SAME private tmux server: tmux allocates a real pty for every
# pane it creates, so the wrapper gets one with no human attached and no
# platform-specific tool needed. This is the "with the client detached"
# alternative to `script`.
#
# `unset TMUX` is load-bearing, not decoration: the wrapper's own process is
# itself the command of a pane on THIS SAME private tmux server (the "driver"
# session below), so tmux has already exported $TMUX into it. tmux's attach
# refuses a client whose tty belongs to one of that server's own panes when
# $TMUX is set ("sessions should be nested with care, unset $TMUX to force"),
# which fails at once and would tear the driver session down immediately --
# making "the launching command returns" pass without proving anything (the
# fix-pass verifier caught exactly this). Sandy's real launch does not need
# this: user-setup.sh runs as PID 1 of a container with no enclosing tmux
# client, so $TMUX is never set there.
_fg_wrapper="$WSTMP/fg-wrapper.sh"
cat > "$_fg_wrapper" <<EOF
#!/bin/sh
unset TMUX
_p_id="\$(tmux -L "$SOCK" -f /dev/null new-session -d -P -F '#{pane_id}' -s sandy -n "$NAME" -- bash -c "$AGENT_CMD 2>&1")"
tmux -L "$SOCK" -f /dev/null set-option -p -t "\$_p_id" @sandy_pane_agent "$FAKE_AGENT" 2>/dev/null
tmux -L "$SOCK" -f /dev/null attach -t sandy
EOF
chmod +x "$_fg_wrapper"

TM new-session -d -s driver -n driver -- "$_fg_wrapper"

# Rise: the inner "sandy" session should appear, tagged, within a few seconds.
_i=0
while [ "$_i" -lt 20 ] && ! TM has-session -t sandy 2>/dev/null; do sleep 0.2; _i=$((_i + 1)); done
ck "foreground: the session comes up" "TM has-session -t sandy"
_fg_pane="$(TM list-panes -t sandy -F '#{pane_id}' 2>/dev/null | sed -n '1p')"
ck "foreground: @sandy_pane_agent is set on the pane sandy created" \
    "[ -n \"$_fg_pane\" ] && [ \"\$(_pane_tag \"$_fg_pane\")\" = \"$FAKE_AGENT\" ]"

# Proof the attach really BLOCKED rather than having already errored out and
# torn the driver session down before the agent's `sleep 3` had a chance to
# finish: check the driver session is still alive right here, well before the
# agent exits. Without this, an attach that failed instantly (e.g. the $TMUX
# nesting refusal above, if it regressed) would make the later "driver session
# ends" check pass immediately for the wrong reason, proving nothing.
ck "foreground: the driver session is still alive right after the tag check (attach really blocked, did not already exit)" \
    "TM has-session -t driver"

# Fall: once the trivial agent's `sleep 3` exits, both the inner "sandy"
# session AND the driver session (whose sole pane IS the attach client) are
# destroyed -- proving the launching command returns rather than hanging.
_i=0
while [ "$_i" -lt 40 ] && TM has-session -t driver 2>/dev/null; do sleep 0.2; _i=$((_i + 1)); done
ck "foreground: the launching command returns once the agent exits (driver session ends)" \
    "! TM has-session -t driver"
ck "foreground: the session ends along with the agent" "! TM has-session -t sandy"

echo ""
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ]
