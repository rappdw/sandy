#!/usr/bin/env bash
# #400 spike: does a container read a file correctly after the HOST rewrote it,
# when an EARLIER container had written that same file?
#
# Run on the macOS host (Docker Desktop or OrbStack), never inside sandy.
#
#   bash test/spike/virtiofs-host-rewrite-spike.sh [iterations]   (default 15)
#
# Each iteration mirrors one sandy relaunch of the same sandbox:
#   1. container A touches f.json the way the previous session's agent did
#   2. the host replaces f.json by write-then-rename (what sandy does since #414)
#   3. container B starts and reads f.json at 0s, 0.5s, 2s and 5s
#
# Three modes for step 1:
#   readonly  A only reads f.json (control: the guest never wrote it)
#   inplace   A rewrites f.json in place, 5 times
#   rename    A rewrites f.json via temp + rename, 5 times (Claude Code's usual path)
#   rename-nohost  as rename, but the host does NOT touch f.json in step 2;
#             B should read A's last version (tests whether step 2 is the trigger)
#   host-stage  as rename, but in step 2 the host writes a FRESH name,
#             f.json.sandy-launch.<i>, and B renames it over f.json itself
#             before reading -- the protocol sandy 2.7.0 uses (#400)
#
# Default modes: readonly rename host-stage. SPIKE_MODES picks others, e.g.
# SPIKE_MODES="inplace rename-nohost".
#
# Each read is classified:
#   ok      parses, and it is the host's version for this iteration
#   stale   parses, but it is an older version
#   BAD     does not parse (the #400 symptom)
#
# Measured 2026-10-01 on the maintainer's Mac (OrbStack), N=20: readonly 3/0/17
# BAD at 0s, rename 6 BAD at 0s, host-stage 0 -- every BAD read was fine 0.5s
# later. A prior READ is enough to arm it; the host-stage protocol is clean.
#
# Prints counts only, never file content. Leaves nothing behind.
# Takes ~5s per relaunch, so ~5 min for the three default modes at N=20;
# a progress line per relaunch goes to stderr, the table rows to stdout.
set -euo pipefail

N="${1:-20}"
IMG="${SPIKE_IMAGE:-sandy-base}"
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "image $IMG not found (set SPIKE_IMAGE to any local image with node)"; exit 1; }

# Under $HOME so it is on the same file-sharing path as ~/.sandy/sandboxes.
D="$(cd "$(mktemp -d "$HOME/.sandy-virtiofs-spike.XXXXXX")" && pwd -P)"
trap 'rm -rf "$D"' EXIT

cat > "$D/a.js" <<'JS'
const fs = require('fs');
const [i, mode] = process.argv.slice(2).map((v, k) => k === 0 ? +v : v);
const doc = (who, len) => JSON.stringify({ who, ver: i, pad: 'x'.repeat(len) }, null, 2);
JSON.parse(fs.readFileSync('/d/f.json', 'utf8'));
for (let k = 0; k < 5 && mode !== 'readonly'; k++) {
  const body = doc('guest', 50000 + ((i * 7919 + k * 104729) % 12000));
  if (mode === 'inplace') fs.writeFileSync('/d/f.json', body);
  else { fs.writeFileSync('/d/f.json.g', body); fs.renameSync('/d/f.json.g', '/d/f.json'); }
  JSON.parse(fs.readFileSync('/d/f.json', 'utf8'));
}
fs.writeFileSync('/d/next.src', doc('host', 50000 + ((i * 31337) % 12000)));
fs.writeFileSync('/d/expect', mode === 'rename-nohost' ? 'guest' : 'host');
fs.writeFileSync('/d/mode', mode);
JS

cat > "$D/b.js" <<'JS'
const fs = require('fs');
const i = +process.argv[2];
const who = fs.readFileSync('/d/expect', 'utf8');
if (fs.readFileSync('/d/mode', 'utf8') === 'host-stage') fs.renameSync('/d/f.json.sandy-launch.' + i, '/d/f.json');
const sleep = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const out = [];
let t = 0;
for (const at of [0, 500, 2000]) {
  sleep(at - t); t = at;
  let r;
  try {
    const j = JSON.parse(fs.readFileSync('/d/f.json', 'utf8'));
    r = (j.who === who && j.ver === i) ? 'ok' : 'stale';
  } catch (e) { r = 'BAD'; }
  out.push(r);
}
console.log(out.join(' '));
JS

run() {
    docker run --rm -u "$(id -u):$(id -g)" -v "$D:/d" --entrypoint node "$IMG" "$@"
}

seed() { printf '{"who":"seed","ver":-1}\n' > "$D/f.json"; }

printf '%-10s %-7s %-7s %-7s\n' mode 0s 0.5s 2s
for mode in ${SPIKE_MODES:-readonly rename host-stage}; do
    seed
    c0=""; c1=""; c2=""
    i=0
    while [ "$i" -lt "$N" ]; do
        run /d/a.js "$i" "$mode" >/dev/null
        case "$mode" in
            (rename-nohost) ;;
            (host-stage) cp "$D/next.src" "$D/f.json.sandy-launch.$i" ;;
            (*) cp "$D/next.src" "$D/f.json.h.$$" && mv -f "$D/f.json.h.$$" "$D/f.json" ;;
        esac
        set -- $(run /d/b.js "$i")
        c0="$c0 $1"; c1="$c1 $2"; c2="$c2 $3"
        printf '  %s %2d/%d: %s %s %s\n' "$mode" "$((i + 1))" "$N" "$1" "$2" "$3" >&2
        i=$((i + 1))
    done
    tally() { local ok=0 st=0 bad=0 w; for w in $1; do case "$w" in (ok) ok=$((ok+1));; (stale) st=$((st+1));; (*) bad=$((bad+1));; esac; done; printf '%s/%s/%s' "$ok" "$st" "$bad"; }
    printf '%-10s %-7s %-7s %-7s\n' "$mode" "$(tally "$c0")" "$(tally "$c1")" "$(tally "$c2")"
done
echo "(each cell: ok/stale/BAD over $N relaunches)"
