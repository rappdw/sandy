# Supply Chain Attack Mitigation

How sandy limits blast radius when a dependency in your AI coding workflow is compromised.

## Background: The LiteLLM Incident (March 2026)

In March 2026, attackers compromised the LiteLLM Python package through a poisoned Trivy GitHub Action. The compromised CI action exfiltrated LiteLLM's PyPI publishing token, allowing the attackers to push malicious versions (1.82.7 and 1.82.8) to PyPI. The attack was sophisticated and multi-staged:

**Stage 1 — Harvest everything.** The payload collected system metadata, SSH keys, `.env` files, shell history, cloud credentials (with full IMDSv2 signing), Kubernetes configs and service account tokens, and cryptocurrency wallet files.

**Stage 2 — Exfiltrate.** Collected data was encrypted with AES-256-CBC and a hardcoded RSA public key, bundled as a tarball, and POSTed to a public HTTPS endpoint (`models.litellm.cloud`).

**Stage 3 — Persist and spread.** A backdoor was installed as a systemd user service polling a C2 server every 5 minutes. If Kubernetes tokens were found, the payload read all secrets across namespaces and deployed privileged pods for host-level persistence.

For the full technical breakdown, see [Snyk's analysis](https://snyk.io/articles/poisoned-security-scanner-backdooring-litellm/).

## The Scenario

Imagine you're using LiteLLM inside sandy to route Claude Code's API traffic through AWS Bedrock instead of Anthropic's first-party API. LiteLLM runs as a dependency inside the container, and you've configured it with Bedrock credentials. One day, `pip install --upgrade litellm` pulls the compromised version.

What happens next depends entirely on the environment the code is running in.

## What Sandy Blocks

### Cloud credential theft via IMDS

The attack's most dangerous capability was querying the cloud Instance Metadata Service (IMDS) at `169.254.169.254` to steal IAM role credentials. On an unprotected EC2 instance, this gives the attacker access to whatever AWS permissions the instance role has — potentially S3 buckets, databases, other services.

Sandy blocks the entire `169.254.0.0/16` range via iptables rules in the `DOCKER-USER` chain. The IMDS query never leaves the container.

### Kubernetes lateral movement

The attack read Kubernetes service account tokens and used them to enumerate secrets across namespaces and deploy privileged pods. Sandy containers have no access to `~/.kube/`, no service account tokens are mounted, and no Kubernetes tooling is present. There is nothing to exploit.

### SSH key theft

The payload harvested SSH private keys from `~/.ssh/`. In sandy's default configuration (`SANDY_SSH=token`), no SSH keys are mounted into the container. Git authentication uses a scoped GitHub CLI token over HTTPS instead. Even in the opt-in `SANDY_SSH=agent` mode, only the agent socket is forwarded — private key files never enter the container.

### Host filesystem harvesting

The attack collected `.env` files, shell history, and cryptocurrency wallets from the user's home directory. Sandy containers cannot see the host home directory. The container's `/home/claude` is a 2GB tmpfs that exists only for the duration of the session. The only host paths accessible are the mounted workspace directory and the per-project sandbox volumes.

### Persistence via systemd

The attack installed a backdoor at `~/.config/sysmon/sysmon.py` and registered it as a systemd user service. Sandy's container has no systemd, no cron, no init system of any kind. The root filesystem is read-only (`--read-only`). Even if the malicious code writes to the tmpfs home directory, everything is destroyed when the container exits. There is no mechanism for background processes to survive a session.

### Privilege escalation

The container runs with `--cap-drop ALL` and `--security-opt no-new-privileges:true`. Only the minimum capabilities needed for file ownership operations (`SETUID`, `SETGID`, `CHOWN`, `DAC_OVERRIDE`, `FOWNER`) are added back. The attack cannot escalate privileges, load kernel modules, or access raw sockets.

### LAN lateral movement

Sandy blocks all RFC 1918 ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), link-local (`169.254.0.0/16`), and CGNAT/Tailscale (`100.64.0.0/10`). The container cannot reach other machines on your network, NAS devices, internal APIs, or VPN endpoints.

## What Sandy Does Not Block

### Exfiltration to public endpoints

The LiteLLM payload POSTed stolen data to `https://models.litellm.cloud/` — a public HTTPS endpoint. Sandy allows outbound internet access by design (Claude Code needs it for the Anthropic API, GitHub, package registries, etc.). A compromised dependency can exfiltrate data to any public URL.

This is the fundamental trade-off: AI coding agents need internet access to function, and that same access can be used for exfiltration.

### Credentials that must be in the container

If LiteLLM is routing to Bedrock, the container must have AWS credentials (access key, secret key, or session token). These are exposed to any code running in the container, including compromised dependencies. Similarly, `ANTHROPIC_API_KEY` or `GIT_TOKEN` are available in the container's environment when configured.

### Workspace source code

The workspace directory is bind-mounted read-write. Any code, configuration, or secrets stored in the project directory are accessible to the compromised dependency.

## Defense in Depth Summary

| Attack vector | Without sandy | With sandy |
|---|---|---|
| IMDS credential theft | Full IAM role access | Blocked (`169.254.0.0/16` dropped) |
| Kubernetes secrets | All namespaces readable | No k8s access exists |
| SSH private keys | All keys in `~/.ssh/` | Not mounted (default) |
| Host home directory | Full read access | Not accessible (tmpfs home) |
| Shell history / `.env` files | Readable from host filesystem | Only workspace `.env` visible |
| Systemd persistence | Backdoor survives reboot | No systemd, tmpfs wiped on exit |
| LAN lateral movement | Full network access | All private ranges blocked |
| C2 polling loop | Runs indefinitely | Dies with container session |
| Privilege escalation | Possible via setuid binaries | `no-new-privileges`, capabilities dropped |
| Exfiltration to public internet | Possible | **Still possible** |
| In-container credentials | Possible | **Still possible** |

## Takeaways

Sandy converts what would be a complete system compromise into a contained incident limited to the current session's workspace and explicitly provided credentials. The attack loses its most dangerous capabilities: cloud credential theft, lateral movement, and persistence. What remains — exfiltration of in-container data to public endpoints — is a harder problem that would require egress filtering (allowlisting specific API endpoints), which imposes significant usability trade-offs.

The broader lesson: supply chain attacks are inevitable in ecosystems with deep dependency trees. The question isn't whether a dependency will be compromised, but what the blast radius will be when it happens. Sandboxing tools like sandy don't eliminate the risk, but they dramatically reduce the blast radius from "full infrastructure compromise" to "one session's worth of accessible data."
