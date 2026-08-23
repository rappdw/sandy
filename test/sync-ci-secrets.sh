#!/usr/bin/env bash
# =============================================================================
# sync-ci-secrets.sh — push the API keys run-integration-tests.sh finds locally
# up to GitHub Actions secrets, so the Integration workflow can run keyed
# sections.
#
#   bash test/sync-ci-secrets.sh              # dry run: report only, sets nothing
#   bash test/sync-ci-secrets.sh --yes        # actually set the secrets
#   bash test/sync-ci-secrets.sh --repo o/r   # target a different repo
#
# Resolution mirrors run-integration-tests.sh EXACTLY (its lines 539-556):
# environment first, then $HOME/.sandy/.secrets as KEY=VALUE. Env wins, same as
# there, so `FOO=... bash test/sync-ci-secrets.sh` overrides the file.
#
# WHAT THIS DOES NOT SYNC, DELIBERATELY: the OAuth paths.
#
# The local banner shows `oauth` for Codex/Gemini/Claude/OpenCode because those
# are detected as FILES — ~/.codex/auth.json, ~/.gemini/oauth_creds.json,
# ~/.claude/.credentials.json, ~/.local/share/opencode/auth.json. Those are not
# synced, for three independent reasons:
#
#   1. They carry REFRESH tokens, not scoped API keys. A leaked CI secret with a
#      refresh token is a materially larger blast radius than a leaked API key,
#      and an API key can be rotated per-purpose while an OAuth session usually
#      cannot.
#   2. They expire and rotate. A copy pushed to CI goes stale on its own
#      schedule and produces confusing red runs that look like product failures.
#   3. Sandy already treats them as leak-sensitive: codex's auth.json is mounted
#      READ-ONLY specifically to stop token leakage back to the host. Pushing
#      the same file to a third-party CI inverts that posture.
#
# So CI will show `api-key` where your host shows `api-key oauth`. That is
# sufficient — each agent needs only ONE working auth path, and the keyed
# sections probe for whichever they find.
#
# Secret VALUES are never printed. Each is reported as a length plus a short
# sha256 fingerprint, which is enough to confirm the right value synced without
# putting it on a terminal, in scrollback, or in CI logs.
# =============================================================================

set -euo pipefail

DRY_RUN=true
REPO=""

while [ $# -gt 0 ]; do
    case "$1" in
        --yes)     DRY_RUN=false ;;
        --repo)    shift; REPO="${1:-}"
                   [ -z "$REPO" ] && { echo "--repo needs OWNER/NAME" >&2; exit 1; } ;;
        --repo=*)  REPO="${1#--repo=}" ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unrecognized argument: $1" >&2; exit 1 ;;
    esac
    shift
done

_c_green=""; _c_yellow=""; _c_red=""; _c_dim=""; _c_off=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _c_green=$'\033[0;32m'; _c_yellow=$'\033[0;33m'; _c_red=$'\033[0;31m'
    _c_dim=$'\033[2m'; _c_off=$'\033[0m'
fi
say()  { printf '%s\n' "$*"; }
warn() { printf '%s%s%s\n' "$_c_yellow" "$*" "$_c_off" >&2; }
die()  { printf '%s%s%s\n' "$_c_red" "$*" "$_c_off" >&2; exit 1; }

# Same sha256 fallback sandy itself uses (macOS ships shasum, Linux sha256sum).
_sha256() { shasum -a 256 2>/dev/null || sha256sum; }

# Fingerprint: length + 12 hex chars of sha256. Enough to tell "did the right
# value land" apart from "did a value land", with no recoverable material.
_fp() {
    local v="$1" n h
    n="$(printf '%s' "$v" | wc -c | tr -d ' ')"
    h="$(printf '%s' "$v" | _sha256 | awk '{print $1}' | cut -c1-12)"
    printf 'len=%s sha256=%s' "$n" "$h"
}

# --- resolve credentials exactly as run-integration-tests.sh does -------------
# Env first (already in the environment), then ~/.sandy/.secrets for anything
# still unset. Parsed as KEY=VALUE, never sourced -- the file is data, not code,
# and sandy itself treats it that way.
if [ -f "$HOME/.sandy/.secrets" ]; then
    while IFS='=' read -r _key _val; do
        _key="$(printf '%s' "$_key" | tr -d '[:space:]')"
        _val="$(printf '%s' "$_val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$_key" ] && continue
        case "$_key" in \#*) continue ;; esac
        case "$_key" in
            OPENAI_API_KEY)          [ -z "${OPENAI_API_KEY:-}" ]          && export OPENAI_API_KEY="$_val" ;;
            GEMINI_API_KEY)          [ -z "${GEMINI_API_KEY:-}" ]          && export GEMINI_API_KEY="$_val" ;;
            ANTHROPIC_API_KEY)       [ -z "${ANTHROPIC_API_KEY:-}" ]       && export ANTHROPIC_API_KEY="$_val" ;;
            CLAUDE_CODE_OAUTH_TOKEN) [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && export CLAUDE_CODE_OAUTH_TOKEN="$_val" ;;
            XAI_API_KEY)             [ -z "${XAI_API_KEY:-}" ]             && export XAI_API_KEY="$_val" ;;
        esac
    done < "$HOME/.sandy/.secrets"
fi

# Newline-delimited "NAME<TAB>required" -- no arrays, so this stays bash-3.2
# safe under set -u (an empty array expansion is a documented trap here).
# ANTHROPIC_API_KEY is marked required because it unlocks the most: every claude
# launch plus the daemon and pane-topology acceptance harnesses.
SECRETS="ANTHROPIC_API_KEY	required
OPENAI_API_KEY	optional
GEMINI_API_KEY	optional
XAI_API_KEY	optional
CLAUDE_CODE_OAUTH_TOKEN	optional"

# --- preflight ---------------------------------------------------------------
command -v gh >/dev/null 2>&1 || die "gh is not installed."
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    [ -z "$REPO" ] && die "Could not determine the repo. Pass --repo OWNER/NAME."
fi

say ""
say "Target repo: ${_c_green}${REPO}${_c_off}"
if [ "$DRY_RUN" = true ]; then
    say "Mode:        ${_c_yellow}DRY RUN${_c_off} (nothing will be set; pass --yes to apply)"
else
    say "Mode:        ${_c_red}APPLY${_c_off} — secrets will be written to GitHub"
fi
say ""

# --- report + optionally set --------------------------------------------------
_found=0; _missing=0; _set=0; _failed=0
while IFS='	' read -r _name _req; do
    [ -z "$_name" ] && continue
    eval "_val=\${$_name:-}"
    if [ -z "$_val" ]; then
        if [ "$_req" = "required" ]; then
            printf '  %s✗%s %-24s not found  %s(keyed claude sections will skip)%s\n' \
                "$_c_red" "$_c_off" "$_name" "$_c_dim" "$_c_off"
        else
            printf '  %s-%s %-24s not found  %s(its sections will skip cleanly)%s\n' \
                "$_c_dim" "$_c_off" "$_name" "$_c_dim" "$_c_off"
        fi
        _missing=$((_missing + 1))
        continue
    fi
    _found=$((_found + 1))
    printf '  %s✓%s %-24s %s\n' "$_c_green" "$_c_off" "$_name" "$(_fp "$_val")"
    [ "$DRY_RUN" = true ] && continue

    # Value goes in on STDIN, never as an argv element: argv is visible to any
    # user on the box via `ps`, and would also land in shell history.
    if printf '%s' "$_val" | gh secret set "$_name" --repo "$REPO" >/dev/null 2>&1; then
        printf '      %s-> set%s\n' "$_c_green" "$_c_off"
        _set=$((_set + 1))
    else
        printf '      %s-> FAILED%s\n' "$_c_red" "$_c_off"
        _failed=$((_failed + 1))
    fi
done <<EOF
$SECRETS
EOF

say ""
if [ "$DRY_RUN" = true ]; then
    say "${_c_dim}$_found available, $_missing missing. Re-run with --yes to set them.${_c_off}"
else
    say "Set $_set secret(s); $_failed failed; $_missing not available locally."
fi

# --- what CI will actually see ------------------------------------------------
# The point of this block: the host banner and the CI banner will NOT match, and
# that difference is expected rather than a misconfiguration. Showing it here
# means nobody has to rediscover it from a confusing CI run.
say ""
say "What the Integration workflow will detect (API keys only -- no OAuth files):"
_has() { eval "[ -n \"\${$1:-}\" ]"; }
_mark() { if "$@"; then printf '%s✓%s' "$_c_green" "$_c_off"; else printf '%s✗%s' "$_c_red" "$_c_off"; fi; }
say "  Codex:    $(_mark _has OPENAI_API_KEY)  (api-key)"
say "  Gemini:   $(_mark _has GEMINI_API_KEY)  (api-key)"
if _has ANTHROPIC_API_KEY || _has CLAUDE_CODE_OAUTH_TOKEN; then
    say "  Claude:   ${_c_green}✓${_c_off}  (api-key/oauth-token)"
else
    say "  Claude:   ${_c_red}✗${_c_off}"
fi
if _has ANTHROPIC_API_KEY || _has OPENAI_API_KEY || _has GEMINI_API_KEY; then
    say "  OpenCode: ${_c_green}✓${_c_off}  (provider keys)"
else
    say "  OpenCode: ${_c_red}✗${_c_off}"
fi
say "  Grok:     $(_mark _has XAI_API_KEY)  (api-key)"
say ""
say "${_c_dim}Your host also shows 'oauth' for several of these. Those come from files"
say "(~/.codex/auth.json and friends) and are deliberately not synced -- refresh"
say "tokens, they expire, and sandy mounts them read-only to prevent exactly this"
say "kind of copying. One working auth path per agent is enough.${_c_off}"

if [ "$DRY_RUN" = false ] && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    say ""
    warn "CLAUDE_CODE_OAUTH_TOKEN was set, but .github/workflows/integration.yml does"
    warn "not forward it yet. Add this line beside the other keys under 'env:':"
    warn "    CLAUDE_CODE_OAUTH_TOKEN: \${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}"
fi

[ "$_failed" -gt 0 ] && exit 1
exit 0
