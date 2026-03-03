## sandy v0.5.0

### What's Changed

**Protected files** — Shell configs (`.bashrc`, `.zshrc`, `.profile`, etc.), `.git/hooks/`, `.claude/commands/`, `.claude/agents/`, `.vscode/`, and `.idea/` are now mounted read-only inside the container. This prevents Claude from injecting shell configs, git hooks, or tampering with Claude command/agent definitions — the most dangerous attack vectors for an AI coding agent. The host filesystem is unaffected.

**Per-project config** — Drop a `.sandy/config` file in any project directory to set environment variables for that project. For example, `SANDY_SSH=agent` for repos that use SSH-based git remotes (Gitea, GitLab, self-hosted). The config is sourced before anything else runs.

**UID/passwd fix for macOS** — When the host UID differs from the container default (1001), sandy now overlays `/etc/passwd` and `/etc/group` with the correct UID so that git, SSH, and other tools that need username resolution work correctly. Fixes "No user exists for uid 501" errors on macOS.

**Container naming** — Containers are now named `sandy-<project>-<hash>` so `docker ps` shows which project each container is running against. Stale containers from unclean exits are automatically cleaned up.

**git-lfs support** — `git-lfs` is now included in the base image. When sandy detects `.gitattributes` with LFS filter rules, it automatically runs `git lfs install` to configure the smudge/clean filters.

**Cairo/Pango/GDK-Pixbuf runtime libs** — Added to the base image for PDF generation tools (synthkit, WeasyPrint, etc.) without requiring per-project Dockerfile customization.

**pip/pip3 wrapper fix** — Fixed a quoting bug where the pip wrapper scripts had variables expanded at container startup instead of at invocation time, causing `ERROR: unknown command ""` on every `pip install`.

**socat preflight check** — Sandy now checks for socat before starting when `SANDY_SSH=agent` is set on macOS, failing early with install instructions instead of silently hanging.

**README improvements** — Restructured to lead with the three-line install-and-run story. Added Prerequisites section listing compatible Docker runtimes (Rancher Desktop, Docker Desktop, Colima, Lima).

**Test suite expanded** — From 12 to 36 tests covering protected files, git-lfs, LFS auto-detection, UID mapping, per-project config, container naming, and pip wrapper correctness.

### Research

Added `claude-code` and `sandbox-runtime` as git submodules under `research/` for ongoing analysis of patterns and capabilities to adopt.
