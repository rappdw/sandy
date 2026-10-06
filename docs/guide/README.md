# sandy documentation

The [project README](../../README.md) covers what sandy is, why you'd use it, and how to get running. These guides hold the detail.

| Guide | What's in it |
|---|---|
| [Configuration](configuration.md) | Every config key and flag, `.sandy/config` and `.sandy/.secrets`, and which settings a repository may change without asking you |
| [Agents and credentials](agents.md) | Claude, Gemini, Codex, OpenCode and Grok: how each signs in, multi-agent sessions, claude.ai connectors, Console profiles, headless servers |
| [Daemon mode and maintenance](daemon.md) | `--start`/`--attach`/`--stop`, remote access, `--update-sessions`, `--exec` |
| [Network isolation](network.md) | The egress proxy and its three postures, macOS and Linux specifics, checking it works |
| [What's in the box](environment.md) | Toolchains, persistent packages, `.venv`, skill packs, GPU, `.sandy/Dockerfile` |
| [Features](features.md) | Feature manifests: per-sandbox directories, mounts, supervised entries, re-provisioning |
| [Notifications and channels](channels.md) | Terminal notifications; Telegram and Discord |
| [Security notes](security.md) | Protected files and directories; links to the threat model |
| [Troubleshooting](troubleshooting.md) | Known problems and fixes |
| [Upgrading to 2.0](upgrading-to-2.0.md) | Migrating sandboxes created by sandy 1.x |

For the implementation-level contract, see [SPECIFICATION.md](../../SPECIFICATION.md) and, for the machine-readable output, [SPEC_INTROSPECTION.md](../../SPEC_INTROSPECTION.md). The [threat model](../security/THREAT_MODEL.md) states what sandy defends against and what it does not.
