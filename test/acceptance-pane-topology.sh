#!/usr/bin/env bash
# End-to-end multi-agent pane-topology acceptance (#22) — proves the tmux
# session `sandy --start` creates for a multi-agent combo actually forms the
# documented split-pane layout (dual / left+2-right / 2x2 grid) AND that each
# configured agent is genuinely running in its documented on-screen position.
#
# ⚠️ RUN ON A HOST WITH DOCKER. This cannot run inside sandy (no Docker), and
# note that running tmux/`sandy --start` from INSIDE a sandy session collides
# with the live tmux server that hosts it — always run this on the host. It
# needs the agent images already built (sandy-full for 3-4 agent combos, the
# per-agent images for 2-agent combos) — run a normal `sandy` launch once
# first if they aren't built yet.
#
# HOST-CONFIRM ON FIRST RUN (both fail CLOSED — a wrong assumption false-FAILS
# an assertion, it never false-passes to hide a topology regression):
#   1. capture-pane vs alt-screen. Identity relies on `capture-pane -p` seeing
#      the pre-agent `[sandy:pane-agent]` marker in the pane's normal-screen
#      scrollback. Agents run WITHOUT creds here, so they exit to the main
#      screen (`<agent>; read -p ''`) where the marker is unambiguously present.
#      If a maintainer runs a credentialed agent that stays on the tmux ALT
#      screen, the default capture may miss the marker → identity false-fail.
#      Confirm identity assertions pass on the first host run; if not, force a
#      normal-buffer capture or add a pane_title cross-check.
#   2. Detached 4-pane fit. `new-session -d` with no attached client defaults to
#      80x24; the 2x2 `all` grid fits, but confirm the `all` combo yields 4
#      panes (a too-small session would drop a pane → count false-fail).
#
#   Usage:  bash test/acceptance-pane-topology.sh          # uses ./sandy
#           SANDY=/path/to/sandy bash test/acceptance-pane-topology.sh
#           SANDY_TEST_COMBOS="claude,gemini claude,codex" bash test/acceptance-pane-topology.sh
#
# Verification strategy: sandy launches each pane's command with
# SANDY_TEST_PANE_TAGS=1, which prepends a `printf '[sandy:pane-agent] <name>'`
# marker ahead of the real agent command in each pane (see the sandy script's
# multi-agent branch, ~3759-3786). A plain-text stdout marker sitting in tmux
# scrollback can't be clobbered by an agent TUI emitting its own OSC-2 title
# sequence the way `select-pane -T` / pane_title could be raced. `capture-pane
# -p` + grep reads it back.
#
# NOTE ON PANE INDEXING — read before "fixing" a failing assertion here. This
# harness deliberately does NOT assume tmux's `pane_index` equals spawn order.
# This is documented tmux behavior for the split sequence the sandy script uses
# (new-session, split -h, split -v -t sandy.1, split -v -t sandy.0 — do NOT
# reproduce it with tmux inside a sandy session; that collides with the live
# tmux server): pane_index does NOT track spawn order once a later split
# re-splits an EARLIER pane. In the 4-agent 2x2 grid, `sandy.0` does hold agent[0] as
# expected, but `sandy.1` ends up holding agent[3]'s content (bottom-left),
# `sandy.2` holds agent[1] (top-right), and `sandy.3` holds agent[2]
# (bottom-right) — tmux inserts a new pane's index immediately after the pane
# it split, not appended at the end of the index sequence. The documented
# CONTRACT (CLAUDE.md / docs/TESTING_PLAN.md) is about ON-SCREEN POSITION
# ("Claude top-left, Gemini top-right, Codex bottom-right, OpenCode
# bottom-left"), not raw pane_index, so this harness derives each pane's
# GEOMETRIC ROLE from its actual left/top coordinates and checks agent
# identity against that role — robust to the indexing quirk, and testing the
# real promise made to users rather than an incidental index coincidence that
# only happens to hold for the 2- and 3-pane layouts. If a maintainer also
# wants pane_index itself to track spawn order (relevant to
# SANDY_CHANNEL_TARGET_PANE, which selects a pane by raw index), that is a
# separate concern from this issue's "does the topology look right" scope.
set -uo pipefail

SANDY="${SANDY:-./sandy}"
PASS=0; FAIL=0
ck() { if eval "$2" >/dev/null 2>&1; then printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1));
       else printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); fi; }

# Default combos exercise dual-pane, left+2-right (triple), and the 2x2 grid
# (all four agents). Override with SANDY_TEST_COMBOS to iterate on just one —
# combos are separated by WHITESPACE; each combo's own agent list uses commas
# (e.g. SANDY_TEST_COMBOS="claude,gemini claude,codex" runs just those two).
DEFAULT_COMBOS="claude,gemini claude,codex claude,gemini,codex all"
COMBOS="${SANDY_TEST_COMBOS:-$DEFAULT_COMBOS}"

WSTMP="$(mktemp -d)"
WSBASE="$WSTMP/pane-topo-accept-$$"
mkdir -p "$WSBASE"
WS=""   # current in-flight workspace; the trap reads this so an abrupt abort
        # mid-combo still tears down whatever's currently up.
cleanup() {
    [ -n "$WS" ] && "$SANDY" --stop --workspace "$WS" >/dev/null 2>&1
    rm -rf "$WSTMP"   # the whole mktemp tree, not just the subdir under it
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || { echo "docker not found — run this on the host"; exit 2; }

# --- small arithmetic helpers (bash 3.2 safe — no [[ -k ]] / no arrays here) ---
_abs_diff() { local d=$(( $1 - $2 )); echo "${d#-}"; }
_close() { # _close a b [tol=1]
    local tol="${3:-1}" d
    d="$(_abs_diff "$1" "$2")"
    [ "$d" -le "$tol" ]
}

for combo in $COMBOS; do
    echo ""
    echo "== combo: $combo =="

    # Fresh scratch workspace per combo, canonicalized like sandy does
    # (pwd -P) — see acceptance-daemon.sh's note on macOS /var -> /private/var.
    WS="$WSBASE/$(printf '%s' "$combo" | tr ',' '-')"
    mkdir -p "$WS" && (cd "$WS" && git init -q)
    WS="$(cd "$WS" && pwd -P)"

    # Expand the "all" alias the same way sandy does (sandy:5333), to build
    # the expected per-role agent list for the identity checks.
    if [ "$combo" = "all" ]; then
        expanded="claude,gemini,codex,opencode"
    else
        expanded="$combo"
    fi
    IFS=',' read -ra AGENTS <<< "$expanded"
    ARITY="${#AGENTS[@]}"

    # Per-combo retry (anti-flake): a Docker-runtime harness under full-suite
    # load can hit a transient container/pane startup race that no single settle
    # window covers. Run the combo; if it logs any NEW failure, discard this
    # attempt's tally and re-run the combo once. A GENUINE failure recurs on the
    # retry (fails both attempts) and is still reported — only transient flake is
    # absorbed. Bounded to 2 attempts. (Body left at its original indent — bash
    # ignores it — to keep this a minimal, reviewable wrap.)
    _combo_attempt=1
    while : ; do
    _snap_pass=$PASS; _snap_fail=$FAIL

    SANDY_AGENT="$combo" SANDY_TEST_PANE_TAGS=1 "$SANDY" --start --workspace "$WS"; RC=$?
    ck "[$combo] --start exits 0" "[ $RC -eq 0 ]"

    C="$(docker ps -q --filter label=sandy.daemon=true --filter "label=sandy.workspace_path=$WS" 2>/dev/null | head -1)"
    ck "[$combo] daemon container is running" "[ -n \"$C\" ]"
    ck "[$combo] inner tmux session exists" "docker exec -u \"$(id -u)\" \"$C\" tmux has-session -t sandy"

    # Cheap defense-in-depth: pane commands already never exit by construction
    # (every build_*_cmd is wrapped by _sandy_wrap_cmd_exit_pause, which joins
    # a trailing `read -p ''` with `;` so the pane's shell blocks forever even
    # if the agent itself exits on bad/absent creds) — this is belt-and-
    # suspenders for the odd case where the whole `bash -c` wrapper fails to
    # even start.
    docker exec -u "$(id -u)" "$C" tmux set-option -t sandy remain-on-exit on >/dev/null 2>&1
    ck "[$combo] remain-on-exit set (defense-in-depth)" \
        "docker exec -u \"$(id -u)\" \"$C\" tmux show-options -t sandy remain-on-exit | grep -q on\$"

    # Settle gate (anti-flake): `--start`'s readiness only waits for
    # `tmux has-session`, but the panes are created by the entrypoint
    # sequentially and each pane's bash prints its `[sandy:pane-agent]` marker
    # before exec'ing the agent. Inspecting immediately can race a late-split
    # pane (esp. the 4-agent grid) or a not-yet-rendered marker, producing an
    # intermittent identity/count failure that passes on re-run. Poll until all
    # ARITY panes exist AND every one has rendered its marker (bounded ~15s), so
    # geometry + identity below read a settled session.
    _settle=0
    while [ "$_settle" -lt 30 ]; do
        _pc="$(docker exec -u "$(id -u)" "$C" tmux list-panes -t sandy:0 -F x 2>/dev/null | grep -c x || true)"
        if [ "${_pc:-0}" -eq "$ARITY" ]; then
            _allmark=1
            for _pidx in $(docker exec -u "$(id -u)" "$C" tmux list-panes -t sandy:0 -F '#{pane_index}' 2>/dev/null); do
                docker exec -u "$(id -u)" "$C" tmux capture-pane -p -t "sandy.$_pidx" -S - 2>/dev/null \
                    | grep -q '\[sandy:pane-agent\]' || { _allmark=0; break; }
            done
            [ "$_allmark" -eq 1 ] && break
        fi
        sleep 0.5
        _settle=$((_settle + 1))
    done

    PANES_RAW="$(docker exec -u "$(id -u)" "$C" tmux list-panes -t sandy:0 -F '#{pane_index} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{pane_dead}' 2>/dev/null)"

    IDX=(); LEFT=(); TOP=(); WIDTH=(); HEIGHT=(); DEAD=()
    while read -r p_idx p_left p_top p_width p_height p_dead; do
        [ -z "$p_idx" ] && continue
        IDX+=("$p_idx"); LEFT+=("$p_left"); TOP+=("$p_top"); WIDTH+=("$p_width"); HEIGHT+=("$p_height"); DEAD+=("$p_dead")
    done <<PANES
$PANES_RAW
PANES

    N="${#IDX[@]}"
    ck "[$combo] pane count == arity ($ARITY)" "[ $N -eq $ARITY ]"

    alldead=""
    for d in ${DEAD[@]+"${DEAD[@]}"}; do
        [ "$d" = "1" ] && alldead="yes"
    done
    ck "[$combo] no pane reports dead (#{pane_dead})" "[ -z \"$alldead\" ]"

    # Marker capture per actual tmux pane index (NOT assumed == local array
    # position, though they happen to coincide since we just enumerated them
    # in list-panes' own order).
    MARK=()
    i=0
    while [ "$i" -lt "$N" ]; do
        pidx="${IDX[$i]}"
        content="$(docker exec -u "$(id -u)" "$C" tmux capture-pane -p -t "sandy.$pidx" -S - 2>/dev/null)"
        agent="$(printf '%s\n' "$content" | grep -oE '\[sandy:pane-agent\] [a-zA-Z0-9_-]+' | head -1 | awk '{print $2}')"
        MARK+=("$agent")
        i=$((i + 1))
    done

    case "$N" in
    2)
        li=0; ri=1
        if [ "${LEFT[0]}" -gt "${LEFT[1]}" ]; then li=1; ri=0; fi
        ck "[$combo] left pane starts at column 0" "[ ${LEFT[$li]} -eq 0 ]"
        ck "[$combo] right pane starts right of the left pane's edge" \
            "[ ${LEFT[$ri]} -gt $(( ${LEFT[$li]} + ${WIDTH[$li]} )) ]"
        ck "[$combo] panes share the same top row" "[ ${TOP[$li]} -eq ${TOP[$ri]} ]"
        ck "[$combo] panes are equal height" "[ ${HEIGHT[$li]} -eq ${HEIGHT[$ri]} ]"
        ck "[$combo] panes are equal width (±1, divider column)" "_close ${WIDTH[$li]} ${WIDTH[$ri]} 1"
        ck "[$combo] left pane is agent[0]=${AGENTS[0]}" "[ \"${MARK[$li]}\" = \"${AGENTS[0]}\" ]"
        ck "[$combo] right pane is agent[1]=${AGENTS[1]}" "[ \"${MARK[$ri]}\" = \"${AGENTS[1]}\" ]"
        ;;
    3)
        li=0
        [ "${LEFT[1]}" -lt "${LEFT[$li]}" ] && li=1
        [ "${LEFT[2]}" -lt "${LEFT[$li]}" ] && li=2
        others=()
        for k in 0 1 2; do [ "$k" != "$li" ] && others+=("$k"); done
        a="${others[0]}"; b="${others[1]}"
        tri="$a"; bri="$b"
        if [ "${TOP[$b]}" -lt "${TOP[$a]}" ]; then tri="$b"; bri="$a"; fi

        ck "[$combo] left pane starts at column 0" "[ ${LEFT[$li]} -eq 0 ]"
        ck "[$combo] right-column panes share the same left, right of the left pane" \
            "[ ${LEFT[$tri]} -eq ${LEFT[$bri]} ] && [ ${LEFT[$tri]} -gt $(( ${LEFT[$li]} + ${WIDTH[$li]} )) ]"
        ck "[$combo] top-right pane starts at the top row (same top as left pane)" \
            "[ ${TOP[$tri]} -eq ${TOP[$li]} ]"
        ck "[$combo] bottom-right pane starts below the top-right pane" \
            "[ ${TOP[$bri]} -gt $(( ${TOP[$tri]} + ${HEIGHT[$tri]} )) ]"
        ck "[$combo] top-right/bottom-right panes are equal height (±1)" \
            "_close ${HEIGHT[$tri]} ${HEIGHT[$bri]} 1"
        ck "[$combo] top-right/bottom-right panes are equal width" \
            "[ ${WIDTH[$tri]} -eq ${WIDTH[$bri]} ]"
        ck "[$combo] left pane is agent[0]=${AGENTS[0]}" "[ \"${MARK[$li]}\" = \"${AGENTS[0]}\" ]"
        ck "[$combo] top-right pane is agent[1]=${AGENTS[1]}" "[ \"${MARK[$tri]}\" = \"${AGENTS[1]}\" ]"
        ck "[$combo] bottom-right pane is agent[2]=${AGENTS[2]}" "[ \"${MARK[$bri]}\" = \"${AGENTS[2]}\" ]"
        ;;
    4)
        minleft="${LEFT[0]}"
        for k in 1 2 3; do [ "${LEFT[$k]}" -lt "$minleft" ] && minleft="${LEFT[$k]}"; done
        leftcol=(); rightcol=()
        for k in 0 1 2 3; do
            if [ "${LEFT[$k]}" -eq "$minleft" ]; then leftcol+=("$k"); else rightcol+=("$k"); fi
        done
        ck "[$combo] exactly two panes in the left column, two in the right" \
            "[ ${#leftcol[@]} -eq 2 ] && [ ${#rightcol[@]} -eq 2 ]"

        tl="${leftcol[0]:-0}"; bl="${leftcol[1]:-0}"
        if [ "${#leftcol[@]}" -eq 2 ] && [ "${TOP[${leftcol[1]}]}" -lt "${TOP[${leftcol[0]}]}" ]; then
            tl="${leftcol[1]}"; bl="${leftcol[0]}"
        fi
        tr="${rightcol[0]:-0}"; br="${rightcol[1]:-0}"
        if [ "${#rightcol[@]}" -eq 2 ] && [ "${TOP[${rightcol[1]}]}" -lt "${TOP[${rightcol[0]}]}" ]; then
            tr="${rightcol[1]}"; br="${rightcol[0]}"
        fi

        ck "[$combo] top-left pane starts at column 0" "[ ${LEFT[$tl]} -eq 0 ]"
        ck "[$combo] bottom-left pane shares the left column" "[ ${LEFT[$bl]} -eq ${LEFT[$tl]} ]"
        ck "[$combo] right-column panes start right of the left column" \
            "[ ${LEFT[$tr]} -eq ${LEFT[$br]} ] && [ ${LEFT[$tr]} -gt $(( ${LEFT[$tl]} + ${WIDTH[$tl]} )) ]"
        ck "[$combo] top row panes share the same top" "[ ${TOP[$tl]} -eq ${TOP[$tr]} ]"
        ck "[$combo] bottom row panes share the same top, below the top row" \
            "[ ${TOP[$bl]} -eq ${TOP[$br]} ] && [ ${TOP[$bl]} -gt $(( ${TOP[$tl]} + ${HEIGHT[$tl]} )) ]"
        ck "[$combo] left/right column widths match (±1, divider column)" \
            "_close ${WIDTH[$tl]} ${WIDTH[$tr]} 1"
        ck "[$combo] top-left/bottom-left panes are equal width" "[ ${WIDTH[$tl]} -eq ${WIDTH[$bl]} ]"
        ck "[$combo] top-right/bottom-right panes are equal width" "[ ${WIDTH[$tr]} -eq ${WIDTH[$br]} ]"
        ck "[$combo] top row heights match (±1)" "_close ${HEIGHT[$tl]} ${HEIGHT[$tr]} 1"
        ck "[$combo] bottom row heights match (±1)" "_close ${HEIGHT[$bl]} ${HEIGHT[$br]} 1"

        ck "[$combo] top-left pane is agent[0]=${AGENTS[0]}" "[ \"${MARK[$tl]}\" = \"${AGENTS[0]}\" ]"
        ck "[$combo] top-right pane is agent[1]=${AGENTS[1]}" "[ \"${MARK[$tr]}\" = \"${AGENTS[1]}\" ]"
        ck "[$combo] bottom-right pane is agent[2]=${AGENTS[2]}" "[ \"${MARK[$br]}\" = \"${AGENTS[2]}\" ]"
        ck "[$combo] bottom-left pane is agent[3]=${AGENTS[3]}" "[ \"${MARK[$bl]}\" = \"${AGENTS[3]}\" ]"
        ;;
    *)
        ck "[$combo] unsupported pane count $N (harness only knows 2/3/4)" "false"
        ;;
    esac

    "$SANDY" --stop --workspace "$WS" >/dev/null 2>&1; ck "[$combo] --stop exits 0" "[ $? -eq 0 ]"

    # Retry decision: clean attempt, or out of attempts → keep this tally.
    if [ "$FAIL" -eq "$_snap_fail" ] || [ "$_combo_attempt" -ge 2 ]; then
        break
    fi
    # Transient failure with a retry left: discard this attempt's tally
    # (PASS/FAIL and the printed lines were attempt 1's) and re-run once.
    printf '  \033[33mRETRY\033[0m [%s] %d transient failure(s) — re-running combo once\n' "$combo" "$(( FAIL - _snap_fail ))"
    PASS=$_snap_pass; FAIL=$_snap_fail
    sleep 2
    _combo_attempt=$(( _combo_attempt + 1 ))
    done

    WS=""   # stopped — clear so the EXIT trap doesn't try to stop it again
done

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ]
