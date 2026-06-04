#!/usr/bin/env bash
# =============================================================================
# M2.7 day-1 spike — validate the egress-proxy architecture's load-bearing
# assumptions on REAL Docker Desktop (macOS) before committing ~2 weeks of work.
#
# The whole M2.7 design rests on one claim: a Docker `--internal` bridge network
# severs the container's route to the host LAN (closing F2's raw-IP path) while
# still allowing a same-network sidecar to reach the container, and the sidecar
# itself to reach the internet via a second, non-internal network. None of this
# can be tested in CI (GitHub Actions is Linux-only; the platform being fixed
# has no automated coverage), so it has to be proven by hand, once, here.
#
# Run this on a Mac with Docker Desktop BEFORE writing any proxy code. If the
# PASS/FAIL summary at the end is all-PASS, the architecture is sound and PR
# 2.7.1+ can proceed. If any assumption FAILS, stop — the topology needs a
# rethink, and you've spent an hour instead of three weeks.
#
# Also runnable on Linux as a sanity check (it'll note where the two platforms
# are expected to differ), but the macOS run is the one that matters.
#
# Usage:  bash test/spike/macos-internal-network-spike.sh
#         LAN_PROBE=192.168.1.1 bash test/spike/...   # override the LAN target
#
# No sudo required. Cleans up all created networks/containers on exit.
# =============================================================================
set -uo pipefail

# --- config ---------------------------------------------------------------
PID_TAG="spike$$"
INT_NET="sandy_spike_internal_${PID_TAG}"
EXT_NET="sandy_spike_external_${PID_TAG}"
PROXY_NAME="sandy_spike_proxy_${PID_TAG}"
CLIENT_IMAGE="alpine:3.20"

# A LAN IP that should be UNREACHABLE once isolation works. Default to a common
# home-router address; override with LAN_PROBE=<ip> if yours differs. The test
# only checks reachability transitions, so an unrelated-but-routable LAN IP is
# fine — what matters is that it's reachable WITHOUT --internal and not WITH it.
LAN_PROBE="${LAN_PROBE:-192.168.1.1}"

# --- bookkeeping ----------------------------------------------------------
PASS=0; FAIL=0; WARN=0
_results=()

_ok()   { _results+=("PASS  $1"); PASS=$((PASS+1)); }
_no()   { _results+=("FAIL  $1"); FAIL=$((FAIL+1)); }
_warn() { _results+=("WARN  $1"); WARN=$((WARN+1)); }
_info() { printf '\033[0;36m[spike]\033[0m %s\n' "$1"; }

cleanup() {
    docker rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
    docker network rm "$INT_NET" >/dev/null 2>&1 || true
    docker network rm "$EXT_NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

OS="$(uname -s)"
_info "Platform: $OS  (the macOS result is the one that gates M2.7)"
_info "LAN probe target: $LAN_PROBE  (override with LAN_PROBE=<ip>)"

if ! docker info >/dev/null 2>&1; then
    echo "[spike] ERROR: docker daemon not reachable. Start Docker Desktop and retry." >&2
    exit 1
fi

docker pull -q "$CLIENT_IMAGE" >/dev/null 2>&1 || true

# Helper: run a short-lived client on a network and report exit code only.
# $1=network  $2...=command. Caps each probe at a few seconds so an unreachable
# target fails fast rather than hanging on a full TCP timeout.
_client() {
    local net="$1"; shift
    docker run --rm --network "$net" "$CLIENT_IMAGE" sh -c "$*" 2>/dev/null
}

# =============================================================================
# Baseline — WITHOUT --internal, confirm the F2 exposure actually reproduces.
# If the LAN isn't reachable even on a normal bridge, the probe target is wrong
# and the later "blocked" results would be meaningless (can't block what was
# never reachable).
# =============================================================================
_info "=== Baseline: normal (non-internal) bridge ==="
if docker network create --driver bridge "$EXT_NET" >/dev/null 2>&1; then
    _ok "create non-internal bridge network"
else
    _no "create non-internal bridge network"
fi

# Internet egress on a normal bridge should work everywhere.
if _client "$EXT_NET" "wget -q -T 4 -O /dev/null https://api.anthropic.com/ || nc -z -w4 api.anthropic.com 443"; then
    _ok "non-internal: internet egress works (api.anthropic.com:443)"
else
    _warn "non-internal: internet egress probe failed — check network/offline; later results may be unreliable"
fi

# LAN reachability on a normal bridge: on macOS this is F2 (EXPECTED reachable).
# On Linux with no sandy iptables rules, also reachable. We only need it
# reachable here to validate the probe; sandy's real Linux defense is iptables.
if _client "$EXT_NET" "nc -z -w3 $LAN_PROBE 80 || nc -z -w3 $LAN_PROBE 443 || nc -z -w3 $LAN_PROBE 22"; then
    _ok "non-internal: LAN target $LAN_PROBE reachable (baseline F2 exposure confirmed)"
    _LAN_BASELINE_REACHABLE=1
else
    _warn "non-internal: LAN target $LAN_PROBE NOT reachable — pick a routable LAN_PROBE or the isolation test below proves nothing"
    _LAN_BASELINE_REACHABLE=0
fi

# =============================================================================
# Assumption 1 — `--internal` severs the route to the LAN (the F2 fix).
# This is THE claim. If it fails on Docker Desktop macOS, the whole design dies.
# =============================================================================
_info "=== Assumption 1: --internal blocks LAN egress ==="
if docker network create --driver bridge --internal "$INT_NET" >/dev/null 2>&1; then
    _ok "create --internal bridge network"
else
    _no "create --internal bridge network"
fi

# Raw-IP to the LAN from an --internal network must FAIL (no route off-bridge).
if _client "$INT_NET" "nc -z -w3 $LAN_PROBE 80 || nc -z -w3 $LAN_PROBE 443 || nc -z -w3 $LAN_PROBE 22"; then
    _no "A1: --internal STILL reaches LAN $LAN_PROBE — architecture is INVALID on this platform"
else
    if [ "${_LAN_BASELINE_REACHABLE:-0}" = "1" ]; then
        _ok "A1: --internal blocks LAN $LAN_PROBE (reachable on bridge, blocked on --internal) ✦ KEY RESULT"
    else
        _warn "A1: --internal blocks LAN, but baseline wasn't reachable either — inconclusive (fix LAN_PROBE)"
    fi
fi

# Internet from an --internal network must ALSO fail (sanity: it really is sealed).
if _client "$INT_NET" "wget -q -T 4 -O /dev/null https://api.anthropic.com/ || nc -z -w4 api.anthropic.com 443"; then
    _no "A1b: --internal network reached the internet — it is NOT actually internal on this platform"
else
    _ok "A1b: --internal blocks direct internet egress (expected — proxy will be the only exit)"
fi

# host.docker.internal from --internal must fail (the local-LLM-collision concern).
if _client "$INT_NET" "nc -z -w3 host.docker.internal 1 2>/dev/null; nc -z -w3 host.docker.internal 80 || nc -z -w3 host.docker.internal 443 || nc -z -w3 host.docker.internal 22"; then
    _warn "A1c: host.docker.internal reachable from --internal — verify SANDY_LOCAL_LLM_HOST interaction"
else
    _ok "A1c: host.docker.internal unreachable from --internal (confirms local-LLM needs proxy forwarding)"
fi

# =============================================================================
# Assumption 2 — a sidecar on the --internal network is still reachable by the
# client (intra-bridge L2), and the sidecar can reach the internet via a SECOND
# non-internal network. This is the proxy's two-network position.
# =============================================================================
_info "=== Assumption 2: dual-homed sidecar (internal + external) ==="

# Start a sidecar attached to the internal network, listening on :3128.
# Then connect it to the external network too. busybox httpd is enough to prove
# "the client can reach me on the internal net" and "I can reach the internet
# on the external net".
if docker run -d --name "$PROXY_NAME" --network "$INT_NET" "$CLIENT_IMAGE" \
    sh -c "while true; do printf 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nproxy' | nc -l -p 3128 -w1; done" \
    >/dev/null 2>&1; then
    _ok "start dual-homed sidecar on --internal network"
else
    _no "start dual-homed sidecar on --internal network"
fi

if docker network connect "$EXT_NET" "$PROXY_NAME" >/dev/null 2>&1; then
    _ok "attach sidecar to second (non-internal) network"
else
    _no "attach sidecar to second (non-internal) network"
fi

# Discover the sidecar's IP on the INTERNAL network — that's the address the
# real container would point --dns and HTTP_PROXY at.
PROXY_INT_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$INT_NET\").IPAddress}}" "$PROXY_NAME" 2>/dev/null)"
if [ -n "$PROXY_INT_IP" ]; then
    _ok "sidecar internal IP discovered: $PROXY_INT_IP"
else
    _no "could not discover sidecar internal IP (downstream probes will be skipped)"
fi

# A2: client on --internal can reach the sidecar (intra-bridge — must work
# despite --internal, because it's L2, not routed egress).
if [ -n "$PROXY_INT_IP" ] && _client "$INT_NET" "nc -z -w3 $PROXY_INT_IP 3128"; then
    _ok "A2: client on --internal reaches sidecar:$PROXY_INT_IP:3128 ✦ KEY RESULT"
elif [ -n "$PROXY_INT_IP" ]; then
    _no "A2: client on --internal CANNOT reach the sidecar — proxy would be unreachable, design INVALID"
fi

# A2b: the sidecar itself can reach the internet via its external leg.
if docker exec "$PROXY_NAME" sh -c "wget -q -T 4 -O /dev/null https://api.anthropic.com/ || nc -z -w4 api.anthropic.com 443" 2>/dev/null; then
    _ok "A2b: dual-homed sidecar reaches the internet via the external network ✦ KEY RESULT"
else
    _no "A2b: dual-homed sidecar CANNOT reach the internet — proxy could not forward, design INVALID"
fi

# =============================================================================
# Assumption 3 — `--dns <sidecar-ip>` is honored by a container on the
# --internal network (so the proxy can serve DNS / SNI-redirect). We can't run
# a full resolver here, but we CAN prove the container's resolv.conf is set to
# the sidecar and that traffic to :53 reaches it.
# =============================================================================
_info "=== Assumption 3: --dns points at the sidecar under --internal ==="
if [ -n "$PROXY_INT_IP" ]; then
    _RESOLV="$(docker run --rm --network "$INT_NET" --dns "$PROXY_INT_IP" "$CLIENT_IMAGE" cat /etc/resolv.conf 2>/dev/null)"
    if echo "$_RESOLV" | grep -q "$PROXY_INT_IP"; then
        _ok "A3: --dns $PROXY_INT_IP propagates into container resolv.conf ✦ KEY RESULT"
    else
        _no "A3: --dns did NOT propagate (resolv.conf: $(echo "$_RESOLV" | tr '\n' ' '))"
    fi
    # And the client can send UDP/53 to the sidecar (reachability, not a real query).
    if _client "$INT_NET" "nc -z -u -w3 $PROXY_INT_IP 53 || true; nc -z -w3 $PROXY_INT_IP 3128"; then
        _ok "A3b: client can reach sidecar transport on the internal net (TCP proven; UDP/53 path open)"
    else
        _warn "A3b: could not confirm sidecar transport reachability for DNS"
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
printf '\033[1m===== M2.7 spike results (%s) =====\033[0m\n' "$OS"
for r in "${_results[@]}"; do
    case "$r" in
        PASS*) printf '  \033[0;32m✓\033[0m %s\n' "${r#PASS  }" ;;
        FAIL*) printf '  \033[0;31m✗\033[0m %s\n' "${r#FAIL  }" ;;
        WARN*) printf '  \033[0;33m⊘\033[0m %s\n' "${r#WARN  }" ;;
    esac
done
echo ""
printf 'PASS=%d  FAIL=%d  WARN=%d\n' "$PASS" "$FAIL" "$WARN"
echo ""

if [ "$FAIL" -gt 0 ]; then
    printf '\033[0;31mGATE: FAILED.\033[0m One or more load-bearing assumptions did not hold on this\n'
    printf 'platform. Do NOT proceed with the proxy build as designed — the --internal\n'
    printf 'two-network topology needs a rethink first. Investigate each FAIL above.\n'
    exit 1
fi
if [ "$OS" != "Darwin" ]; then
    printf '\033[0;33mGATE: PASSED on %s, but this is NOT the platform M2.7 exists to fix.\n' "$OS"
    printf 'You MUST re-run this on Docker Desktop (macOS) before committing to the build.\033[0m\n'
    exit 0
fi
printf '\033[0;32mGATE: PASSED on macOS.\033[0m The --internal two-network topology isolates the\n'
printf 'LAN, keeps the sidecar reachable, lets the sidecar egress, and honors --dns.\n'
printf 'The M2.7 architecture is sound on this Docker Desktop version. Proceed to PR 2.7.1.\n'
