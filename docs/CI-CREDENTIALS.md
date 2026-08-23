# CI credentials runbook

How to mint **dedicated** provider API keys for the `Integration` workflow, rather than reusing the ones in your local environment.

> UI paths on provider consoles drift. The durable instruction in each section is the **shape** — create an isolated scope, put a CI-only key in it, give that scope a spend cap. Treat the click-paths as hints, not gospel.

---

## Why separate keys at all

Reusing your local key means CI and your laptop share one blast radius and one rotation schedule. A dedicated key per purpose buys three things:

- **Bounded blast radius.** If the CI key leaks, you revoke exactly one key and nothing on your machine changes.
- **Independent rotation.** You can rotate CI on a schedule without logging yourself out mid-task.
- **Attributable spend.** Usage under the CI key is CI's usage. When the nightly run starts costing more than you expect, you can see that directly instead of inferring it.

The same reasoning is why `test/sync-ci-secrets.sh` refuses to push OAuth session files: refresh tokens are account-shaped, not purpose-shaped.

**Do not use `CLAUDE_CODE_OAUTH_TOKEN` for CI.** It is a subscription credential tied to your account — you cannot rotate it independently of your own interactive use (revoking it logs you out), it is not metered so you cannot cap it, and its blast radius is account-level rather than one key. Use an `ANTHROPIC_API_KEY` instead.

---

## What each key unlocks

Set them in this order if you are doing it incrementally — the first buys the most.

| Secret | Unlocks | Priority |
|---|---|---|
| `ANTHROPIC_API_KEY` | every claude launch, plus the daemon (§19) and pane-topology (§21) acceptance harnesses | **highest** |
| `OPENAI_API_KEY` | codex image build + headless (§ codex), and one OpenCode auth path | medium |
| `GEMINI_API_KEY` | gemini image build + headless, and one OpenCode auth path | medium |
| `XAI_API_KEY` | grok image build + headless | low |

Every keyed section **probes for its credential and skips cleanly** when absent (~22 such skips). So a partial set is a valid configuration, not a broken one — the run stays green and simply covers less.

---

## 1. Anthropic — `ANTHROPIC_API_KEY`

Console: <https://console.anthropic.com>

1. Create a **Workspace** dedicated to CI (e.g. `sandy-ci`). Workspaces are the isolation primitive here: a key belongs to one, and a workspace carries its own spend limit.
2. Set a **monthly spend limit** on that workspace. Pick a number that would cover a few nightly runs and nothing more — the point is that a runaway loop or a leaked key hits a wall.
3. Create an API key **inside that workspace**. Name it for where it lives, e.g. `github-actions-sandy`.
4. Copy it once — you will not see it again.

## 2. OpenAI — `OPENAI_API_KEY`

Console: <https://platform.openai.com>

1. Create a **Project** for CI (e.g. `sandy-ci`). Projects scope keys and carry their own budget and rate limits.
2. Set a **budget / usage limit** on the project.
3. Create a **project-scoped** API key (not a legacy user-level key — a user key ignores the project boundary you just drew).
4. Name it `github-actions-sandy`.

## 3. Google Gemini — `GEMINI_API_KEY`

Console: <https://aistudio.google.com/apikey> (or the Google Cloud console for a Vertex-backed setup)

1. Create or select a **Google Cloud project** used only for CI. The API key is bound to a project, so the project *is* the isolation boundary.
2. Create the API key in that project.
3. Apply **API restrictions** to the key so it can call only the Generative Language API, and set quotas on the project.

Note: sandy also supports Gemini via OAuth and ADC locally. Neither is appropriate for CI, for the same reason as the Claude OAuth token — use the API key.

## 4. xAI — `XAI_API_KEY`

Console: <https://console.x.ai>

1. Create an API key, named `github-actions-sandy`.
2. If your account supports team or per-key credit limits, apply one.

Grok authenticates fully headless from `XAI_API_KEY` alone — there is no auth file to materialize, so this is the whole story for grok.

---

## Setting them as GitHub secrets

**Do not put CI keys in your shell environment or `~/.sandy/.secrets`.** That would re-merge the two blast radii you just separated, and `test/sync-ci-secrets.sh` would then treat them as local credentials. Set them straight from the provider console to GitHub:

```sh
gh secret set ANTHROPIC_API_KEY --repo rappdw/sandy   # paste, then Ctrl-D
gh secret set OPENAI_API_KEY    --repo rappdw/sandy
gh secret set GEMINI_API_KEY    --repo rappdw/sandy
gh secret set XAI_API_KEY       --repo rappdw/sandy
```

Reading on **stdin** matters: a value passed as `--body "$KEY"` is visible to any user on the box via `ps` and lands in your shell history.

Confirm the names landed (values are never retrievable, by design):

```sh
gh secret list --repo rappdw/sandy
```

`test/sync-ci-secrets.sh` is for the *other* workflow — pushing credentials you already hold locally. Once you are on dedicated CI keys, it is no longer the right tool for setting them; its dry run is still useful as a local inventory.

---

## Verifying

```sh
gh workflow run Integration --repo rappdw/sandy
gh run watch --repo rappdw/sandy
```

In the run log, the suite prints its credential banner near the top. Expect **`api-key`** for each provider you configured, and **not** the `oauth` entries your host shows — those come from local files that are deliberately not synced. One working auth path per agent is sufficient.

A section reporting `skip (no XAI_API_KEY)` is doing the right thing, not failing.

---

## Rotation

Rotate on a schedule (quarterly is a reasonable default) and immediately on any suspicion. Rotate **without a gap**:

1. Mint the replacement in the same workspace/project.
2. `gh secret set <NAME>` — the new value overwrites the old.
3. Trigger a `workflow_dispatch` run and confirm it passes.
4. **Then** revoke the old key in the provider console.

Doing step 4 first gives you a window where CI is broken and you are debugging a self-inflicted outage.

Record the mint date somewhere you will actually look — the provider console's "last used" column tells you whether a key is live, but not whether it is overdue.

## If a CI key is exposed

1. **Revoke first**, in the provider console. Do not start with rotation — revocation is what stops the bleeding.
2. Mint a replacement and set the secret.
3. Check the provider's usage logs for the exposure window. This is the payoff for having used a dedicated key: usage under it is unambiguously CI's, so anomalies stand out instead of being buried in your own traffic.
4. If the exposure was a leaked workflow log, remember that GitHub masks registered secrets in logs on a best-effort basis — a value that was transformed (base64'd, embedded in JSON) before printing can evade the mask.

---

## Threat notes for this workflow specifically

- **No `pull_request` trigger, deliberately.** GitHub does not pass secrets to forked-repo PRs, and it should not — a keyed run triggered by an untrusted fork would hand an attacker these keys. Triggers are `schedule` and `workflow_dispatch`, both of which run in the base-repo trust context. If you ever add a `pull_request` trigger to this workflow, the keys must come out of it first.
- **Anyone who can push to `main` or dispatch a workflow can exfiltrate these secrets** — that is inherent to CI secrets, not specific to this setup. It is an argument for spend caps and dedicated keys, which bound what a compromise is worth.
- **Actions are pinned by major tag, not commit SHA** (`actions/checkout@v7`, `actions/cache@v6`). A compromised upstream action release could read secrets in this job. Pinning to full SHAs closes that; it is the standard hardening step if you decide these keys warrant it.
