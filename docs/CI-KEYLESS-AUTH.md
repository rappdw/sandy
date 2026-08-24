# Keyless CI auth (workload identity federation)

How to let the `Integration` workflow authenticate to model providers using GitHub's OIDC token instead of long-lived API keys stored as repository secrets.

**Scope: GitHub CI only.** Local development is unchanged — keep using API keys and OAuth exactly as today (`~/.sandy/.secrets`, host credential files, [`CI-CREDENTIALS.md`](CI-CREDENTIALS.md)). Nothing in `sandy` itself changes.

> Provider consoles drift. The durable part of each section is the **shape** — register GitHub as a trusted issuer, scope a rule to this repository, exchange the OIDC token for short-lived access. Treat click-paths as hints.

---

## Why

A federated token is short-lived and claim-scoped, so there is **no standing credential in GitHub to leak or rotate**. It retires the largest residual in `CI-CREDENTIALS.md`: *"anyone who can push to `main` or dispatch a workflow can exfiltrate these secrets"* becomes *"…can obtain a short-lived token scoped to this repo."* The identifiers that remain are repository **variables**, not secrets.

---

## Provider support — checked August 2026

| Provider | Keyless from GitHub Actions? | Path |
|---|---|---|
| **Anthropic** | **Yes** — WIF, GA | Register the GitHub issuer, map a rule → 4 env vars. Claude Code CLI supports it (verified: all six contract env vars ship in the binary) |
| **OpenAI** | **Yes** | Same shape — a service-account mapping under a Workload Identity Provider; the SDK fetches the GitHub OIDC token and exchanges it |
| **Google** | **Yes, but only via Vertex AI** | The Gemini API (AI Studio) accepts **only API keys**. Vertex AI accepts WIF tokens natively. Sandy already supports this — see below |
| **xAI (Grok)** | **No, not for CI** | `GROK_OIDC_ISSUER`/`GROK_OIDC_CLIENT_ID` exist but use **PKCE** — an interactive browser flow for enterprise SSO, not machine-to-machine. Keep `XAI_API_KEY` |

So three of four can go keyless. `XAI_API_KEY` stays a secret; that section skips cleanly if you drop it entirely.

---

## 1. Anthropic

Tracked in [#190](https://github.com/rappdw/sandy/issues/190). Patch drafted at `0002-wif-integration.patch`.

**Console** (<https://platform.claude.com/settings/workload-identity-federation>) — three objects: a **service account**, an **issuer**, and a **rule**.

> **Use the guided flow if you can.** Settings → Workload identity → **Connect workload** → the **GitHub Actions** tile walks all three at once. The field-by-field tables below are for doing it manually, or for checking what the wizard produced.

### Step 0 — Service account

A service account (`svac_…`) is an **organization-level**, non-human identity — no email, no password, no console login. It is the principal a federated token acts as.

> **It only becomes active in a workspace once you add it as a member of that workspace.** Creating it is not enough. Because the rule below is scoped to a single workspace rather than "all workspaces", the service account must be a **member of that same workspace** — otherwise the rule mints tokens for a principal that cannot act where they are scoped, which presents as *successful auth followed by permission errors*, not as an auth failure.

Then the two steps below: register the issuer ("we trust GitHub"), then create a rule ("…and specifically this repo").

### Step 1 — Register issuer

| Field | Value | Why |
|---|---|---|
| Name | `github-ci` | shown in rules and audit logs |
| Issuer URL (`iss`) | `https://token.actions.githubusercontent.com` | correct for github.com. GitHub **Enterprise Server** appends an enterprise slug |
| JWKS source | OIDC discovery | GitHub publishes `/.well-known/openid-configuration` at the issuer URL |
| Discovery base URL | **blank** | GitHub's discovery endpoint *is* the issuer URL |
| CA certificate | **blank** | GitHub uses public CAs |
| Maximum token lifetime | **1 hour** (the default) | GitHub tokens are ~10 min `exp − iat`, well under |

> ### Turn OFF "Enforce single-use tokens (JTI replay protection)"
>
> The form's own hint describes our case: *"Disable only if tokens must be reused (for example, a token shared across multiple workers in one process)."*
>
> The integration suite launches **many** sandy containers, each running its own `claude` process, and each exchanges the **same** `ANTHROPIC_IDENTITY_TOKEN` set once in the workflow env. One `jti`, N exchanges. With replay protection on, the first container authenticates and every later one fails — surfacing as a flaky mid-suite auth error rather than a configuration choice.
>
> Minting a fresh token per *section* is the plan (see [Bring-up order](#bring-up-order)) and `SANDY_INTEG_ONLY` is the seam for it — but that does not rescue replay protection. Even within a single section, sandy launches several containers that each exchange the same token, so one `jti` still sees N exchanges. Leave it off.

### Step 2 — Create a rule

The rule maps verified token claims to API access.

| Field | Value | Why |
|---|---|---|
| Rule name | `sandy-integration-ci` | lowercase, hyphens |
| Description | `GitHub Actions Integration workflow for rappdw/sandy` | optional |
| Issuer | `github-ci` | the one registered in Step 1 |
| Subject pattern | `repo:rappdw/sandy:ref:refs/heads/main` | exact — **no trailing `*`** |
| Additional claim conditions | **blank** initially | see below |
| Expected audience | **blank** | blank means Anthropic's default `https://api.anthropic.com`, which is what the workflow requests |
| Service account | the one from Step 0 | must be a **member of the target workspace** |
| Authorization | **Workspaces → Default**, *not* "all workspaces" | least privilege, **and** it avoids needing `ANTHROPIC_WORKSPACE_ID` at all |
| OAuth scope | `workspace:developer` | the default |
| Token lifetime | **`600` — leave it** | see below |

> **Do not raise "Token lifetime" to an hour.** The field is *"upper-bounded by JWT expiry"*, so the minted token expires at `min(configured lifetime, GitHub JWT expiry)`. GitHub's OIDC tokens are short-lived and not configurable, so a larger number buys nothing — it only leaves a stated bound that no longer matches reality. Should the binding ever change (Anthropic revising the semantics, or this rule pointed at an IdP with longer-lived JWTs) a 1-hour setting would silently start minting hour-long tokens. `600` says what is actually intended.
>
> Not to be confused with the **issuer** form's "Maximum token lifetime (hours): 1" — that rejects *incoming* JWTs whose `exp − iat` exceeds it. Different object, opposite direction, and 1 hour is correct there.

The subject pattern is the security boundary. GitHub formats `sub` as:

```
repo:rappdw/sandy:ref:refs/heads/main
```

That value is correct here because `schedule` and `workflow_dispatch` both run on the **default branch**. If the rule form exposes separate fields rather than a raw `sub`, the equivalents are `repository` = `rappdw/sandy`, `ref` = `refs/heads/main`, and optionally `workflow` = `Integration`.

Prefer this exact form over `repo:rappdw/sandy:*` — the wildcard accepts *any* ref, so anyone who can push a branch could mint. (Fork PRs cannot either way: they carry `repo:<forker>/sandy`, and this workflow has no `pull_request` trigger.)

Scoping to the repo is what makes the identifiers non-secret. Without a repository restriction the rule would accept a token from **any** GitHub Actions workflow anywhere.

Leave **claim conditions blank** to start. Pinning `workflow` = `Integration` is reasonable hardening later, but a mismatched condition fails auth in a way that is tedious to diagnose — get it working first.

**The workflow reports the real number.** The mint step decodes the JWT and logs its actual `exp − iat`, warning if it is under 5 minutes. That turns the ceiling from an assumption into a measurement, and if GitHub ever changes it the log says so rather than the budget quietly going stale.

Then note the **federation rule ID**, **organization ID**, and **service account ID**.

**Repository variables** (not secrets — they are identifiers, and a repo-scoped rule means a leaked ID grants nothing):

```sh
gh variable set ANTHROPIC_FEDERATION_RULE_ID  --repo rappdw/sandy
gh variable set ANTHROPIC_ORGANIZATION_ID     --repo rappdw/sandy
gh variable set ANTHROPIC_SERVICE_ACCOUNT_ID  --repo rappdw/sandy
```

Add `ANTHROPIC_WORKSPACE_ID` **only** if the rule spans multiple workspaces; otherwise omit it.

**Three things that will bite you:**

1. **`permissions: id-token: write`** on the job, or `ACTIONS_ID_TOKEN_REQUEST_URL` is never populated and the mint step fails with an empty token.
2. **An empty `ANTHROPIC_API_KEY` outranks WIF.** The resolution order is `ANTHROPIC_API_KEY` → `ANTHROPIC_AUTH_TOKEN` → OAuth profile → WIF, and *even the empty string counts as set*. GitHub Actions **cannot conditionally omit** an `env:` entry — a conditional expression yields `''`, which is still set. They must be `unset` in the shell that launches the suite. This is the failure mode where everything looks configured and auth silently falls back to nothing.
3. **Sandy does not forward unrecognized env vars.** The WIF variables are not sandy config keys, so name them in `SANDY_EXTRA_ENV`. That key is privileged-tier, but the suite exports `SANDY_AUTO_APPROVE_PRIVILEGED=1`, so no prompt blocks it:

   ```
   SANDY_EXTRA_ENV: ANTHROPIC_FEDERATION_RULE_ID,ANTHROPIC_ORGANIZATION_ID,ANTHROPIC_SERVICE_ACCOUNT_ID,ANTHROPIC_IDENTITY_TOKEN
   ```

Prefer `ANTHROPIC_IDENTITY_TOKEN` (the value) over `ANTHROPIC_IDENTITY_TOKEN_FILE` — the file variant would have to be mounted into the container.

## 2. OpenAI

Same shape. In the OpenAI platform console create a **service-account mapping** under a Workload Identity Provider, named for the workflow that may use it (e.g. `github-actions-sandy-integration`); OpenAI verifies the token against GitHub's OIDC discovery metadata and JWKS.

The exchange happens **in the SDK**, so what reaches the container is whatever the OpenAI client reads. Codex is a separate binary from the SDK — **verify it honors the federation env vars before relying on this**, the same way Claude Code was verified:

```sh
strings "$(command -v codex)" | grep -i 'OPENAI_.*\(FEDERATION\|IDENTITY\|SERVICE_ACCOUNT\)'
```

If it doesn't, keep `OPENAI_API_KEY` for the codex sections. Sandy materializes it into an ephemeral read-only `auth.json`, which is a separate mechanism from env-var auth.

## 3. Google — via Vertex AI, and sandy already supports it

**The Gemini API (AI Studio) accepts only API keys — it cannot federate.** Vertex AI accepts WIF tokens natively. So going keyless means moving Gemini onto the Vertex backend.

Sandy already has this plumbing: `SANDY_GEMINI_AUTH=adc` mounts `~/.config/gcloud/application_default_credentials.json`, and `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `GOOGLE_GENAI_USE_VERTEXAI` are all recognized config keys. `google-github-actions/auth` with WIF writes exactly that ADC file.

```yaml
- uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: projects/<num>/locations/global/workloadIdentityPools/<pool>/providers/<provider>
    service_account: sandy-ci@<project>.iam.gserviceaccount.com
```

then set `SANDY_GEMINI_AUTH=adc`, `GOOGLE_GENAI_USE_VERTEXAI=true`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`. GCP-side: create a workload identity pool + provider trusting `token.actions.githubusercontent.com`, with an attribute condition restricting `assertion.repository` to `rappdw/sandy`.

**Without that condition the pool trusts every GitHub repository on earth.** It is the single most important line in the GCP setup.

Cost note: Vertex pricing differs from the AI Studio free tier — check before switching if the free tier is what has been covering these runs.

## 4. xAI — keep the API key

`GROK_OIDC_ISSUER` / `GROK_OIDC_CLIENT_ID` exist, but the flow is **PKCE**: interactive, browser-based, for developers authenticating through Okta/Entra/Auth0. Not usable unattended.

Grok can also invoke an executable that prints a token on stdout, which *would* work in CI — but it needs something to mint the token from, and xAI does not trust GitHub's issuer directly. That is a bridge with no far bank today.

So: keep `XAI_API_KEY` as a secret, or drop it and let the grok sections skip.

---

## Bring-up order

**Do not convert everything at once.** Each step below is separately provable; doing them together means debugging several unproven things at once.

1. **Console setup** — service account (added as a member of the target workspace), issuer, rule, per the sections above.
2. **Set the repository variables** (`gh variable set`, above). Setting `ANTHROPIC_FEDERATION_RULE_ID` is what switches the workflow onto the WIF path; until then it uses the key exactly as today.
3. **Apply the workflow patch**, which is staged behind the existing key path:
   ```sh
   git apply 0002-wif-integration.patch
   ```
   It needs a `workflow`-scoped token to push (`gh auth refresh -h github.com -s workflow`), and `.github/workflows/` is `:ro` inside a sandy session — so commit it from the host.
4. **Re-enable the workflow if it is disabled** — a disabled workflow cannot be dispatched either:
   ```sh
   gh workflow list --repo rappdw/sandy --all      # look for disabled_manually
   gh workflow enable Integration --repo rappdw/sandy
   ```
   Then dispatch a run scoped to **one** claude section (§7 is the claude headless regression):
   ```sh
   gh workflow run Integration --repo rappdw/sandy -f only=7 -f skip=19,20,21
   ```
   Confirm the log reads `auth: workload identity federation (rule …)` **and** that §7 did not skip. A skip means the credential never arrived.
5. **Build the per-section loop** (below), run the full suite, and only then delete `ANTHROPIC_API_KEY` from secrets.

### Token lifetimes — measured, and not what the form implies

**Two different lifetimes, and conflating them cost this document two revisions.**

```
JWT lifetime_seconds : 300    the GitHub assertion's own validity
expires_in           : 598    the Anthropic access token you actually use
```

The rule form says *"Token lifetime … Upper-bounded by JWT expiry"*, which reads as "the minted token cannot outlive the JWT". **Measured on 2026-08-24, that is not what happens**: a 300-second JWT yielded a 598-second access token — the rule's configured 600, essentially in full.

So the usable credential is **~10 minutes**, not the 5 the JWT would suggest. Budget against `expires_in`, not against the JWT.

```
workflow: checkout + docker verify + disk reclaim    ~1-2 min
suite:    agent image build before the first claude  ~3-6 min   (moved outside the window)
lean run  (SKIP=19,20,21)                            ~9.5 min on the maintainer host; CI is slower
full run                                             ~27 min
```

Per section, against ~598s:

| | duration | fits? |
|---|---|---|
| §20 (runs `--rebuild`) | ~432s | yes |
| §19 + §21 | ~300s combined | yes |
| the other ~23 sections | ~14.6 min **total** | trivially |

**Every section fits inside one token**, so per-section re-minting covers the whole suite with no section surgery. Two mitigations, in order:

1. **Pre-build outside the token window** (in the drafted patch). `./sandy --build-only` needs no credentials, so the image build should not consume the credential. Still worth doing — it is 3-6 minutes of a 10-minute budget.
2. **Re-mint per section** — loop `SANDY_INTEG_ONLY` in the workflow. This is the mechanism that retires the API key.

> **Whether the rule's Token lifetime can be raised above 600 is untested.** The form's wording suggested a JWT-derived cap that measurement disproved, so the honest position is that the bound is not understood, not that it is absent. If a longer credential would help, test it rather than reasoning from the form — this document has been wrong about that field twice.

A third option is deliberately rejected: re-minting from *inside* the container would require forwarding `ACTIONS_ID_TOKEN_REQUEST_TOKEN` into the sandbox and allowlisting GitHub's token endpoint through the egress proxy. That puts a GitHub credential inside the box to avoid an Anthropic one — strictly worse than the problem it solves.

**`ANTHROPIC_API_KEY` is a bring-up crutch, not the destination.** It exists so the nightly keeps working while steps 1–3 above are being proven, and it goes away at step 5.

---

## Diagnosing a failed exchange

The exchange returns a deliberately vague `authentication_error` / "Authentication failed" with a `request_id`. **The real reason is in the Claude Console's activity log**, keyed by that `request_id` — go there first rather than guessing at the workflow.

The entry carries `status.reason` plus the full decoded token claims, which is everything needed to diff intent against reality:

| `status.reason` | Means | Fix |
|---|---|---|
| `match_claim_value_mismatch` | an **Additional claim condition** on the rule does not match the token | compare the condition against the logged `claims`. A condition pinning `workflow` to one workflow's name fails for *every other* workflow — including a smoke test |
| subject/pattern mismatch | the `sub` does not match the subject pattern | compare `claims.sub` against the pattern; a push from a non-`main` branch is the usual cause |
| `workspace_id_required` | the rule spans multiple workspaces | set `ANTHROPIC_WORKSPACE_ID` |

Claims worth knowing are distinct, because pinning the wrong one is the common mistake:

```
sub               repo:rappdw/sandy:ref:refs/heads/main
workflow          the workflow NAME          e.g. anthropic-wif-test
workflow_ref      owner/repo/.github/workflows/<file>@<ref>
job_workflow_ref  same, for the job's defining workflow
ref               refs/heads/main
repository        rappdw/sandy
```

This is why claim conditions start blank: `sub` alone already carries repo **and** ref, so a `workflow` condition adds little and breaks any workflow not named in it. Add conditions only after the exchange is proven, and only ones you can state a threat for.

---

## Verifying

```sh
gh variable list --repo rappdw/sandy    # identifiers — safe to read
gh secret   list --repo rappdw/sandy    # names only; values are never retrievable
```

The suite prints its credential banner near the top of the run. Under WIF, expect `Claude: ✓ (wif)` with **no** `ANTHROPIC_API_KEY` secret configured — that is the whole point.

> ### A WIF run can go green having tested nothing
>
> The first federated run reported success and executed zero tests:
>
> ```
> auth: workload identity federation (rule fdrl_…)     ← the workflow half worked
> ⊘ claude headless regression (no Anthropic credentials) (skipped)
> All 0 tests passed (1 skipped — missing credentials).
> ```
>
> The workflow authenticated correctly, but the **suite's own credential detection did not know WIF exists** — it looked for `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, or `~/.claude/.credentials.json`, and WIF supplies none of them. Every claude section skipped, and because a skip is a *legitimate* outcome, nothing failed.
>
> Fixed in `run-integration-tests.sh` (#196), which now treats `ANTHROPIC_FEDERATION_RULE_ID` **plus** `ANTHROPIC_IDENTITY_TOKEN` as credentials — both, since a rule alone is configuration with nothing to exchange.
>
> **The operational lesson outlives the fix:** on this suite, green does not mean tested. Always confirm the banner shows the auth method you expect *and* that the sections you care about actually ran. A skipped section and a passing section look identical in the exit code.

### Verification checklist for a WIF run

1. `auth: workload identity federation (rule …)` — the workflow took the WIF branch rather than falling back
2. `Claude: ✓ (wif)` in the banner — the *suite* recognised the credential
3. The section you targeted **ran**, rather than reporting `⊘ … (skipped)`
4. `All N tests passed` with **N > 0**

Only 3 and 4 distinguish a working setup from a well-configured one that tests nothing.
