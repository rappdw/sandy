# Architecture Review: sandy Launcher

**Reviewer:** Codebase Architect
**Date:** 2026-02-16
**Scope:** sandy launcher (518 lines) and install.sh (84 lines)

---

## Executive Summary

The sandy launcher is a well-structured Bash script that orchestrates Docker-based isolation for Claude Code. The architecture demonstrates solid engineering principles with hash-based caching, ephemeral credentials, and platform-aware implementations. However, several critical race conditions, signal handling gaps, and concurrent execution hazards require immediate attention before release.

**Critical Issues:** 3
**High Priority:** 5
**Medium Priority:** 4
**Low Priority:** 3
**Informational:** 6

---

## 1. Full Lifecycle Trace

### 1.1 Execution Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                          SANDY INVOCATION                           │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ PREFLIGHT CHECKS (lines 38-66)                                     │
│  • Parse --help flag                                                │
│  • Verify docker command exists                                     │
│  • Set SANDY_HOME (default: ~/.sandy)                              │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ BUILD FILE GENERATION (lines 69-214)                               │
│  • ensure_build_files()                                             │
│    - Generate Dockerfile.new (73 lines)                            │
│    - Generate entrypoint.sh.new (80 lines)                         │
│    - Generate tmux.conf.new (26 lines)                             │
│    - Atomic replacement if content changed (diff check)            │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ RESOURCE DETECTION (lines 216-224)                                 │
│  • Query docker info for CPU/memory                                │
│  • Calculate limits: SANDY_CPUS, SANDY_MEM                         │
│  • Fallback to safe defaults on parse failure                      │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ IMAGE BUILD (lines 226-235)                                        │
│  • Hash build files (Dockerfile + entrypoint.sh + tmux.conf)      │
│  • Compare with ~/.sandy/.build_hash                               │
│  • Skip if hash matches AND image exists                           │
│  • docker build if stale/missing                                   │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ NETWORK SETUP (lines 237-249)                                      │
│  • ensure_network()                                                 │
│  • Create br-claude bridge (172.30.0.0/24) if missing             │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ SANDBOX DIRECTORY CREATION (lines 251-312)                         │
│  • Hash working directory → 8-char short hash                      │
│  • Sanitize basename for mnemonic naming                           │
│  • Sandbox path: ~/.sandy/sandboxes/{name}-{hash}                 │
│  • Migrate legacy hash-only sandboxes if present                   │
│  • Seed settings.json, statsig/ from host ~/.claude                │
│  • Merge sandy defaults via Node.js JSON manipulation              │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ .claude.json SEEDING (lines 374-396)                               │
│  • Stored at ~/.sandy/sandboxes/{name}-{hash}.claude.json         │
│  • Seed from host ~/.claude.json (theme, OAuth, onboarding)       │
│  • Merge tipsDisabled=true override                                │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ CREDENTIAL LOADING (lines 398-413)                                 │
│  • EPHEMERAL: Fresh tmpdir each launch                             │
│  • Linux: Copy ~/.claude/.credentials.json                         │
│  • macOS: Extract from macOS Keychain                              │
│  • chmod 600, mount read-only                                      │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ NETWORK ISOLATION (lines 326-372)                                  │
│  • Install trap cleanup EXIT                                       │
│  • apply_network_isolation()                                       │
│    - Clean stale rules from previous runs                          │
│    - Linux: iptables DOCKER-USER chain                             │
│      * DROP private ranges (10/8, 172.16/12, 192.168/16, etc.)    │
│      * ACCEPT 172.30.0.0/24 (container subnet)                     │
│    - macOS: Docker Desktop provides VM-level isolation             │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ GIT AUTHENTICATION SETUP (lines 441-507)                           │
│  • SANDY_SSH=token (default):                                      │
│    - Extract gh auth token                                         │
│    - Mount as GIT_TOKEN env var                                    │
│  • SANDY_SSH=agent (opt-in):                                       │
│    - Linux: Mount SSH_AUTH_SOCK directly                           │
│    - macOS: Start TCP relay (Node.js), expose port to container   │
│    - Mount ~/.ssh read-only → /tmp/host-ssh                        │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ DOCKER RUN FLAGS ASSEMBLY (lines 415-507)                          │
│  • --rm -it (interactive, auto-remove)                             │
│  • --cpus / --memory (resource limits)                             │
│  • --security-opt no-new-privileges                                │
│  • --read-only (immutable root filesystem)                         │
│  • --tmpfs /tmp:size=1G                                            │
│  • --tmpfs /home/claude:size=512M,uid=1001                         │
│  • -v $SANDBOX_DIR:/home/claude/.claude                            │
│  • -v $CRED_TMPDIR/.credentials.json (ephemeral, ro)              │
│  • -v $CLAUDE_JSON:/home/claude/.claude.json                       │
│  • -v $WORK_DIR:/workspace                                         │
│  • --network sandy_internet-only                                   │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ CONTAINER LAUNCH (line 517)                                        │
│  • docker run "${RUN_FLAGS[@]}" sandy-claude-code "$@"            │
│  • Entrypoint flow (inside container):                             │
│    1. Seed SSH known_hosts (if mounted)                            │
│    2. SSH agent setup (if SANDY_SSH=agent)                         │
│       - macOS: Node.js Unix→TCP socket relay                       │
│       - Linux: Use mounted socket                                  │
│    3. Copy ~/.ssh with correct ownership                           │
│    4. Drop to user claude via gosu                                 │
│    5. Trust /workspace git directory                               │
│    6. Configure git auth (token or agent)                          │
│    7. Launch tmux session with claude CLI                          │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│ CLEANUP ON EXIT (trap cleanup EXIT, lines 361-369)                │
│  • cleanup_network_isolation()                                     │
│    - Remove iptables rules (Linux)                                 │
│  • rm -rf $CRED_TMPDIR (ephemeral credentials)                     │
│  • kill SSH_RELAY_PID (macOS SSH agent relay)                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 Critical Path Analysis

**Initialization Phase (lines 1-214):**
- Fast path: Build file diff checks enable zero-rebuild launches (~50ms overhead)
- Slow path: First run triggers `docker build` (~60-120s depending on network)

**Setup Phase (lines 216-413):**
- Network creation: Idempotent `docker network create` (fails gracefully if exists)
- Sandbox creation: One-time seed, reused on subsequent runs
- Credential loading: Fresh tmpdir every launch (ephemeral by design)

**Isolation Phase (lines 326-372):**
- iptables rules: Applied synchronously, cleaned up in trap
- **RACE HAZARD**: No locking between concurrent sandy invocations

**Launch Phase (lines 415-517):**
- Docker run blocks until container exits
- Cleanup trap fires on normal exit, SIGINT, SIGTERM

---

## 2. Inline File Generation

### 2.1 Build File Strategy

**Files Generated:**
1. `Dockerfile` (lines 72-85): 14-line minimal Node.js base
2. `entrypoint.sh` (lines 87-168): 81-line root → user privilege drop
3. `tmux.conf` (lines 170-196): 27-line tmux config

**Generation Logic:**
```bash
# Atomic update pattern (lines 198-211)
for f in Dockerfile entrypoint.sh tmux.conf; do
    if [ ! -f "$SANDY_HOME/$f" ] || ! diff -q "$SANDY_HOME/$f.new" "$SANDY_HOME/$f"; then
        mv "$SANDY_HOME/$f.new" "$SANDY_HOME/$f"
        changed=true
    else
        rm "$SANDY_HOME/$f.new"
    fi
done
```

**[HIGH] Finding 2.1: Build Cache Invalidation Incomplete**

The build hash (line 227) includes Dockerfile, entrypoint.sh, and tmux.conf but **misses dependencies**:
- Changes to base image `node:20-slim` won't trigger rebuild
- Changes to npm package `@anthropic-ai/claude-code` won't trigger rebuild
- tmux.conf changes force rebuild even though it's just COPY'd (could be updated without rebuild)

**Recommendation:**
- Add version pinning to Dockerfile: `npm install -g @anthropic-ai/claude-code@<VERSION>`
- Separate tmux.conf hash from build hash (it's a static file copy)
- Document rebuild policy: `sandy --rebuild` flag or `rm ~/.sandy/.build_hash`

**[INFO] Finding 2.2: Inline Files vs. External Files**

Inline generation is appropriate for this use case:
- ✅ Single-file distribution (no separate assets to bundle)
- ✅ Atomic updates (diff-based replacement)
- ✅ Version locked to launcher script

**Trade-offs:**
- ❌ Harder to debug (must edit ~/.sandy/Dockerfile, not the source)
- ❌ Large heredocs reduce script readability
- ✅ No file-sync issues between script versions

---

## 3. Error Handling Patterns

### 3.1 Shell Options

```bash
set -euo pipefail  # Line 2
```

**Analysis:**
- `-e`: Exit on error (any non-zero exit code)
- `-u`: Treat unset variables as errors
- `-o pipefail`: Propagate errors through pipes

**[MEDIUM] Finding 3.1: set -e Gotchas**

Several commands intentionally ignore errors via `|| true`:
```bash
# Line 229: Expected behavior (skip build if image exists)
! docker image inspect "$IMAGE_NAME" &>/dev/null

# Line 329-332: Cleanup is idempotent (rules may not exist)
sudo iptables -D DOCKER-USER ... 2>/dev/null || true

# Line 497: Token may not exist
GIT_TOKEN="$(gh auth token 2>/dev/null || true)"
```

These are **correctly handled**. However:

**[CRITICAL] Finding 3.2: Unguarded Docker Operations**

Line 517: `docker run "${RUN_FLAGS[@]}" "$IMAGE_NAME" "$@"`

If `docker run` fails (e.g., OOM, image pull failure), the script exits via `set -e` but the cleanup trap **has already run** (installed at line 371). This is correct behavior.

**BUT**: If the container starts successfully then crashes, cleanup runs. If the container is killed via SIGKILL (not trapped), cleanup **may not run**.

**Recommendation:**
- Document that SIGKILL bypasses cleanup (this is a fundamental limitation)
- Add health check: Verify iptables rules were cleaned after manual SIGKILL

### 3.2 Cleanup Reliability

**[HIGH] Finding 3.3: Partial Cleanup on Failure**

If `apply_network_isolation()` (line 372) fails after creating some iptables rules:
1. The script exits via `set -e`
2. The trap calls `cleanup_network_isolation()`
3. Cleanup attempts to delete **all** rules (lines 355-357)

This is **correct** but fragile:
- If `sudo iptables -D` fails on one rule, it continues (|| true)
- If sudo authentication fails, cleanup silently fails

**Recommendation:**
- Check if `sudo iptables -L DOCKER-USER` succeeds before attempting cleanup
- Log cleanup failures to stderr (not silently ignored)

### 3.3 Subprocess Failures

**[MEDIUM] Finding 3.4: Node.js Dependency**

Lines 290-303 and 383-391 use Node.js for JSON manipulation:
```bash
if command -v node &>/dev/null; then
    node -e "..."  # JSON merge
else
    # Fallback: simple write
fi
```

**Issue:** If Node.js is available but the script fails (syntax error, fs error), the fallback is **not executed** (set -e exits immediately).

**Recommendation:**
- Wrap Node.js calls in `|| fallback_function` pattern
- Or: Use `jq` instead of Node.js (more robust, smaller dependency)

---

## 4. Signal/Trap Handling

### 4.1 Trap Configuration

```bash
trap cleanup EXIT  # Line 371
```

**Analysis:**
- Catches: Normal exit, SIGINT, SIGTERM, script errors (set -e)
- **Misses**: SIGHUP, SIGQUIT, SIGKILL (unkillable)

**[HIGH] Finding 4.1: Incomplete Signal Coverage**

The trap only handles `EXIT`. This means:
- ✅ Ctrl+C (SIGINT) → EXIT trap fires
- ✅ `kill <pid>` (SIGTERM) → EXIT trap fires
- ❌ `kill -9 <pid>` (SIGKILL) → No cleanup
- ❌ Terminal disconnect (SIGHUP) → May or may not fire (shell-dependent)

**Recommendation:**
```bash
trap cleanup EXIT INT TERM HUP
```

This ensures explicit signal handling (defense in depth).

**[CRITICAL] Finding 4.2: Stale iptables Rules**

Current mitigation (lines 328-332):
```bash
# Clean up any stale rules from a previous unclean exit
sudo iptables -D DOCKER-USER -i "$BRIDGE_NAME" ...
```

This is **excellent defensive programming** but has a race condition:

**Scenario:**
1. sandy instance A starts, adds iptables rules
2. sandy instance B starts, cleans stale rules (removes A's rules!)
3. Instance A is now unprotected

See **Finding 7.1** below.

### 4.2 Cleanup Function Anatomy

```bash
cleanup() {
    cleanup_network_isolation
    if [ -n "${CRED_TMPDIR:-}" ]; then
        rm -rf "$CRED_TMPDIR"
    fi
    if [ -n "${SSH_RELAY_PID:-}" ]; then
        kill "$SSH_RELAY_PID" 2>/dev/null || true
    fi
}
```

**[INFO] Finding 4.3: Cleanup is Defensive**

- Uses `${VAR:-}` to avoid unset variable errors
- Ignores kill errors (process may have already exited)
- `rm -rf` is safe (tmpdir is ephemeral)

**[LOW] Finding 4.4: No Cleanup Idempotency Guard**

If the trap fires twice (can happen in some shells), cleanup runs twice. This is safe but wasteful:
- `cleanup_network_isolation`: Attempts to delete rules (fails silently if missing)
- `rm -rf $CRED_TMPDIR`: Fails silently if already removed
- `kill $SSH_RELAY_PID`: Fails silently if already dead

**Recommendation:** Add guard:
```bash
cleanup() {
    [ -n "${CLEANUP_DONE:-}" ] && return
    CLEANUP_DONE=1
    # ... rest of cleanup
}
```

---

## 5. Idempotency

### 5.1 Idempotent Operations

| Operation | Idempotent? | Notes |
|-----------|-------------|-------|
| `ensure_build_files()` | ✅ Yes | Diff-based update |
| `docker build` | ✅ Yes | Skipped if hash matches |
| `ensure_network()` | ✅ Yes | `docker network create` fails gracefully if exists |
| Sandbox creation | ✅ Yes | `mkdir -p` is idempotent |
| iptables rules | ❌ **NO** | See Finding 5.1 |
| Credential tmpdir | ❌ **NO** | Fresh tmpdir every launch |

**[CRITICAL] Finding 5.1: iptables Rule Duplication**

If `apply_network_isolation()` is called twice in the same script invocation:
```bash
sudo iptables -I DOCKER-USER ...  # INSERT (not replace)
```

Each call **prepends** new rules. Multiple invocations → duplicate rules.

**Current mitigation:** Script only calls `apply_network_isolation()` once (line 372).

**Risk:** If refactored to retry on failure, rules will duplicate.

**Recommendation:**
- Add idempotency check:
```bash
apply_network_isolation() {
    [ -n "${IPTABLES_APPLIED:-}" ] && return
    IPTABLES_APPLIED=1
    # ... rest of function
}
```

### 5.2 Concurrent Execution

**[CRITICAL] Finding 5.2: No Locking Mechanism**

Multiple sandy instances can run concurrently with **shared resources**:
1. `~/.sandy/Dockerfile` (diff checks may race)
2. `~/.sandy/.build_hash` (writes are not atomic)
3. Docker network `sandy_internet-only` (shared)
4. iptables DOCKER-USER chain (globally shared)

**Race Scenario:**
```
Time  Instance A                Instance B
----  ----------------------    ----------------------
T0    Write Dockerfile.new
T1                              Write Dockerfile.new (overwrites A)
T2    diff Dockerfile.new
T3                              diff Dockerfile.new
T4    mv Dockerfile.new
T5                              mv Dockerfile.new (FAILS, file missing)
```

**Recommendation:**
- Use `flock` for critical sections:
```bash
(
    flock -x 200
    ensure_build_files
    # ... docker build
) 200>~/.sandy/.lock
```

---

## 6. Cross-Platform Logic

### 6.1 Platform Detection

```bash
OS="$(uname -s)"  # Line 315
```

**Branches:**
1. Linux: iptables, direct SSH socket mount
2. macOS: Docker Desktop VM isolation, TCP SSH relay
3. Other: Untested (likely fails)

**[MEDIUM] Finding 6.1: No Windows Support**

Windows users with WSL2 + Docker Desktop will get `uname -s` = `Linux` but may have different behavior:
- iptables may not work (WSL2 networking is complex)
- SSH agent forwarding differs

**Recommendation:**
- Add WSL detection: `[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]`
- Document: "Use WSL2 with Docker Desktop, iptables may require manual setup"

### 6.2 SSH Agent Forwarding

**Linux (lines 459-462):**
```bash
RUN_FLAGS+=(-v "$SSH_AUTH_SOCK:/tmp/ssh-agent.sock")
```

**macOS (lines 464-487):**
```bash
node -e "..."  # TCP relay on random port
RUN_FLAGS+=(-e "SSH_RELAY_PORT=$SSH_RELAY_PORT")
```

**[HIGH] Finding 6.2: macOS Relay Failure Not Detected**

If the Node.js relay fails to start (e.g., port exhaustion, Node.js error):
- `SSH_RELAY_PID=$!` captures the PID
- Script waits for port file (lines 480-483)
- If wait times out, `SSH_RELAY_PORT` is **empty or invalid**
- Container receives broken config, git operations fail silently

**Recommendation:**
```bash
if [ -z "$SSH_RELAY_PORT" ]; then
    error "SSH relay failed to start"
    exit 1
fi
```

### 6.3 Credential Loading

**macOS Keychain (lines 405-412):**
```bash
KEYCHAIN_CREDS="$(security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null || true)"
```

**[INFO] Finding 6.3: Platform-Specific Fallback Chain**

Priority order:
1. `~/.claude/.credentials.json` (all platforms)
2. macOS Keychain (macOS only)
3. No credentials (warning, requires ANTHROPIC_API_KEY)

This is **well-designed** and handles platform differences correctly.

---

## 7. Race Conditions

### 7.1 Concurrent Invocations

**[CRITICAL] Finding 7.1: iptables Rule Conflicts**

**Scenario:**
```
Terminal 1: cd ~/project-A && sandy
Terminal 2: cd ~/project-B && sandy  (seconds later)
```

**Timeline:**
```
T0: Instance A cleans stale rules (lines 329-332)
T1: Instance A applies rules (lines 342-346)
T2: Instance B cleans stale rules → DELETES A's rules!
T3: Instance B applies rules
T4: Instance A's container is now UNPROTECTED (LAN access possible)
T5: Instance A exits, cleanup deletes B's rules
T6: Instance B's container is now UNPROTECTED
```

**Root Cause:** iptables rules are identified by `--bridge-name`, which is **shared** across all instances.

**Recommendation:**

**Option 1 (Preferred): Per-Instance Networks**
```bash
BRIDGE_NAME="br-claude-$$"  # Unique per process
NETWORK_NAME="sandy_internet-only_$$"
```
Each instance gets its own bridge and rules. Cleanup only affects its own resources.

**Option 2: Global Lock**
```bash
exec 200>~/.sandy/.iptables.lock
flock -x 200
apply_network_isolation
# Keep lock until cleanup
```

**Option 3: Reference Counting**
Store active instances in `~/.sandy/.active_pids`, only delete rules when count reaches 0. (Complex, fragile)

### 7.2 Docker Build Races

**[HIGH] Finding 7.2: Concurrent docker build**

If two instances detect stale build hash simultaneously:
```
T0: Instance A computes BUILD_HASH
T1: Instance B computes BUILD_HASH (same value)
T2: Instance A starts docker build
T3: Instance B starts docker build (redundant, wastes resources)
T4: Both write ~/.sandy/.build_hash (last write wins, benign)
```

**Impact:** Wasted CPU/time, not a correctness issue.

**Recommendation:**
- Use flock around docker build
- Or accept the inefficiency (rare, only on first run or upgrades)

### 7.3 Sandbox Directory Creation

**[LOW] Finding 7.3: Benign Race in Sandbox Creation**

Lines 273-312: `mkdir -p` and file seeding are not atomic. Two instances launching **same project** concurrently might:
- Both create `$SANDBOX_DIR` (benign, mkdir -p is idempotent)
- Both copy settings.json (last write wins, benign)
- Both run Node.js JSON merge (may corrupt if writes interleave)

**Probability:** Low (requires same project, same millisecond launch)

**Recommendation:** Acceptable risk for v1.0, document as known limitation.

---

## 8. Code Organization

### 8.1 Function Structure

**Functions Defined:**
1. `info()`, `warn()`, `error()` (lines 33-35): Logging
2. `ensure_build_files()` (lines 69-211): File generation
3. `ensure_network()` (lines 238-247): Network setup
4. `apply_network_isolation()` (lines 326-349): iptables rules
5. `cleanup_network_isolation()` (lines 351-359): iptables cleanup
6. `cleanup()` (lines 361-369): Main cleanup

**[INFO] Finding 8.1: Good Separation of Concerns**

Each function has a single responsibility. The main script is linear and readable.

**[MEDIUM] Finding 8.2: Large Inline Functions**

`ensure_build_files()` is 142 lines (68% heredocs). This is acceptable for this use case but makes diffing changes harder.

**Recommendation:** Consider splitting into:
```bash
generate_dockerfile() { cat >$1 <<'EOF' ... }
generate_entrypoint() { cat >$1 <<'EOF' ... }
ensure_build_files() { generate_dockerfile ...; generate_entrypoint ...; }
```

### 8.2 Variable Naming

**Global Constants:**
- `SANDY_HOME`, `BRIDGE_NAME`, `IMAGE_NAME`, `NETWORK_NAME`: SCREAMING_CASE (good)
- `OS`, `WORK_DIR`, `SANDBOX_DIR`: SCREAMING_CASE (good)

**Local Variables:**
- `changed` (line 199): lowercase (inconsistent)
- `f` (line 200): single-letter (acceptable in loop)

**[LOW] Finding 8.3: Inconsistent Naming**

Most variables are SCREAMING_CASE (indicating global/constant), but `changed` is lowercase.

**Recommendation:** Use `local` keyword for function-scoped variables:
```bash
ensure_build_files() {
    local changed=false
    local f
    ...
}
```

### 8.3 Magic Numbers

**[INFO] Finding 8.4: Hardcoded Limits**

- `--memory`: `(AVAILABLE_MEM_GB - 1)g` or `2g` minimum (line 224)
- `--tmpfs /tmp:size=1G` (line 420)
- `--tmpfs /home/claude:size=512M` (line 421)
- Network subnet: `172.30.0.0/24` (line 243)

These are reasonable defaults but not configurable.

**Recommendation:** Add environment variables:
```bash
SANDY_MEM="${SANDY_MEM:-$(calculate_default_mem)}"
SANDY_TMP_SIZE="${SANDY_TMP_SIZE:-1G}"
```

---

## 9. Install Script Architecture

### 9.1 Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ install.sh EXECUTION                                        │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ PREREQUISITE CHECKS (lines 22-39)                          │
│  • docker (warn if missing)                                 │
│  • node (warn if missing)                                   │
│  • gh (warn if missing or not authenticated)                │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ DOWNLOAD/COPY sandy (lines 44-58)                          │
│  • If LOCAL_INSTALL set: cp local file                      │
│  • Else: curl or wget from SANDY_URL                        │
│  • Install to $INSTALL_DIR/sandy (default: ~/.local/bin)   │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ PATH CHECK (lines 63-76)                                   │
│  • Check if INSTALL_DIR in PATH                             │
│  • If not: Show shell-specific instructions                │
│    - zsh: .zshrc                                            │
│    - bash: .bashrc                                          │
│    - fish: fish_add_path                                    │
│    - other: generic export                                  │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ COMPLETION MESSAGE (lines 78-84)                           │
└─────────────────────────────────────────────────────────────┘
```

### 9.2 Findings

**[INFO] Finding 9.1: Installer is Simple and Robust**

- No complex dependencies (curl/wget only)
- Graceful fallbacks (curl → wget)
- Non-destructive (warns but continues on missing prereqs)

**[LOW] Finding 9.2: No Version Check**

The installer doesn't verify:
- Minimum Docker version (e.g., requires Docker 20.10+ for `--security-opt`)
- Minimum Node.js version (e.g., requires Node 14+ for async/await in relay)

**Recommendation:**
```bash
DOCKER_VERSION="$(docker --version | grep -oE '[0-9]+\.[0-9]+' | head -1)"
if [ "$(printf '%s\n' "20.10" "$DOCKER_VERSION" | sort -V | head -1)" != "20.10" ]; then
    error "Docker 20.10+ required, found $DOCKER_VERSION"
    exit 1
fi
```

**[LOW] Finding 9.3: curl | sh Pattern**

```sh
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | sh
```

This is a **standard pattern** (used by Homebrew, rustup, etc.) but has risks:
- User cannot inspect script before execution
- Network interruption mid-download could execute partial script

**Mitigation (already implemented):**
- `-f`: Fail on HTTP errors
- `-s`: Silent (no progress bar)
- `-S`: Show errors even in silent mode
- `-L`: Follow redirects

**Recommendation:** Document two-step install in README:
```bash
# Option 1: Direct (standard)
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | sh

# Option 2: Inspect first
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh -o install.sh
less install.sh
sh install.sh
```

---

## 10. Additional Security Findings

### 10.1 SANDY_MODEL Validation

**[INFO] Finding 10.1: Input Validation Present**

Lines 430-435:
```bash
SANDY_MODEL="${SANDY_MODEL:-claude-opus-4-6}"
if ! [[ "$SANDY_MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    error "Invalid SANDY_MODEL: $SANDY_MODEL"
    exit 1
fi
```

This prevents command injection via environment variable.

**[HIGH] Finding 10.2: Missing Validation on Other Inputs**

`SANDY_HOME` is not validated (line 18):
```bash
SANDY_HOME="${SANDY_HOME:-$HOME/.sandy}"
```

If a user sets `SANDY_HOME="/tmp; rm -rf /"`, the script could execute arbitrary commands in paths like:
```bash
cat > "$SANDY_HOME/Dockerfile.new" <<'DOCKERFILE'  # Could create file at malicious path
```

**Recommendation:**
```bash
# Validate SANDY_HOME contains no shell metacharacters
if [[ "$SANDY_HOME" =~ [';$`&|<>'] ]]; then
    error "Invalid SANDY_HOME: contains shell metacharacters"
    exit 1
fi
```

### 10.2 Privileged Operations

**[INFO] Finding 10.3: sudo Usage is Documented**

Lines 329-357: `sudo iptables` requires privilege elevation.

**User Impact:**
- First run: User is prompted for sudo password
- Subsequent runs: May be cached (depending on sudo timeout)

**Recommendation:** Document in README:
```markdown
## Permissions

sandy requires sudo access on Linux to configure network isolation (iptables).
You'll be prompted for your password on first run.

macOS: No sudo required (Docker Desktop provides isolation).
```

---

## Summary of Findings by Severity

### CRITICAL (3)

1. **Finding 3.2**: Unguarded container failures may leave stale resources (low probability)
2. **Finding 5.1**: iptables rule duplication if apply_network_isolation() called multiple times
3. **Finding 7.1**: Concurrent sandy instances can delete each other's iptables rules → LAN exposure

### HIGH (5)

1. **Finding 2.1**: Build cache doesn't detect upstream changes (base image, npm package)
2. **Finding 3.3**: Partial cleanup on failure may leave stale iptables rules
3. **Finding 4.1**: Trap doesn't explicitly handle SIGHUP (may orphan resources)
4. **Finding 6.2**: macOS SSH relay failure not validated, causes silent git failures
5. **Finding 10.2**: SANDY_HOME environment variable not validated, potential injection vector

### MEDIUM (4)

1. **Finding 3.4**: Node.js JSON fallback not executed on script errors
2. **Finding 6.1**: Windows/WSL2 support unclear, may fail with cryptic errors
3. **Finding 8.2**: Large inline functions make diffs harder to review
4. **Finding 7.2**: Concurrent docker builds waste resources (not a correctness issue)

### LOW (3)

1. **Finding 4.4**: Cleanup not idempotent (fires multiple times safely but wastefully)
2. **Finding 9.2**: Installer doesn't check minimum Docker/Node versions
3. **Finding 9.3**: curl | sh pattern (standard but risky if user doesn't inspect)

### INFO (6)

1. **Finding 2.2**: Inline file generation is appropriate for this use case
2. **Finding 4.3**: Cleanup function is defensive and safe
3. **Finding 6.3**: Platform-specific credential loading is well-designed
4. **Finding 8.1**: Good separation of concerns
5. **Finding 10.1**: Input validation present for SANDY_MODEL
6. **Finding 10.3**: sudo usage is necessary and correct

---

## Recommendations for Pre-Release

### Must-Fix Before Release

1. **Fix Finding 7.1**: Use per-instance bridge names (`br-claude-$$`)
2. **Fix Finding 10.2**: Validate `SANDY_HOME` environment variable
3. **Fix Finding 6.2**: Validate SSH relay startup on macOS

### Should-Fix Before Release

1. **Fix Finding 4.1**: Add explicit signal handlers (`trap cleanup EXIT INT TERM HUP`)
2. **Fix Finding 3.3**: Add error logging to cleanup_network_isolation()
3. **Fix Finding 2.1**: Document rebuild process or add `--rebuild` flag

### Nice-to-Have

1. Add flock-based locking for concurrent execution safety
2. Split large inline functions for better maintainability
3. Add minimum version checks to installer

---

## Architecture Strengths

1. **Ephemeral credentials**: Fresh tmpdir each launch prevents persistence
2. **Hash-based caching**: Fast subsequent launches
3. **Defensive cleanup**: Stale rule removal on startup
4. **Platform awareness**: Separate logic for Linux/macOS
5. **Mnemonic sandbox names**: `project-abc12345` more readable than `abc123...xyz`
6. **Read-only container filesystem**: Strong isolation guarantee
7. **Atomic file updates**: diff-based replacement prevents corruption

---

**End of Architecture Review**
