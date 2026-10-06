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
