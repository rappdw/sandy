#!/usr/bin/env bash
set -euo pipefail

# test/ci-wif-access-token.sh — mint a GitHub OIDC JWT and immediately
# exchange it for a short-lived Anthropic access token (Workload Identity
# Federation, #190). Prints ONLY the access token on stdout; every diagnostic
# (decoded JWT claims, exchange expires_in) goes to stderr, so a caller doing
#     _tok="$(bash test/ci-wif-access-token.sh)"
# gets a clean value with nothing else mixed in.
#
# Why exchange eagerly, here, instead of letting the client do it lazily
# in-container: the GitHub JWT is only good for ~300s (measured), but the
# Anthropic access token this script hands back is good for ~598s -- see
# docs/CI-KEYLESS-AUTH.md "Token lifetimes -- measured, and not what the form
# implies". Exchanging once, at a known moment, is what makes that longer
# clock start where the caller expects it to.
#
# Required env:
#   ACTIONS_ID_TOKEN_REQUEST_URL, ACTIONS_ID_TOKEN_REQUEST_TOKEN
#       -- populated by GitHub Actions when the job has `permissions:
#          id-token: write`. Not set outside Actions.
#   ANTHROPIC_FEDERATION_RULE_ID, ANTHROPIC_ORGANIZATION_ID,
#   ANTHROPIC_SERVICE_ACCOUNT_ID
#       -- the federation rule's identifiers (repository variables upstream;
#          identifiers, not secrets -- a repo-scoped rule means a leaked ID
#          grants nothing).
# Optional env:
#   ANTHROPIC_WORKSPACE_ID -- only needed when the rule spans multiple
#       workspaces; omitted from the exchange payload entirely when unset,
#       rather than sent as an empty string.
#
# A diagnostic must never fail this script -- every diagnostic block below is
# wrapped so a jq/base64 hiccup while decoding claims cannot turn a working
# mint+exchange into a false failure.

_die() {
    printf '[ci-wif-access-token] ERROR: %s\n' "$1" >&2
    exit 1
}

[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] \
    || _die "ACTIONS_ID_TOKEN_REQUEST_URL is not set (job needs permissions: id-token: write)"
[ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] \
    || _die "ACTIONS_ID_TOKEN_REQUEST_TOKEN is not set (job needs permissions: id-token: write)"
[ -n "${ANTHROPIC_FEDERATION_RULE_ID:-}" ]   || _die "ANTHROPIC_FEDERATION_RULE_ID is not set"
[ -n "${ANTHROPIC_ORGANIZATION_ID:-}" ]      || _die "ANTHROPIC_ORGANIZATION_ID is not set"
[ -n "${ANTHROPIC_SERVICE_ACCOUNT_ID:-}" ]   || _die "ANTHROPIC_SERVICE_ACCOUNT_ID is not set"

# Anthropic's default audience; the console rule leaves "Expected audience"
# blank, which means exactly this value is required.
_aud="https://api.anthropic.com"

# --- Step 1: mint the GitHub OIDC JWT ---------------------------------------
# --fail-with-body: curl exits 0 on an HTTP error without it, which would
# report a green mint on a failed request. The writeout goes to stderr
# (%{stderr}) so stdout stays pure JSON for jq.
_jwt="$(curl -sS --fail-with-body -w '%{stderr}HTTP %{http_code}\n' \
          -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
          "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${_aud}" | jq -r '.value')" \
    || _die "OIDC token request failed"
[ -n "$_jwt" ] && [ "$_jwt" != "null" ] || _die "OIDC token request returned no value"

# --- Diagnostic: decode + report the JWT's own claims -----------------------
# When an exchange is rejected, the API says only "Authentication failed";
# the decoded sub is what gets diffed against the federation rule's subject
# pattern to see why. `|| true` throughout -- never fail the mint over a
# diagnostic.
{
    _pay="$(printf '%s' "$_jwt" | cut -d. -f2)"
    _pay="$_pay$(printf '%*s' $(( (4 - ${#_pay} % 4) % 4 )) '' | tr ' ' '=')"
    _pay="$(printf '%s' "$_pay" | tr '_-' '/+')"
    # GNU (Linux/CI, the actual execution environment for this script) uses
    # `base64 -d`; BSD (macOS, in case a maintainer runs this by hand) uses
    # `-D`. Try GNU first, fall back to BSD.
    _claims="$( { printf '%s' "$_pay" | base64 -d 2>/dev/null \
                    || printf '%s' "$_pay" | base64 -D 2>/dev/null; } \
                | jq -c '{sub, aud, lifetime_seconds: (.exp - .iat)}' 2>/dev/null || echo '{}')"
    printf '[ci-wif-access-token] minted at %s; claims: %s\n' \
        "$(date -u +%H:%M:%SZ)" "$_claims" >&2
} || true

# --- Step 2: exchange the JWT for an Anthropic access token -----------------
# Built with jq -n rather than string interpolation into a heredoc, so the
# JWT and IDs never need to be shell/JSON-escaped by hand -- and so
# workspace_id can be OMITTED (not sent as "") when the rule is single-workspace.
_payload="$(jq -n \
    --arg grant_type "urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --arg assertion "$_jwt" \
    --arg rule "$ANTHROPIC_FEDERATION_RULE_ID" \
    --arg org "$ANTHROPIC_ORGANIZATION_ID" \
    --arg svc "$ANTHROPIC_SERVICE_ACCOUNT_ID" \
    --arg ws "${ANTHROPIC_WORKSPACE_ID:-}" \
    '{grant_type: $grant_type, assertion: $assertion,
      federation_rule_id: $rule, organization_id: $org, service_account_id: $svc}
     + (if $ws != "" then {workspace_id: $ws} else {} end)')"

_resp="$(curl -sS --fail-with-body -w '%{stderr}HTTP %{http_code}\n' \
    https://api.anthropic.com/v1/oauth/token \
    -H "content-type: application/json" \
    --data "$_payload")" \
    || _die "token exchange failed"

_access_token="$(printf '%s' "$_resp" | jq -r '.access_token // empty' 2>/dev/null || true)"
[ -n "$_access_token" ] || _die "exchange response had no access_token"

# --- Diagnostic: report the ACCESS TOKEN's lifetime (not the JWT's) ---------
# This is the number the caller's refresh budget is actually built on.
{
    _expires_in="$(printf '%s' "$_resp" | jq -r '.expires_in // "unknown"' 2>/dev/null || echo unknown)"
    printf '[ci-wif-access-token] exchange ok; expires_in=%ss\n' "$_expires_in" >&2
} || true

# stdout: the access token, and nothing else.
printf '%s' "$_access_token"
