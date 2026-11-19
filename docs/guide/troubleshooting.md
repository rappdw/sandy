# Troubleshooting

Known problems and their fixes. Part of the [sandy guides](README.md); back to the [project README](../../README.md).

## The build hangs at "Building sandbox image" on a VM (generic CPU model)

**Symptom.** On a QEMU/KVM virtual machine — Proxmox is the common case — the
first launch stops at `[sandy] Building sandbox image (may take a few
minutes)...` and never finishes. The build makes no further progress, and one process
sits at ~90–100% CPU indefinitely, typically
`/home/sandy/.claude/downloads/claude-<version>-linux-x64 install` (or the Grok
Build binary being installed the same way).

**Cause.** Claude Code and Grok Build ship as **native binaries** with an
embedded JavaScript runtime, and the image build runs each one's own installer
(Claude Code's installer ends by executing the downloaded binary's `install`
step). On a VM that uses the hypervisor's **generic CPU model** — `kvm64` or
`qemu64`, which `lscpu` reports as *Common KVM processor* / *QEMU Virtual CPU*
— the guest is offered only the x86-64 baseline feature set: no `sse4_2`,
`popcnt`, `avx` or `avx2`. The runtime then spins in userspace instead of
failing. It is not a network or egress stall, and not cross-architecture
emulation (both sides are x86_64); the same build works in CI and on real
hardware because those expose the full feature set.

**How to tell.** On the VM:

```bash
lscpu | grep 'Model name'                        # "Common KVM processor" / "QEMU Virtual CPU" is the tell
grep -oE 'sse4_2|popcnt|avx2' /proc/cpuinfo | sort -u   # empty, or missing entries, means a generic model
/lib64/ld-linux-x86-64.so.2 --help | grep x86-64-v      # glibc >= 2.33: is x86-64-v2 "supported"?
```

And, to rule out the network: find the spinning process (`ps aux | grep
'downloads/claude'` on the VM — `docker build` steps are ordinary host
processes on Linux) and run `sudo strace -f -p <pid>`. A process in state `R`
making **no syscalls at all** is a pure userspace spin; a network stall would
be blocked in `connect`/`recv`/`poll`.

**Fix.** Give the VM real CPU features — the agent binaries need at least an
**x86-64-v2** feature level:

- **Proxmox**: VM → Hardware → Processors → Type → `host` (or `x86-64-v2-AES`
  / `x86-64-v3` if live migration between different hosts rules out `host`).
- **libvirt / virt-manager**: `<cpu mode='host-passthrough'/>`, or tick "Copy
  host CPU configuration". **Plain QEMU**: `-cpu host`.
- **Cold-boot the VM** — stop it, then start it. A reboot from inside the guest
  keeps the old CPU model; the type only changes on a fresh power cycle.
- Re-check with the `grep` above (the flags should now appear), then run
  `sandy` again. An interrupted build is retried on the next launch; no
  `--rebuild` is needed.

## An agent pane fails with "Missing optional dependency"

**Symptom.** After an image rebuild, an agent pane exits at once with an error
like `Error: Missing optional dependency @openai/codex-linux-arm64`.

**Cause.** Codex and OpenCode ship their real binary as a separate
per-platform npm package. npm publishes the main package first and the
platform packages over the following minutes, and an install in that window
silently skips the platform package that does not exist yet. Before 2.8.0 the
image build did not check that the installed agent runs, so the broken
agent shipped, and no later launch rebuilt it.

**Fix.** `sandy --rebuild`. Since 2.8.0 a build whose agent cannot report its
version fails, so a rebuild during a publish window keeps the existing image
and retries 30 minutes later (see below). An image already broken this way is
rebuilt automatically at its next launch.

## "Skipping the agent image rebuild"

**Symptom.** A launch prints `Skipping the agent image rebuild: The
sandy-claude-code rebuild failed 4 min ago (docker build exit 100); it is
retried in 26 min, or now with sandy --rebuild.` and starts on the existing
image.

**Cause.** An earlier launch tried to rebuild the agent image (an agent update,
or a sandy upgrade that changed the image), the build failed, and sandy kept
the existing image. So that every launch on a bad network does not repeat the
whole failed build, the same rebuild is not tried again for 30 minutes. A
different agent, changed image inputs, or a newer agent release that sandy's
update check can see are not held back, an image that does not exist yet
is always built, and a rebuilt base image is never held back: the agent
image is rebuilt on top of it at its next launch, whichever agent's launch
rebuilt the base. A release the check cannot see (its registry unreachable, or
`SANDY_OFFLINE=1`) waits out the 30 minutes too. If the failed rebuild was for a
new release, a launch that cannot see that release rebuilds at once with what
it does see, and a failure of that build is held back for 30 minutes in turn.

**Fix.** Nothing, if you are happy on the existing image: the rebuild is tried
again automatically once the 30 minutes are up, or sooner once the base image
is rebuilt (for example after a sandy upgrade that changes it).
A successful rebuild clears the hold. To retry at once (say, after
fixing the network), run `sandy --rebuild`.
