[![License: MIT](https://img.shields.io/github/license/rappdw/sandy)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/rappdw/sandy)](https://github.com/rappdw/sandy/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)]()

# sandy — Claude's isolated sibling

Run Claude Code with `--dangerously-skip-permissions` in a Docker container with proper isolation:

- **Filesystem**: Read/write access limited to the mounted working directory only
- **Network**: Public internet access only — all LAN/private networks are blocked
- **Resources**: Capped CPU and memory (auto-detected from host)
- **Security**: Non-root user, read-only root filesystem, no privilege escalation
- **Per-project sandboxes**: Isolated `~/.claude` per working directory

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash
```

Or install locally from a clone:

```bash
LOCAL_INSTALL=./sandy ./install.sh
```

## Quick Start

```bash
# cd into whatever project you want Claude to work on
cd /path/to/your/project

# Start an interactive session
sandy

# Or run with a one-shot prompt
sandy -p "Review the code in src/ for security issues"
```

No `ANTHROPIC_API_KEY` required if using Claude paid account (Pro/Max) (OAuth) — credentials are seeded from docker host (if present) on first run.

## Configuration

### Model selection

```bash
SANDY_MODEL=claude-sonnet-4-5-20250929 sandy
```

Defaults to `claude-opus-4-6` if not set.

### API key (non-OAuth)

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
sandy
```

## How Network Isolation Works

### macOS (Docker Desktop)
Docker Desktop runs containers inside a lightweight Linux VM. Containers **cannot directly access your Mac's LAN** by default — they can only reach the internet through Docker's NAT. This gives you LAN isolation out of the box.

### Linux
Sandy automatically inserts `iptables` rules into the `DOCKER-USER` chain that block all RFC 1918 traffic from the container's bridge interface:

| Range | What it blocks |
|---|---|
| `10.0.0.0/8` | Home/office LAN, VPNs |
| `172.16.0.0/12` | Docker internals, some LANs |
| `192.168.0.0/16` | Home/office LAN |
| `169.254.0.0/16` | Link-local |
| `100.64.0.0/10` | CGNAT, Tailscale |

Rules are automatically cleaned up when sandy exits. Stale rules from a previous unclean exit are cleaned up on startup. If `iptables` is not accessible, sandy warns that LAN isolation is not active.

## Verifying Isolation

From inside the container, you can verify:

```bash
# Should FAIL — LAN is blocked
curl -m 5 http://192.168.1.1

# Should SUCCEED — public internet works
curl -m 5 https://api.anthropic.com
```

## Security Notes

- The container runs as a non-root user (`claude`, UID 1001)
- The root filesystem is read-only (`/tmp` and `/home/claude` are tmpfs)
- `no-new-privileges` prevents privilege escalation
- Credentials are seeded into per-project sandboxes, not shared across projects
- The working directory is bind-mounted read/write — Claude can modify your files there (that's the point)

https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference+user%3Asessions%3Aclaude_code+user%3Amcp_servers&code_challenge=C4PBbCAG07gHP4W3AyS9JKIDLWvW5WGP9F-lAR7zQ2k&code_challenge_method=S256&state=Q8WKME9eT_mlNNhPFG1HJALA6LkGXB0VyjZaGvfZmKQ