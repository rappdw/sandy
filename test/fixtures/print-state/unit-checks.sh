#!/usr/bin/env bash
# Unit checks for the no-fork readers --print-state uses (B7): each is run
# against the forking form it replaced, on a table of inputs chosen to break
# a naive version (quotes, backslashes, control bytes, CR, NUL, UTF-8,
# invalid UTF-8, missing/empty/odd files). The forking forms are the
# reference, run here with the host's own tools, so a check fails on any
# input where bash and the tools disagree.
#
# Usage: unit-checks.sh SANDY_SCRIPT GROUP   (GROUP: escape|file|ascii|ws|approval|split)
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
    "$SANDY")"
eval "$_fns"
for _f in _json_escape_v _json_escape _sandy_read_file_v _sandy_ctl_strip_v _sandy_is_ascii_print \
          _sandy_ps_ws_path _sandy_ps_approval_v _sandy_ps_split7_v; do
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
file|ws|approval)
    D="$(mktemp -d)"; D="$(cd "$D" && pwd -P)"
    trap 'rm -rf "$D"' EXIT
    _mk() { # name printf-format
        printf "$2" > "$D/$1"
    }
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
        set -- empty one nl nls inner onlynl cr odd nul nulend leadnul leadnl dir missing
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
        set -- w01 w02 w03 w04 w05 w06 w07 w08 w09 w10 w11 w12 w13 w14 w15 w16 w17 w18 w19 w20 w21 w22 missing
        for f in "$@"; do
            N=$((N + 1))
            r="$(grep -m1 '"workspace_path"' "$D/$f" 2>/dev/null \
                 | sed 's/.*"workspace_path"[[:space:]]*:[[:space:]]*"//; s/".*//' || true)"
            _sandy_ps_ws_path "$D/$f"
            [ "$_SANDY_WSP" = "$r" ] || miss "_sandy_ps_ws_path $f: $(q "$_SANDY_WSP") != $(q "$r")"
        done
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
        set -- a01 a02 a03 a04 a05 a06 a07 a08 a09 a10 a11 a12 a13 missing
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
