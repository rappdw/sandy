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
#
# Each read is classified:
#   ok      parses, and it is the host's version for this iteration
#   stale   parses, but it is an older version
#   BAD     does not parse (the #400 symptom)
#
# Prints counts only, never file content. Leaves nothing behind.
# Takes ~10s per relaunch (the reader alone waits 7.5s), so ~8 min at N=15;
# a progress line per relaunch goes to stderr, the table rows to stdout.
set -euo pipefail

N="${1:-15}"
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
JS

cat > "$D/b.js" <<'JS'
const fs = require('fs');
const i = +process.argv[2];
const sleep = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const out = [];
let t = 0;
for (const at of [0, 500, 2000, 5000]) {
  sleep(at - t); t = at;
  let r;
  try {
    const j = JSON.parse(fs.readFileSync('/d/f.json', 'utf8'));
    r = (j.who === 'host' && j.ver === i) ? 'ok' : 'stale';
  } catch (e) { r = 'BAD'; }
  out.push(r);
}
console.log(out.join(' '));
JS

run() {
    docker run --rm -u "$(id -u):$(id -g)" -v "$D:/d" --entrypoint node "$IMG" "$@"
}

seed() { printf '{"who":"seed","ver":-1}\n' > "$D/f.json"; }

printf '%-9s %-6s %-6s %-6s %-6s\n' mode 0s 0.5s 2s 5s
for mode in readonly inplace rename; do
    seed
    c0=""; c1=""; c2=""; c3=""
    i=0
    while [ "$i" -lt "$N" ]; do
        run /d/a.js "$i" "$mode" >/dev/null
        cp "$D/next.src" "$D/f.json.h.$$" && mv -f "$D/f.json.h.$$" "$D/f.json"
        set -- $(run /d/b.js "$i")
        c0="$c0 $1"; c1="$c1 $2"; c2="$c2 $3"; c3="$c3 $4"
        printf '  %s %2d/%d: %s %s %s %s\n' "$mode" "$((i + 1))" "$N" "$1" "$2" "$3" "$4" >&2
        i=$((i + 1))
    done
    tally() { local ok=0 st=0 bad=0 w; for w in $1; do case "$w" in (ok) ok=$((ok+1));; (stale) st=$((st+1));; (*) bad=$((bad+1));; esac; done; printf '%s/%s/%s' "$ok" "$st" "$bad"; }
    printf '%-9s %-6s %-6s %-6s %-6s\n' "$mode" "$(tally "$c0")" "$(tally "$c1")" "$(tally "$c2")" "$(tally "$c3")"
done
echo "(each cell: ok/stale/BAD over $N relaunches)"
