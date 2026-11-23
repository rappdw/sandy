#!/usr/bin/env bash
# Builds a --print-state fixture: a SANDY_HOME whose sandboxes, features and
# approvals reach every per-sandbox branch of _sandy_emit_state that does not
# depend on the host (no parser-dependent settings statuses, no non-ASCII file
# NAMES, no invalid UTF-8: BSD sed refuses it where GNU sed does not, so the
# output would differ between hosts for reasons that are not sandy's). Also
# writes ROOT/bin/docker, a stub with fixed answers, so the running_containers
# loop and the daemon fields run without docker.
#
# Usage: make-home.sh ROOT LIVE_PID DEAD_PID
#   ROOT      an empty directory; the SANDY_HOME is ROOT/home
#   LIVE_PID  a pid that is alive while --print-state runs (lock "live")
#   DEAD_PID  a pid that is not (lock "stale")
# The output names ROOT, both pids and each sandbox's size (full mode), so a
# comparison normalises those three before comparing bytes.
#
# Sandbox names start a<NN>- so the glob order is the same in every locale.
# Used by run-tests.sh §242; keep it BSD safe (macOS userland, bash 5).
set -euo pipefail
ROOT="$1"; LIVE="$2"; DEAD="$3"
H="$ROOT/home"; SB="$H/sandboxes"
mkdir -p "$SB" "$H/approvals" "$H/features" "$ROOT/bin" "$ROOT/ws"
TAB="$(printf '\t')"

stamp() { TZ=UTC touch -t "$1" "$2"; }
vers() { # dir created [last]
    printf '%s\n' "$2" > "$1/.sandy_created_version"; stamp 202601020304.05 "$1/.sandy_created_version"
    if [ $# -ge 3 ]; then printf '%s\n' "$3" > "$1/.sandy_last_version"; stamp 202602030405.06 "$1/.sandy_last_version"; fi
}

# a01: a complete current marker, every marker-derived field present.
d="$SB/a01-full-11111111"; mkdir -p "$d/claude" "$d/feature-state/featA" "$ROOT/ws/one"
vers "$d" "2.8.0" "2.9.0-dev"
printf '{ "schema_version": 1, "sandbox_name": "a01-full-11111111", "workspace_path": "%s" }\n' "$ROOT/ws/one" > "$d/WORKSPACE.json"
cat > "$d/sandy-session.json" <<EOF
{
  "schema": 1,
  "sandy_version": "2.9.0-dev",
  "workspace": "/ws/one",
  "launched_at": "2026-11-01T10:11:12Z",
  "cross_session_inbound": "accept",
  "cross_session_inbound_source": "feature:featA",
  "agents": ["claude","codex"],
  "image": {"name": "sandy-full", "id": "sha256:0123456789abcdef", "project_layer": false},
  "agent_args": {"claude": ["--append-system-prompt-file", "/opt/sandy/features/featA/p.md"]},
  "agent_args_composed": {"claude": [{"flag": "--x", "composed": true}]},
  "agent_wrappers": {"claude": "featA"},
  "feature_entries": {
    "featA": {"path": "/opt/sandy/features/featA/bin/run"},
    "featB": {"path": "/opt/sandy/features/featB/missing"},
    "featC": {"path": "/usr/local/bin/elsewhere"}
  },
  "claude_sessions": ["main", "side"]
}
EOF
printf 'state=running\nrestarts=3\nlast_exit_code=1\nlast_restart_at=2026-11-01T10:12:00Z\nnoise=x\n' > "$d/feature-state/featA/.state"
mkdir -p "$H/features/featA/payload/bin" "$H/features/featA/.selected" "$H/features/featB/.selected"
printf '#!/bin/sh\n' > "$H/features/featA/payload/bin/run"
: > "$H/features/featA/.selected/a01-full-11111111"
printf 'needs a newer sandy\tdetail\n' > "$H/features/featB/.selected/a01-full-11111111"
printf -- '--verbose\n' > "$d/agent-args.claude"; printf -- '-x\n' > "$d/agent-args.mirror"
# Session status: a launch row, rows with control bytes, quotes, backslashes,
# UTF-8, an extra trailing field (read lumps it into the last one), an empty
# slug (skipped), and a leading-tab row (IFS whitespace collapses it).
{
    printf 'launch\tL-1\001\n'
    printf 'main\tready\tsid-1\tMain "one" \\ é\ttrue\tnone\tok\n'
    printf 'side\tstarting\tsid\0033x\tname\001x\tfalse\tdrift\treason%sextra%sfields\n' "$TAB" "$TAB"
    printf '\tskipped\tleading\n'
    printf 'ünï\tcödé\t\t\t\t\t\n'
} > "$d/claude/.sandy-sessions.tsv"
mkdir -p "$d/locks"
mkdir "$SB/.a01-full-11111111.lock"; printf '%s\n' "$DEAD" > "$SB/.a01-full-11111111.lock/pid"

# a02: an OLDER marker (relay_alias shape, relay-state fallback), inbound null
# with claude launched, no source line.
d="$SB/a02-legacy-22222222"; mkdir -p "$d/relay-state"
vers "$d" "2.5.0"
printf '{"workspace_path":"/nonexistent/a02"}\n' > "$d/WORKSPACE.json"
cat > "$d/sandy-session.json" <<'EOF'
{
  "schema": 1,
  "sandy_version": "2.5.0",
  "launched_at": "2026-01-01T00:00:00Z",
  "cross_session_inbound": null,
  "agents": ["claude"],
  "feature_entries": {
    "relayer": {"path": "/opt/sandy/features/relayer/r", "relay_alias": true, "disabled_by": null},
    "other": {"path": "/opt/sandy/features/other/o", "relay_alias": false, "disabled_by": null}
  }
}
EOF
printf 'state=backoff\nrestarts=\nlast_exit_code=\n' > "$d/relay-state/.state"
mkdir "$SB/.a02-legacy-22222222.lock"; printf '%s\n' "$LIVE" > "$SB/.a02-legacy-22222222.lock/pid"

# a03: no marker, no WORKSPACE.json, no last version; a lock with no pid file.
d="$SB/a03-nomarker-33333333"; mkdir -p "$d"
vers "$d" "0.14.0"
mkdir "$SB/.a03-nomarker-33333333.lock"

# a04: a marker with no schema line (unreadable) and a mis-shaped image.
d="$SB/a04-noschema-44444444"; mkdir -p "$d"
vers "$d" "2.0.0" "2.0.1"
cat > "$d/sandy-session.json" <<'EOF'
{
  "sandy_version": "2.0.0",
  "image": {"name": "sandy full", "id": null, "project_layer": false},
  "agents": ["gemini"],
  "agent_args": {},
EOF
mkdir "$SB/.a04-noschema-44444444.lock"; printf 'not-a-pid\n' > "$SB/.a04-noschema-44444444.lock/pid"

# a05: the marker is a directory; a06: a dangling link.
d="$SB/a05-markerdir-55555555"; mkdir -p "$d/sandy-session.json"; vers "$d" "2.1.0"
d="$SB/a06-dangling-66666666"; mkdir -p "$d"; vers "$d" "2.1.0"
ln -s "$ROOT/nowhere" "$d/sandy-session.json"

# a07: odd characters everywhere sandy reads a value back verbatim.
d="$SB/a07-odd-77777777"; mkdir -p "$d"
printf '2.9.0 "q" \\ b\ttab\r\n\nsecond line\n\n\n' > "$d/.sandy_created_version"; stamp 202603040506.07 "$d/.sandy_created_version"
printf '' > "$d/.sandy_last_version"; stamp 202603040506.08 "$d/.sandy_last_version"
printf '{"x": 1,\n "workspace_path" :  "/nonexistent/sp ace/\\"quoted\\"/ü\\tt", "workspace_path": "/no/second"}\n{"workspace_path": "/no/third"}\n' > "$d/WORKSPACE.json"
cat > "$d/sandy-session.json" <<'EOF'
{
  "schema": 1,
  "sandy_version": "2.9.0-dev+ü\x",
  "launched_at": "2026-11-01T10:11:12Z — ü",
  "cross_session_inbound": "hold",
  "cross_session_inbound_source": "bad source!",
  "agents": ["codex"],
  "image": {"name": "sandy-codex", "id": null, "project_layer": true},
  "agent_args": {"codex": ["-c", "a=\"b\\c\""]},
  "agent_args": {"codex": ["last", "wins"]},
  "agent_args_composed": {},
  "agent_wrappers": {},
  "feature_entries": {},
  "claude_sessions": []
}
EOF

# a08: inbound null without claude (not_claude), a stray line that matches
# the unanchored agents pattern after the real one (last wins), and an
# entry-shaped line with no "feature_entries" key (feature_entries null).
d="$SB/a08-notclaude-88888888"; mkdir -p "$d"; vers "$d" "2.7.0" "2.7.0"
cat > "$d/sandy-session.json" <<'EOF'
{
  "schema": 1,
  "sandy_version": "",
  "launched_at": "",
  "agents": ["codex"],
  "cross_session_inbound": null,
  "cross_session_inbound_source": null,
  "github": {"note": "x", "agents": ["grok","opencode"], "y": 1},
  "credentials": {
    "tok": {"path": "/opt/sandy/features/t/x"}
  },
  "claude_sessions": ["s"]
}
EOF
mkdir -p "$d/claude"; ln -s "$ROOT/nowhere" "$d/claude/.sandy-sessions.tsv"

# a09: inbound null and NO agents line (unknown); an unknown inbound value
# later in the file wins over the null (last line wins).
d="$SB/a09-unknown-99999999"; mkdir -p "$d"; vers "$d" "2.7.0"
cat > "$d/sandy-session.json" <<'EOF'
{
  "schema": 1,
  "cross_session_inbound": null,
  "cross_session_inbound": "maybe",
  "cross_session_inbound_source": "explicit",
  "feature_entries": {"x": 1}
}
EOF

# a10: a sandbox NAME with a space, quote, backslash and tab, and a lock
# holder pid file with surrounding text.
n="a10-sp ace\"q\\b${TAB}t-aaaaaaaa"; d="$SB/$n"; mkdir -p "$d"; vers "$d" "2.8.0"
printf '{"workspace_path": "%s"}\n' "$ROOT/ws/one" > "$d/WORKSPACE.json"
mkdir "$SB/.$n.lock"; printf '12 34\n' > "$SB/.$n.lock/pid"
: > "$H/features/featA/.selected/$n"

# a11: claude_sessions with more than 64 status lines (only 64 are read), and
# settings files whose answers need no parser: a link (unreadable), and none.
d="$SB/a11-many-bbbbbbbb"; mkdir -p "$d/claude"; vers "$d" "2.9.0"
printf '{"workspace_path": "%s"}\n' "$ROOT/ws/one" > "$d/WORKSPACE.json"
printf '{\n  "schema": 1,\n  "agents": ["claude"],\n  "claude_sessions": ["s0"],\n}\n' > "$d/sandy-session.json"
i=0; : > "$d/claude/.sandy-sessions.tsv"
while [ "$i" -lt 70 ]; do printf 's%02d\tready\n' "$i" >> "$d/claude/.sandy-sessions.tsv"; i=$((i + 1)); done
ln -s "$ROOT/nowhere" "$d/claude/settings.json"

# a12: CRLF marker lines (the ",$"-anchored readers miss them), and a marker
# whose last line has no newline.
d="$SB/a12-crlf-cccccccc"; mkdir -p "$d"; vers "$d" "2.9.0"
printf '{\r\n  "schema": 1,\r\n  "sandy_version": "2.9.0",\r\n  "launched_at": "2026-01-01T00:00:00Z",\r\n  "agents": ["claude"],\r\n  "agent_wrappers": {"claude": "w"}' > "$d/sandy-session.json"

# a13: inbound null and no agents line at all (status unknown).
d="$SB/a13-noagents-dddddddd"; mkdir -p "$d"; vers "$d" "2.9.0"
printf '{\n  "schema": 1,\n  "cross_session_inbound": null,\n  "cross_session_inbound_source": "default",\n}\n' > "$d/sandy-session.json"

# a14: one line that two readers match (agents is unanchored): each must see
# the ORIGINAL line, so agent_args keeps its value and agents finds its own.
d="$SB/a14-overlap-eeeeeeee"; mkdir -p "$d"; vers "$d" "2.9.0"
printf '{\n  "schema": 1,\n  "agent_args": {"agents": ["claude","x"]},\n  "image": {"name": "sandy-x", "id": null, "project_layer": false},\n  "agent_wrappers": {"agents": ["w"]}\n}\n' > "$d/sandy-session.json"

# a15: every marker field twice, the two values different: each reader must
# report the LAST (what `| tail -n 1` gave), never the first.
d="$SB/a15-dups-ffffffff"; mkdir -p "$d"; vers "$d" "2.9.0" "2.9.1"
cat > "$d/sandy-session.json" <<'EOF'
{
  "schema": 1,
  "sandy_version": "1.0.0-first",
  "launched_at": "2020-01-01T00:00:00Z",
  "cross_session_inbound": "refuse",
  "cross_session_inbound_source": "explicit",
  "agents": ["codex"],
  "image": {"name": "sandy-first", "id": null, "project_layer": false},
  "agent_args": {"first": 1},
  "agent_args_composed": {"first": 1},
  "agent_wrappers": {"first": 1},
  "claude_sessions": ["first"],
  "sandy_version": "2.9.0-last",
  "launched_at": "2026-11-11T11:11:11Z",
  "cross_session_inbound": "hold",
  "cross_session_inbound_source": "feature:last",
  "agents": ["claude","gemini"],
  "image": {"name": "sandy-last", "id": "sha256:abc", "project_layer": true},
  "agent_args": {"last": 2},
  "agent_args_composed": {"last": 2},
  "agent_wrappers": {"last": 2},
  "claude_sessions": ["last"],
}
EOF

# a16: only the LAST-used version stamp exists (created_at stays empty).
d="$SB/a16-lastonly-a1a1a1a1"; mkdir -p "$d"
printf '2.9.2\n' > "$d/.sandy_last_version"; stamp 202604050607.08 "$d/.sandy_last_version"

# a17: inbound null and agents naming claude only inside another word
# ("claude-code" is not the agent claude): not_claude.
d="$SB/a17-claudeish-b2b2b2b2"; mkdir -p "$d"; vers "$d" "2.9.0"
printf '{\n  "schema": 1,\n  "agents": ["claude-code"],\n  "cross_session_inbound": null,\n}\n' > "$d/sandy-session.json"

# Approvals: full, missing comment lines, leading whitespace, no final newline.
printf 'abc123\n# workspace: /ws/one\n# approved: 2026-01-01T00:00:00Z\nKEY=V\n' > "$H/approvals/passive-aaaa1111.list"
printf 'def456\nKEY=V\n' > "$H/approvals/passive-bbbb2222.list"
printf 'ghi789\n#  workspace:x\n# workspace:  \t /ws/two "q" \\b\n# approved:\t2026' > "$H/approvals/passive-cccc3333.list"
printf 'jkl\n# workspace: /ws/first\n# workspace: /ws/second\n# approved: a1\n# approved: a2\n' > "$H/approvals/passive-dddd4444.list"
printf 'ctx1\n# approved: 2026-02-02T00:00:00Z\n# workspace: /ws/df\n' > "$H/approvals/dockerfile-dddd4444.list"
printf '' > "$H/approvals/dockerfile-eeee5555.list"

# The docker stub: fixed answers, so running_containers (light and full) and
# the daemon fields run. Only `ps` (no -a) lists containers; everything else
# the full path asks answers empty or fails, deterministically.
cat > "$ROOT/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    info) exit 0 ;;
    ps)
        case " $* " in *" -a "*|*" --all "*) exit 0 ;; esac
        printf '%s\n' \
            'c1aaaaaaaaaa|sandy-a01-full-11111111|sandy-full|2026-11-01 10:00:00 +0000 UTC|true|a01-full-11111111|' \
            'c2bbbbbbbbbb|sandy-proxy-sandy-x|sandy-proxy|2026-11-01 10:00:01 +0000 UTC|||' \
            'c3cccccccccc|sandy-a02-legacy-22222222|sandy-claude-code|2026-11-01 10:00:02 +0000 UTC|true||2026-11-02T00:00:00Z' \
            'c4dddddddddd|unrelated|postgres|2026-11-01 10:00:03 +0000 UTC|||' \
            'c5eeeeeeeeee|sandy_odd "q" \ x|img|t|false|s|u|extra|fields' \
            'c6ffffffffff|sandy-short'
        ;;
    exec)
        case " $* " in *" c1aaaaaaaaaa "*) printf '2\n' ;; *) exit 1 ;; esac ;;
    inspect) printf 'c1aaaaaaaaaafull|sha256:run|sandy-full\n' ;;
    image)
        case " $* " in *" sandy-full"*) printf 'sha256:run\n' ;; *) exit 1 ;; esac ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$ROOT/bin/docker"
