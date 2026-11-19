#!/usr/bin/env bash
# Unit checks for the no-fork readers --print-state uses (B7): each is run
# against the forking form it replaced, on a table of inputs chosen to break
# a naive version (quotes, backslashes, control bytes, CR, NUL, UTF-8,
# invalid UTF-8, missing/empty/odd files). The forking forms are the
# reference, run here with the host's own tools, so a check fails on any
# input where bash and the tools disagree.
#
# Usage: unit-checks.sh SANDY_SCRIPT GROUP   (GROUP: escape|file|ascii|ws|approval|split|marker)
# Prints one line per mismatch and exits 1 if there was any; exits 2 if the
# functions could not be extracted (so a rename cannot pass vacuously).
# Used by run-tests.sh §242; bash-3.2 and BSD safe.
set -u
SANDY="$1"; GROUP="$2"
_fns="$(sed -n \
    -e '/^_json_escape_v() {$/,/^}$/p' \
    -e '/^_json_escape() {$/,/^}$/p' \
    -e '/^_sandy_read_file_v() {$/,/^}$/p' \
    -e '/^_sandy_ctl_strip_v() {$/,/^}$/p' \
    -e '/^_SANDY_ASCII_PRINT=/p' \
    -e '/^_sandy_is_ascii_print() {$/,/^}$/p' \
    -e '/^_sandy_ps_ws_path() {$/,/^}$/p' \
    -e '/^_sandy_ps_approval_v() {$/,/^}$/p' \
    -e '/^_sandy_ps_split7_v() {$/,/^}$/p' \
    -e '/^_SANDY_SLURP_MAX=/p' \
    -e '/^_sandy_slurp_v() {$/,/^}$/p' \
    -e '/^_sandy_ps_ws_path_cmd() {$/,/^}$/p' \
    -e '/^_sandy_first_line_v() {$/,/^}$/p' \
    -e '/^_sandy_ps_marker_read() {$/,/^}$/p' \
    -e '/^_sandy_ps_marker_read_cmd() {$/,/^}$/p' \
    "$SANDY")"
eval "$_fns"
for _f in _json_escape_v _json_escape _sandy_read_file_v _sandy_ctl_strip_v _sandy_is_ascii_print \
          _sandy_ps_ws_path _sandy_ps_approval_v _sandy_ps_split7_v _sandy_slurp_v _sandy_ps_ws_path_cmd \
          _sandy_first_line_v _sandy_ps_marker_read _sandy_ps_marker_read_cmd; do
    command -v "$_f" >/dev/null 2>&1 || { echo "could not extract $_f from $SANDY"; exit 2; }
done
[ -n "${_SANDY_ASCII_PRINT:-}" ] || { echo "could not extract _SANDY_ASCII_PRINT"; exit 2; }

# The definition every release up to 2.9.0 shipped, verbatim.
_ref_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

BAD=0; N=0
miss() { BAD=1; printf 'MISMATCH %s\n' "$*"; }
q() { printf '%q' "$1"; }

# Inputs: every byte 1..255 alone and between letters, plus a table.
_inputs() {
    local i c
    for i in $(seq 1 255); do
        c="$(printf "\\$(printf '%03o' "$i")")"
        [ "$i" = 10 ] && c=$'\n'
        printf '%s\0' "$c" "a${c}b" "${c}${c}"
    done
    printf '%s\0' "" "plain" '\' '\\' '"' '\"' '"\' $'\n' $'\r\n' $'\t' $'a\tb\nc\rd' \
        'é ü 日本 🎉' $'\xff\xfe' $'caf\xe9' $'\xc3' '%s %% %b \n' '-n' '-e' '--' \
        "$(printf '%0300d' 0 | tr 0 '\\')" "$(printf '%0300d' 0 | tr 0 '"')" \
        $'mixed "q" \\ \t \001 \037 \177 é \xff end'
}

case "$GROUP" in
escape)
    while IFS= read -r -d '' s; do
        N=$((N + 1))
        r="$(_ref_json_escape "$s")"
        a="$(_json_escape "$s")"
        _json_escape_v "$s"
        [ "$a" = "$r" ] || miss "_json_escape $(q "$s"): $(q "$a") != $(q "$r")"
        [ "$_SANDY_JE" = "$r" ] || miss "_json_escape_v $(q "$s"): $(q "$_SANDY_JE") != $(q "$r")"
    done < <(_inputs)
    ;;
ascii)
    while IFS= read -r -d '' s; do
        N=$((N + 1))
        # Reference: printable ASCII and tab only, decided byte by byte.
        exp=0
        if [ -n "$s" ]; then
            t="$(printf '%s' "$s" | LC_ALL=C tr -d '\011\040-\176'; echo x)"; t="${t%x}"
            [ -z "$t" ] && exp=1
        else
            exp=1
        fi
        if _sandy_is_ascii_print "$s"; then got=1; else got=0; fi
        [ "$got" = "$exp" ] || miss "_sandy_is_ascii_print $(q "$s"): $got != $exp"
        _sandy_ctl_strip_v "$s"
        t="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\037')"
        [ "$_SANDY_CS" = "$t" ] || miss "_sandy_ctl_strip_v $(q "$s"): $(q "$_SANDY_CS") != $(q "$t")"
    done < <(_inputs)
    ;;
file|ws|approval|marker)
    D="$(mktemp -d)"; D="$(cd "$D" && pwd -P)"
    trap 'rm -rf "$D"' EXIT
    _mk() { # name printf-format
        printf "$2" > "$D/$1"
    }
    _bytes() { head -c "$1" /dev/zero | tr '\000' x; }
    _big() { { _bytes "$(($2 - 1))"; printf '\n'; } > "$D/$1"; }   # exactly $2 bytes
    if [ "$GROUP" = file ]; then
        _mk empty ''
        _mk one 'x'
        _mk nl 'x\n'
        _mk nls 'x\n\n\n'
        _mk inner 'a\nb\n\nc\n\n'
        _mk onlynl '\n\n'
        _mk cr 'x\r\n'
        _mk odd ' sp "q" \\ \t\001\033 é \377\n'
        _mk nul 'a\000b\000\n'
        _mk nulend 'ab\000'
        _mk leadnul 'a\303\000b\000c\n'
        _mk leadnl 'x\303\n\ny\n\n'
        mkdir "$D/dir"
        _mk nulonly '\000'
        _big b8191 8191; _big b8192 8192; _big b8193 8193; _big b2m 2600000
        set -- empty one nl nls inner onlynl cr odd nul nulend leadnul leadnl nulonly b8191 b8192 b8193 b2m dir missing
        for f in "$@"; do
            N=$((N + 1))
            r="$(cat "$D/$f" 2>/dev/null)" 2>/dev/null || true
            _sandy_read_file_v "$D/$f"
            [ "$_SANDY_RF" = "$r" ] || miss "_sandy_read_file_v $f: $(q "$_SANDY_RF") != $(q "$r")"
        done
    elif [ "$GROUP" = ws ]; then
        _mk w01 '{ "schema_version": 1, "sandbox_name": "x", "workspace_path": "/ws/demo" }\n'
        _mk w02 '{"workspace_path":"/a"}'
        _mk w03 '{"workspace_path" \t:\t  "/sp ace/x"}\n'
        _mk w04 'junk\n{"other": 1}\n  "workspace_path": "/second/line",\n"workspace_path": "/third"\n'
        _mk w05 '{"workspace_path": "/esc/\\"q\\"/b"}\n'
        _mk w06 '{"workspace_path": "/a", "workspace_path": "/b"}\n'
        _mk w07 '{"workspace_path": "/a", "workspace_path" x "/b"}\n'
        _mk w08 '{"workspace_path": "workspace_path": "/c"}\n'
        _mk w09 '{"workspace_path"}\n'
        _mk w10 '{"workspace_path": /noquote}\n'
        _mk w11 '{"workspace_path": "unterminated\n'
        _mk w12 '"workspace_path":"" tail\n'
        _mk w13 '{"workspace_path": "/caf\303\251"}\n'
        _mk w14 '{"workspace_path": "/caf\351"}\n'
        _mk w15 '{"workspace_path": "/cr"}\r\n'
        _mk w16 'x"workspace_path"y\n'
        _mk w17 ''
        _mk w18 '\n\n'
        _mk w19 '{"workspace_path": "/a"} "workspace_path" : "/z" tail\n'
        _mk w20 '{"workspace_path"  :  "/t\tab"}\n'
        _mk w22 '{"a": "\303\n"}\n{"workspace_path": "/after/odd"}\n'
        mkdir "$D/w21"
        _mk w23 '{"x": "a\000b",\n "workspace_path": "/nul/before"}\n'
        _mk w24 '{"workspace_path": "/nul/after"}\n\000\n'
        { yes '{"junk": "line"}' | head -n 60000; printf '{"workspace_path": "/big/last"}\n'; } > "$D/w25"
        { _bytes 8150; printf '\n{"workspace_path": "/near/bound"}\n'; } > "$D/w26"
        set -- w01 w02 w03 w04 w05 w06 w07 w08 w09 w10 w11 w12 w13 w14 w15 w16 w17 w18 w19 w20 w21 w22 w23 w24 w25 w26 missing
        for f in "$@"; do
            N=$((N + 1))
            r="$(grep -m1 '"workspace_path"' "$D/$f" 2>/dev/null \
                 | sed 's/.*"workspace_path"[[:space:]]*:[[:space:]]*"//; s/".*//' || true)"
            _sandy_ps_ws_path "$D/$f"
            [ "$_SANDY_WSP" = "$r" ] || miss "_sandy_ps_ws_path $f: $(q "$_SANDY_WSP") != $(q "$r")"
        done
    elif [ "$GROUP" = marker ]; then
        # The marker readers as the pre-B7 loop ran them, one sed (and a tail)
        # per field, copied from 4de285e. Compared field by field with what
        # _sandy_ps_marker_read leaves in its globals.
        _ref_marker() {
            local m="$1"
            RF="$(sed -n \
                -e 's/^  "feature_entries": .*/P/p' \
                -e 's/^    "\([A-Za-z0-9._-]*\)": {"path": "\([^"]*\)"}.*/E \1 \2 new/p' \
                -e 's/^    "\([A-Za-z0-9._-]*\)": {"path": "\([^"]*\)", "relay_alias": \([a-z]*\), .*/E \1 \2 \3/p' \
                "$m" 2>/dev/null || true)"
            RFP=0; printf '%s\n' "$RF" | grep -q '^P$' && RFP=1
            RG="$(sed -n 's/.*"agents": \(\[[^]]*\]\).*/\1/p' "$m" 2>/dev/null | tail -n 1 || true)"
            RI="$(sed -n 's/^  "image": //p' "$m" 2>/dev/null | tail -n 1 || true)"
            RA="$(sed -n 's/^  "agent_args": //p' "$m" 2>/dev/null | tail -n 1 || true)"
            RB="$(sed -n 's/^  "agent_args_composed": //p' "$m" 2>/dev/null | tail -n 1 || true)"
            RW="$(sed -n 's/^  "agent_wrappers": //p' "$m" 2>/dev/null | tail -n 1 || true)"
            RL="$(sed -n 's/^  "claude_sessions": //p' "$m" 2>/dev/null | tail -n 1 || true)"
            RH=0; grep -q '^  "schema": ' "$m" 2>/dev/null && RH=1
            RV="$(sed -n 's/^  "sandy_version": "\([^"]*\)",$/\1/p' "$m" 2>/dev/null | tail -n 1 || true)"
            RT="$(sed -n 's/^  "launched_at": "\([^"]*\)",$/\1/p' "$m" 2>/dev/null | tail -n 1 || true)"
            RX="$(sed -n 's/^  "cross_session_inbound": //p' "$m" 2>/dev/null | tail -n 1 || true)"
            RY="$(sed -n 's/^  "cross_session_inbound_source": //p' "$m" 2>/dev/null | tail -n 1 || true)"
        }
        _cmp_marker() { # name
            _ref_marker "$D/$1/sandy-session.json"
            _sandy_ps_marker_read "$D/$1"
            [ "$RF" = "$_SANDY_MK_FE" ] || miss "marker $1 feature_entries: $(q "$_SANDY_MK_FE") != $(q "$RF")"
            [ "$RFP" = "$_SANDY_MK_FE_P" ] || miss "marker $1 feature_entries P: $_SANDY_MK_FE_P != $RFP"
            [ "$RG" = "$_SANDY_MK_AGENTS" ] || miss "marker $1 agents: $(q "$_SANDY_MK_AGENTS") != $(q "$RG")"
            [ "$RI" = "$_SANDY_MK_IMAGE" ] || miss "marker $1 image: $(q "$_SANDY_MK_IMAGE") != $(q "$RI")"
            [ "$RA" = "$_SANDY_MK_AA" ] || miss "marker $1 agent_args: $(q "$_SANDY_MK_AA") != $(q "$RA")"
            [ "$RB" = "$_SANDY_MK_AAC" ] || miss "marker $1 agent_args_composed: $(q "$_SANDY_MK_AAC") != $(q "$RB")"
            [ "$RW" = "$_SANDY_MK_AW" ] || miss "marker $1 agent_wrappers: $(q "$_SANDY_MK_AW") != $(q "$RW")"
            [ "$RL" = "$_SANDY_MK_CS" ] || miss "marker $1 claude_sessions: $(q "$_SANDY_MK_CS") != $(q "$RL")"
            [ "$RH" = "$_SANDY_MK_SCHEMA" ] || miss "marker $1 schema: $_SANDY_MK_SCHEMA != $RH"
            [ "$RV" = "$_SANDY_MK_VER" ] || miss "marker $1 sandy_version: $(q "$_SANDY_MK_VER") != $(q "$RV")"
            [ "$RT" = "$_SANDY_MK_AT" ] || miss "marker $1 launched_at: $(q "$_SANDY_MK_AT") != $(q "$RT")"
            [ "$RX" = "$_SANDY_MK_CSI" ] || miss "marker $1 cross_session_inbound: $(q "$_SANDY_MK_CSI") != $(q "$RX")"
            [ "$RY" = "$_SANDY_MK_CSIS" ] || miss "marker $1 cross_session_inbound_source: $(q "$_SANDY_MK_CSIS") != $(q "$RY")"
        }
        _mkm() { mkdir -p "$D/$1"; printf "$2" > "$D/$1/sandy-session.json"; }
        _full='{\n  "schema": 1,\n  "sandy_version": "2.9.0",\n  "launched_at": "2026-01-01T00:00:00Z",\n  "cross_session_inbound": "accept",\n  "cross_session_inbound_source": "explicit",\n  "agents": ["claude"],\n  "image": {"name": "sandy-full", "id": null, "project_layer": false},\n  "agent_args": {"a": 1},\n  "agent_args_composed": {"b": 2},\n  "agent_wrappers": {"c": 3},\n  "feature_entries": {\n    "f": {"path": "/opt/sandy/features/f/x"},\n    "g": {"path": "/p", "relay_alias": true, "disabled_by": null}\n  },\n  "claude_sessions": ["s"]\n}\n'
        _mkm m01 "$_full"
        _mkm m02 ''
        _mkm m03 '  "agent_args": {"x": 1}\303\n  "agent_args_composed": {"y": 2},\n  "schema": 1,\n'
        _mkm m04 '  "sandy_version": "1",\n  "sandy_version": "2",\n  "launched_at": "a",\n  "launched_at": "b",\n  "image": 1\n  "image": 2\n  "claude_sessions": 1\n  "claude_sessions": 2\n  "agent_args_composed": 1\n  "agent_args_composed": 2\n  "cross_session_inbound_source": 1\n  "cross_session_inbound_source": 2\n  "agents": [1]\n  "agents": [2]\n'
        _mkm m05 '  "agent_args": {"agents": ["a"]},\n  "image": {"agents": ["b"]}\n'
        _mkm m06 '  "sandy_version": "\377",\n  "agents": ["\377"]\n  "agent_args": {"\351": 1}\n  "launched_at": "\303\251",\n'
        _mkm m07 '  "feature_entries": {\n    "f\303\251": {"path": "/x"},\n    "ok": {"path": "/\351"}\n  },\n'
        _mkm m08 '  "agent_wrappers": {}\r\n  "claude_sessions": []'
        _mkm m09 '\000  "schema": 1,\n  "agents": ["x"]\000\n'
        { printf '{\n  "schema": 1,\n'; yes '  "agents": ["many"],' | head -n 3000; printf '  "agent_wrappers": {"w": 1}\n'; } > "$D/m10.json"
        mkdir -p "$D/m10"; mv "$D/m10.json" "$D/m10/sandy-session.json"
        mkdir -p "$D/m11/sandy-session.json"
        # An invalid lead byte straight before a NUL: in a UTF-8 locale
        # bash 5.2 read takes the NUL into the character, so a slurp in the
        # caller locale would miss it (B7 re-verify).
        _mkm m13 '{\n  "x": "\303\000  "schema": 1,\n  "sandy_version": "v",\n  "launched_at": "t",\n}\n'
        # Repeated keys through both fallbacks (a NUL; a marker over the
        # bound): the last value still wins.
        _dups='  "sandy_version": "1",\n  "sandy_version": "2",\n  "launched_at": "a",\n  "launched_at": "b",\n  "image": 1\n  "image": 2\n  "claude_sessions": 1\n  "claude_sessions": 2\n  "agent_args_composed": 1\n  "agent_args_composed": 2\n  "cross_session_inbound_source": 1\n  "cross_session_inbound_source": 2\n  "agents": [1]\n  "agents": [2]\n  "agent_wrappers": 1\n  "agent_wrappers": 2\n'
        _mkm m14 "{\\000\\n  \"schema\": 1,\\n$_dups"
        mkdir -p "$D/m15"
        { printf '{\n  "schema": 1,\n'; printf "$_dups"; yes '  "pad": "padding padding padding",' | head -n 2000; printf "$_dups" | sed 's/[12]/9&/'; } > "$D/m15/sandy-session.json"
        set -- m01 m02 m03 m04 m05 m06 m07 m08 m09 m10 m11 m13 m14 m15
        for f in "$@"; do N=$((N + 1)); _cmp_marker "$f"; done
        # The same with a stand-in for BSD sed in a UTF-8 locale: a script
        # with the unanchored .*"agents" expression stops at the first line
        # holding a \377 byte and fails; anchored scripts never scan the byte
        # and run to the end. The reference then loses only its agents field,
        # and the combined sed (which carries that expression) must be taken
        # back to the per-field reads rather than lose every later field.
        mkdir -p "$D/bin"
        UC_REALSED="$(command -v sed)"; export UC_REALSED
        cat > "$D/bin/sed" <<'SHIM'
#!/bin/sh
f=""; unanch=0
for a in "$@"; do f="$a"; case "$a" in *'.*"agents"'*) unanch=1 ;; esac; done
ff="$(printf '\377')"
if [ "$unanch" = 1 ] && LC_ALL=C grep -q "$ff" "$f" 2>/dev/null; then
    LC_ALL=C "$UC_REALSED" "/$ff/,\$d" "$f" > "$f.cut"
    n=$#; i=0
    for a in "$@"; do i=$((i + 1)); if [ "$i" -eq "$n" ]; then set -- "$@" "$f.cut"; else set -- "$@" "$a"; fi; done
    shift "$n"
    "$UC_REALSED" "$@"; rm -f "$f.cut"; exit 1
fi
exec "$UC_REALSED" "$@"
SHIM
        chmod +x "$D/bin/sed"
        PATH="$D/bin:$PATH"
        _mkm m12 '{\n  "schema": 1,\n  "agents": ["a"],\n  "x": "\377",\n  "agent_wrappers": {"after": 1},\n  "sandy_version": "9",\n}\n'
        for f in m12 m01 m06; do N=$((N + 1)); _cmp_marker "$f"; done
    else
        _mk a01 'abc123\n# workspace: /ws/one\n# approved: 2026-01-01T00:00:00Z\nKEY=V\n'
        _mk a02 'def456\nKEY=V\n'
        _mk a03 'ghi\n#  workspace:x\n# workspace:  \t /ws/two "q" \\b\n# approved:\t2026'
        _mk a04 '# workspace: /first/line\n# approved: x\n# workspace: /later\n# approved: y\n'
        _mk a05 ''
        _mk a06 '\n# approved:\n'
        _mk a07 'h\n# workspace: /caf\303\251\n# approved: \351\n'
        _mk a08 'h\r\n# workspace: /cr\r\n'
        _mk a09 'h\n# workspace:\n'
        _mk a10 'h\n # workspace: /indented\n'
        _mk a11 'h\n# workspace:/tight\t\n'
        _mk a13 'h\303\n# workspace: /w\n# approved: t\n'
        mkdir "$D/a12"
        _mk a14 'h\n# workspace: /nul\000x\n# approved: t\n'
        _mk a15 'h\n# workspace: /w1\n# workspace: /w2\n# approved: t1\n# approved: t2\n'
        { printf 'big\n'; yes KEY=VALUE | head -n 5000; printf '# workspace: /big\n# approved: late\n'; } > "$D/a16"
        set -- a01 a02 a03 a04 a05 a06 a07 a08 a09 a10 a11 a12 a13 a14 a15 a16 missing
        for f in "$@"; do
            N=$((N + 1))
            rh="$(head -n1 "$D/$f" 2>/dev/null || true)"
            rw="$(grep -m1 '^# workspace:' "$D/$f" 2>/dev/null | sed 's/^# workspace:[[:space:]]*//' || true)"
            ra="$(grep -m1 '^# approved:' "$D/$f" 2>/dev/null | sed 's/^# approved:[[:space:]]*//' || true)"
            _sandy_ps_approval_v "$D/$f"
            [ "$_SANDY_AP_HASH" = "$rh" ] || miss "_sandy_ps_approval_v $f hash: $(q "$_SANDY_AP_HASH") != $(q "$rh")"
            [ "$_SANDY_AP_WS" = "$rw" ] || miss "_sandy_ps_approval_v $f workspace: $(q "$_SANDY_AP_WS") != $(q "$rw")"
            [ "$_SANDY_AP_AT" = "$ra" ] || miss "_sandy_ps_approval_v $f approved: $(q "$_SANDY_AP_AT") != $(q "$ra")"
        done
    fi
    ;;
split)
    set -- 'a|b|c|d|e|f|g' 'a|b|c|d|e|f|g|h|i' 'a' '' '|' '||||||' 'a||c' '|lead' 'trail|' \
        'id|sandy_odd "q" \ x|img|t|false|s|u' $'tab\t|x y|  sp  |é|\xff|' 'c6ffffffffff|sandy-short'
    for l in "$@"; do
        N=$((N + 1))
        _sandy_ps_split7_v "$l"
        for i in 1 2 3 4 5 6 7; do
            r="$(echo "$l" | awk -F'|' "{print \$$i}")"
            eval "g=\$_SANDY_F$i"
            [ "$g" = "$r" ] || miss "_sandy_ps_split7_v $(q "$l") field $i: $(q "$g") != $(q "$r")"
        done
    done
    ;;
*) echo "unknown group $GROUP"; exit 2 ;;
esac
[ "$N" -gt 0 ] || { echo "no inputs ran"; exit 2; }
echo "$GROUP: $N inputs checked"
exit "$BAD"
