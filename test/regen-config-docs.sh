#!/usr/bin/env bash
# Regenerate the config-key tables in CLAUDE.md and SPECIFICATION.md from
# `sandy --print-schema`. The schema is the single source of truth for what
# keys exist, their tier, default, and description — the metadata lives in
# the `_sandy_key_metadata` heredoc in the sandy script. Run this after
# adding, removing, or retiering a key.
#
# Usage:
#   test/regen-config-docs.sh             # rewrite blocks in place
#   test/regen-config-docs.sh --check     # exit 1 if any block would change
#                                         # (used by test/run-tests.sh)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDY="$REPO_ROOT/sandy"

MODE="write"
if [ "${1:-}" = "--check" ]; then
    MODE="check"
fi

# Capture the schema into an env var rather than piping it: python3 reads its
# source code from stdin via the heredoc, so a `cmd | python3 - <<EOF` would
# clobber the pipe (heredoc wins). Env-var pass-through keeps both channels
# free — the heredoc carries code, SANDY_SCHEMA carries data.
SANDY_SCHEMA="$("$SANDY" --print-schema)" \
MODE="$MODE" REPO_ROOT="$REPO_ROOT" \
python3 - <<'PYEOF'
import json, os, pathlib, re, sys

schema = json.loads(os.environ["SANDY_SCHEMA"])
repo = pathlib.Path(os.environ["REPO_ROOT"])
mode = os.environ["MODE"]

cfg = schema["config"]
PRIV = cfg["privileged_keys"]
PASS = cfg["passive_keys"]
ENV  = cfg["env_only_keys"]


def inline_list(keys):
    """Comma-separated backticked names, wraps naturally in markdown."""
    return ", ".join(f"`{k['name']}`" for k in keys)


def fmt_default(k):
    d = k.get("default")
    if d in (None, "", "unset"):
        return "unset"
    return f"`{d}`"


def fmt_desc(k):
    # Descriptions are single-line in the schema by construction (the
    # _sandy_key_metadata heredoc uses pipe-separated single lines). Escape
    # any literal pipe that would break the markdown table.
    return k["description"].replace("|", "\\|")


def config_table():
    rows = ["| Variable | Tier | Default | Description |",
            "|---|---|---|---|"]
    for tier_label, keys in (("privileged", PRIV),
                             ("passive",    PASS),
                             ("env-only",   ENV)):
        for k in keys:
            rows.append(
                f"| `{k['name']}` | {tier_label} | {fmt_default(k)} | {fmt_desc(k)} |"
            )
    return "\n".join(rows)


BLOCKS = {
    "privileged-key-list": inline_list(PRIV),
    "passive-key-list":    inline_list(PASS),
    "config-keys-table":   config_table(),
}

# Sentinel format:
#   <!-- BEGIN AUTOGEN:<name> ... -->
#   <generated body>
#   <!-- END AUTOGEN:<name> -->
# Everything between BEGIN and END is replaced verbatim. The BEGIN line can
# carry a free-form hint (e.g. "Run test/regen-config-docs.sh to update.")
# which is preserved by the replacement (we match-and-keep group 1).
SENTINEL_RE = lambda name: re.compile(
    r"(<!-- BEGIN AUTOGEN:" + re.escape(name) + r"(?:[^>]*)-->)"
    r"\n[\s\S]*?\n"
    r"(<!-- END AUTOGEN:" + re.escape(name) + r" -->)"
)

FILES = ["CLAUDE.md", "SPECIFICATION.md"]
drift = []
missing = []

for fn in FILES:
    path = repo / fn
    text = path.read_text()
    original = text
    for name, body in BLOCKS.items():
        pat = SENTINEL_RE(name)
        if not pat.search(text):
            # A file may only use a subset of blocks (the table only appears
            # in SPECIFICATION.md, for example). Only flag missing sentinels
            # when the user's edit clearly expected the block to be there.
            continue
        text = pat.sub(lambda m, b=body: f"{m.group(1)}\n{b}\n{m.group(2)}", text)
    if text != original:
        if mode == "check":
            drift.append(fn)
        else:
            path.write_text(text)
            print(f"[regen-config-docs] updated {fn}")
    elif mode == "write":
        print(f"[regen-config-docs] {fn} up to date")

if mode == "check" and drift:
    print(f"[regen-config-docs] DRIFT in: {', '.join(drift)}", file=sys.stderr)
    print(f"[regen-config-docs] run `test/regen-config-docs.sh` to fix", file=sys.stderr)
    sys.exit(1)
PYEOF
