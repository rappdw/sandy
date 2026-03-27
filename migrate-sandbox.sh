#!/usr/bin/env bash
# migrate-sandbox.sh — Migrate a sandy sandbox to the current workspace path convention.
#
# Sandy's container workspace path has changed across versions:
#   Era 1: /workspace
#   Era 2: raw host path (e.g. /home/rappdw/dev/project)
#   Era 3: $HOME-relative path (e.g. /home/claude/dev/project)
#
# Each era left behind project dirs, history entries, and .claude.json keys
# under the old path. This script consolidates them for a given sandbox.
#
# Usage: migrate-sandbox.sh <sandbox-dir> <workspace-path>
#   sandbox-dir:    path to the sandbox (e.g. ~/.sandy/sandboxes/myproject-a1b2c3d4)
#   workspace-path: current container workspace path (e.g. /home/claude/dev/project)
#
# What it does:
#   1. Merges old project dirs into the current workspace-keyed project dir
#   2. Rewrites history.jsonl project paths to the current workspace
#   3. Consolidates .claude.json project entries under the current workspace key
#
# Safe to run multiple times (idempotent). Prints what it does.

set -euo pipefail

usage() {
    echo "Usage: $0 <sandbox-dir> <workspace-path>" >&2
    echo "" >&2
    echo "  sandbox-dir:    path to the sandbox (e.g. ~/.sandy/sandboxes/myproject-a1b2c3d4)" >&2
    echo "  workspace-path: current container workspace path (e.g. /home/claude/dev/project)" >&2
    exit 1
}

[ $# -eq 2 ] || usage

SANDBOX_DIR="$(cd "$1" && pwd)"
WORKSPACE="$2"

if [ ! -d "$SANDBOX_DIR" ]; then
    echo "Error: sandbox dir does not exist: $SANDBOX_DIR" >&2
    exit 1
fi

CLAUDE_DIR="$SANDBOX_DIR/claude"  # maps to ~/.claude inside container
CLAUDE_JSON="$(dirname "$SANDBOX_DIR")/$(basename "$SANDBOX_DIR").claude.json"

info()  { printf '\033[0;36m● %s\033[0m\n' "$*"; }
warn()  { printf '\033[0;33m! %s\033[0m\n' "$*" >&2; }
ok()    { printf '\033[0;32m✓ %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Merge old project dirs
# ---------------------------------------------------------------------------
CUR_PROJ="$CLAUDE_DIR/projects/$(echo "$WORKSPACE" | tr '/' '-')"
migrated=0

if [ -d "$CLAUDE_DIR/projects" ]; then
    mkdir -p "$CUR_PROJ"
    for old_proj in "$CLAUDE_DIR/projects"/-*/; do
        [ -d "$old_proj" ] || continue
        # Normalize trailing slash for comparison
        case "$old_proj" in "$CUR_PROJ"/) continue ;; esac
        old_name="$(basename "$old_proj")"
        info "Merging project dir: $old_name"
        # cp -an: archive mode, no-clobber — merges subdirs without overwriting
        if cp -an "$old_proj". "$CUR_PROJ"/ 2>/dev/null; then
            rm -rf "$old_proj"
            migrated=$((migrated + 1))
        else
            warn "Failed to merge $old_name"
        fi
    done
fi

if [ "$migrated" -gt 0 ]; then
    ok "Merged $migrated old project dir(s) into $(basename "$CUR_PROJ")"
else
    info "No old project dirs to merge"
fi

# ---------------------------------------------------------------------------
# 2. Rewrite history.jsonl project paths
# ---------------------------------------------------------------------------
HISTORY="$CLAUDE_DIR/history.jsonl"
if [ -f "$HISTORY" ]; then
    old_count=$(grep -c '"project"' "$HISTORY" 2>/dev/null || echo 0)
    stale_count=$(grep -v "\"project\":\"$WORKSPACE\"" "$HISTORY" 2>/dev/null | grep -c '"project"' 2>/dev/null || echo 0)
    if [ "$stale_count" -gt 0 ]; then
        sed -i "s|\"project\":\"[^\"]*\"|\"project\":\"$WORKSPACE\"|g" "$HISTORY"
        ok "Rewrote $stale_count/$old_count history entries to $WORKSPACE"
    else
        info "All $old_count history entries already point to current workspace"
    fi
else
    info "No history.jsonl to migrate"
fi

# ---------------------------------------------------------------------------
# 3. Consolidate .claude.json project entries
# ---------------------------------------------------------------------------
if [ -f "$CLAUDE_JSON" ]; then
    node -e '
        const fs = require("fs");
        const f = process.argv[1];
        const ws = process.argv[2];
        let d;
        try { d = JSON.parse(fs.readFileSync(f, "utf8")); } catch(e) {
            console.log("● Cannot parse " + f + ", skipping");
            process.exit(0);
        }
        const p = d.projects;
        if (!p || typeof p !== "object") { console.log("● No project entries in .claude.json"); process.exit(0); }
        const keys = Object.keys(p).filter(k => k !== ws);
        if (keys.length === 0) { console.log("● All .claude.json entries already under current workspace"); process.exit(0); }

        let merged = p[ws] || {};
        let count = 0;
        for (const k of keys) {
            const old = p[k];
            if (!old || typeof old !== "object") { delete p[k]; count++; continue; }
            if (old.hasTrustDialogAccepted) merged.hasTrustDialogAccepted = true;
            if (old.hasCompletedProjectOnboarding) merged.hasCompletedProjectOnboarding = true;
            if (old.allowedTools && old.allowedTools.length) {
                merged.allowedTools = [...new Set([...(merged.allowedTools || []), ...old.allowedTools])];
            }
            if (!p[ws]) { merged = { ...old, ...merged }; p[ws] = merged; }
            delete p[k];
            count++;
        }
        p[ws] = merged;
        const tmp = f + ".tmp";
        fs.writeFileSync(tmp, JSON.stringify(d, null, 2) + "\n");
        fs.renameSync(tmp, f);
        console.log("\x1b[32m✓ Consolidated " + count + " stale project key(s) into " + ws + "\x1b[0m");
    ' "$CLAUDE_JSON" "$WORKSPACE"
else
    info "No .claude.json found at $CLAUDE_JSON"
fi

echo ""
ok "Migration complete for $(basename "$SANDBOX_DIR")"
