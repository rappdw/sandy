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
# WHY THERE IS A FALLBACK MATRIX BELOW. /v1/oauth/token answers every
# authentication failure with an opaque 401 "Authentication failed" -- verified
# directly: a syntactically valid request carrying the string "not.a.jwt" as its
# assertion returns byte-identical output to a real-but-rejected token. The
# endpoint DOES validate shape first (a bad grant_type or a malformed fdrl_ ID
# returns 400 with a specific message), so a 401 proves the payload reached
# claim verification and was refused there -- but says nothing about why.
# Two dimensions of the request are genuinely ambiguous against a rule created
# through the console, and neither is knowable without an attempt:
#   * whether workspace_id must be SENT or OMITTED for a single-workspace rule
#   * whether a blank "Expected audience" means Anthropic's default audience or
#     GitHub's default (the repo owner URL)
# Guessing costs a CI round trip per guess. So on rejection this script walks
# the small matrix, reports which combination the rule accepts, and uses it --
# loudly, so the canonical shape gets corrected rather than left wrong.
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
#   ANTHROPIC_WORKSPACE_ID -- sent when set, unless a fallback variant omits it.
#
# A diagnostic must never fail this script -- every diagnostic block below is
# wrapped so a jq/base64 hiccup while decoding claims cannot turn a working
# mint+exchange into a false failure.

_log() { printf '[ci-wif-access-token] %s\n' "$*" >&2; }
_die() {
    _log "ERROR: $1"
    # The response body is the only thing that could ever explain a failure, so
    # it must never be discarded -- the first version of this script threw it
    # away and left a 401 with nothing to go on.
    [ -n "${_RESP:-}" ] && _log "last response: $(printf '%s' "$_RESP" | head -c 400)"
    exit 1
}

[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] \
    || _die "ACTIONS_ID_TOKEN_REQUEST_URL is not set (job needs permissions: id-token: write)"
[ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] \
    || _die "ACTIONS_ID_TOKEN_REQUEST_TOKEN is not set (job needs permissions: id-token: write)"
[ -n "${ANTHROPIC_FEDERATION_RULE_ID:-}" ]   || _die "ANTHROPIC_FEDERATION_RULE_ID is not set"
[ -n "${ANTHROPIC_ORGANIZATION_ID:-}" ]      || _die "ANTHROPIC_ORGANIZATION_ID is not set"
[ -n "${ANTHROPIC_SERVICE_ACCOUNT_ID:-}" ]   || _die "ANTHROPIC_SERVICE_ACCOUNT_ID is not set"

# The audience requested from GitHub. It must MATCH the federation rule's
# "Expected audience" field, and that field has to be set EXPLICITLY: a blank
# field is an empty expected-audience list which matches nothing, not a default.
# Confirmed by an audit entry whose status.reason read `jwt_audience_mismatch`
# while the rule's audience field was blank -- every token was refused
# regardless of the aud it carried. (Read status.reason ONLY: the entry's
# `actor` block is an empty template on failure, with issuer and subject blank
# too, so its `audience: []` says nothing about the rule's configuration.)
_ANTHROPIC_AUD="https://api.anthropic.com"

# --- mint a GitHub OIDC JWT -------------------------------------------------
# $1: audience to request, or the empty string to take GitHub's default.
# --fail-with-body: curl exits 0 on an HTTP error without it, which would
# report a green mint on a failed request.
_mint_jwt() {
    local _aud="$1" _url="$ACTIONS_ID_TOKEN_REQUEST_URL" _out=""
    [ -n "$_aud" ] && _url="${_url}&audience=${_aud}"
    _out="$(curl -sS --fail-with-body \
              -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
              "$_url" | jq -r '.value')" || return 1
    [ -n "$_out" ] && [ "$_out" != "null" ] || return 1
    printf '%s' "$_out"
}

# --- decode a JWT payload for diagnostics -----------------------------------
# GNU (Linux/CI, the actual execution environment) uses `base64 -d`; BSD
# (macOS, for a maintainer running this by hand) uses `-D`. Try GNU, fall back.
_jwt_claims() {
    local _pay
    _pay="$(printf '%s' "$1" | cut -d. -f2)"
    _pay="$_pay$(printf '%*s' $(( (4 - ${#_pay} % 4) % 4 )) '' | tr ' ' '=')"
    _pay="$(printf '%s' "$_pay" | tr '_-' '/+')"
    { printf '%s' "$_pay" | base64 -d 2>/dev/null \
        || printf '%s' "$_pay" | base64 -D 2>/dev/null; } \
      | jq -c '{sub, aud, lifetime_seconds: (.exp - .iat)}' 2>/dev/null || printf '{}'
}

# --- exchange a JWT for an access token -------------------------------------
# $1 JWT, $2 include workspace_id (1|0). Sets _RESP; returns curl status.
# Built with jq -n rather than string interpolation, so the JWT and IDs never
# need hand-escaping -- and so workspace_id can be genuinely OMITTED rather
# than sent as an empty string.
_exchange() {
    local _jwt="$1" _with_ws="$2" _payload=""
    local _ws=""
    [ "$_with_ws" = "1" ] && _ws="${ANTHROPIC_WORKSPACE_ID:-}"
    _payload="$(jq -n \
        --arg grant_type "urn:ietf:params:oauth:grant-type:jwt-bearer" \
        --arg assertion "$_jwt" \
        --arg rule "$ANTHROPIC_FEDERATION_RULE_ID" \
        --arg org "$ANTHROPIC_ORGANIZATION_ID" \
        --arg svc "$ANTHROPIC_SERVICE_ACCOUNT_ID" \
        --arg ws "$_ws" \
        '{grant_type: $grant_type, assertion: $assertion,
          federation_rule_id: $rule, organization_id: $org,
          service_account_id: $svc}
         + (if $ws != "" then {workspace_id: $ws} else {} end)')"
    _RESP="$(curl -sS --fail-with-body https://api.anthropic.com/v1/oauth/token \
        -H "content-type: application/json" --data "$_payload")"
}

# --- token extraction --------------------------------------------------------
_token_from_resp() { printf '%s' "${_RESP:-}" | jq -r '.access_token // empty' 2>/dev/null || true; }

# --- attempt: mint for an audience, exchange with/without workspace_id -------
# $1 audience ("" = GitHub default), $2 include workspace_id, $3 label.
# Echoes the access token on success; returns nonzero on any failure.
_attempt() {
    local _aud="$1" _with_ws="$2" _label="$3" _jwt="" _tok="" _rc=0
    _jwt="$(_mint_jwt "$_aud")" || { _log "  $_label: JWT mint failed"; return 1; }
    _RESP=""
    _exchange "$_jwt" "$_with_ws" || _rc=$?
    if [ "$_rc" -ne 0 ]; then
        _log "  $_label: rejected -- $(printf '%s' "${_RESP:-}" | jq -rc '.error.message // "no body"' 2>/dev/null || printf 'no body') [request_id $(printf '%s' "${_RESP:-}" | jq -r '.request_id // "?"' 2>/dev/null || printf '?')]"
        return 1
    fi
    _tok="$(_token_from_resp)"
    [ -n "$_tok" ] || { _log "  $_label: 200 but no access_token in response"; return 1; }
    printf '%s' "$_tok"
}

# --- canonical attempt -------------------------------------------------------
_jwt="$(_mint_jwt "$_ANTHROPIC_AUD")" || _die "OIDC token request failed"
_log "minted at $(date -u +%H:%M:%SZ); claims: $(_jwt_claims "$_jwt")"

_RESP=""
_rc=0
_exchange "$_jwt" "1" || _rc=$?
_access_token=""
[ "$_rc" -eq 0 ] && _access_token="$(_token_from_resp)"

# --- fallback matrix ---------------------------------------------------------
# Only reached when the canonical shape is refused. Each entry re-mints, so a
# single-use assertion cannot produce a false negative on a later variant.
if [ -z "$_access_token" ]; then
    # Print the request_id for EVERY attempt. The console audit log is keyed by
    # request_id, and a run makes several attempts within the same second, so
    # without this an operator cannot tell which audit entry belongs to which
    # variant -- and the variants fail for different reasons once the rule is
    # partly correct. `// "?"` so a non-JSON body cannot break the diagnostic.
    _log "canonical exchange refused (workspace_id sent, audience $_ANTHROPIC_AUD)"
    _log "  canonical request_id: $(printf '%s' "${_RESP:-}" | jq -r '.request_id // "?"' 2>/dev/null || printf '?')"
    _log "walking the fallback matrix to identify what this rule accepts:"
    _WORKED=""
    # Newline-delimited rather than an array: an empty array expansion under
    # `set -u` is a documented bash-3.2 trap in this repo.
    while IFS='|' read -r _v_aud _v_ws _v_label; do
        [ -z "$_v_label" ] && continue
        _t="$(_attempt "$_v_aud" "$_v_ws" "$_v_label")" || continue
        _access_token="$_t"; _WORKED="$_v_label"; break
    done <<VARIANTS
$_ANTHROPIC_AUD|0|anthropic-audience, workspace_id OMITTED
|1|github-default-audience, workspace_id sent
|0|github-default-audience, workspace_id OMITTED
VARIANTS
    if [ -n "$_access_token" ]; then
        _log ""
        _log "!! The canonical exchange shape in this script is WRONG for this rule."
        _log "!! Accepted instead: $_WORKED"
        _log "!! Proceeding with that, but fix the canonical shape so the matrix"
        _log "!! stops being load-bearing (docs/CI-KEYLESS-AUTH.md)."
        _log ""
    fi
fi

if [ -z "$_access_token" ]; then
    _log "every variant was refused. The 401 body is opaque by design, so the"
    _log "next diagnostic step is the Anthropic console audit log: find this"
    _log "attempt and read its failure reason (e.g. match_claim_value_mismatch),"
    _log "then compare it against the sub printed above."
    _die "token exchange failed"
fi

# Report the ACCESS TOKEN lifetime (not the JWT's) -- this is the number the
# caller's refresh budget is actually built on.
_log "exchange ok; expires_in=$(printf '%s' "$_RESP" | jq -r '.expires_in // "unknown"' 2>/dev/null || printf 'unknown')s"

# stdout: the access token, and nothing else.
printf '%s' "$_access_token"
