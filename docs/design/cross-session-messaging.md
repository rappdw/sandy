# Design: cross-session agent messaging over the handoff substrate

**For:** #132 (cross-workspace session handoff) — this is #132's relay layer, specified.
**Status:** design; **nothing below is built**. Layer 1 (the mailbox pair) ships in `1.7.0`; Layers 2–3 are unbuilt and gated on `SANDY_HANDOFF_PEERS` (privileged, unshipped).
**Targets:** sandy `main` @ `1.9.1-dev`. Every addition here is additive — `schema_version` stays `1`, `SANDY_SANDBOX_MIN_COMPAT` does not move.
**Verified against:** Claude Code `2.1.250` (socket mechanics, address grammar, env vars, the injection recipe, `file_attachments`), and its `2.1.166` changelog entry (relayed-message authority). Facts attributed to the binary below were read out of that build; state them as established.

Each claim about Claude Code's messaging channel was confirmed against the installed binary. State them as facts, not conjecture — the whole point of this document is that the far side is *known*, not assumed.

---

## 1. Problem

Claude Code shipped cross-session messaging (`SendMessage` / `ListAgents`) in v2.1.224. It is **same-host-only by construction**: the transport is a Unix domain socket, and a socket cannot cross a machine boundary. Two sandy containers on two different hosts can never reach each other through it. #132 evaluated it and **refuted it as a substrate** for exactly this reason — and that refutation is correct *as far as it goes*.

It does not go far enough. "UDS can't cross machines" refutes UDS **as a transport**. It says nothing about UDS **as a delivery adapter** — the last hop that turns an already-delivered message into a *live in-session turn*. Those are two different jobs, and #132's own architecture already separates them: the handoff relay is the thing that *moves* a message; whatever initiates a turn at the far end is a *delivery* concern layered on top.

Once you separate transport from delivery, the picture inverts:

- The **handoff relay is the transport**, and because it just moves a message plus its attachments, it is transport-agnostic: same-host is a filesystem copy; **cross-host is SSH, HTTP, or a message bus.** This is the layer that makes messaging work across machines — which pure UDS never can.
- **UDS messaging is the local last-mile delivery adapter**: on the receiving host, after the relay has landed the message, `docker exec … socat` into the receiver's *own* socket turns that message into a real user turn, with attachments. The socket never leaves its host; it is only ever the final hop.

So cross-session messaging is **not a separate feature to bolt on**. It is the highest-fidelity *delivery adapter* for the handoff relay — and the relay is what generalizes it past the same-host wall Claude Code's own implementation hits.

This document specifies that decomposition precisely enough to build the relay from it.

---

## 2. The verified mechanism, both sides

### 2.1 Claude Code UDS cross-session messaging (confirmed against 2.1.250)

**Transport.** A Unix domain socket at `/tmp/cc-socks/<pid>.sock`, mode `srw-------`. The binary's own regex constrains the accepted socket-directory paths:

```
^/tmp/cc-socks(?:-N)?$
^/private/tmp/cc-socks(?:-N)?$
^/run/user/<uid>/cc-socks$
```

(plus a termux path). Peer **discovery is by scanning that shared socket directory** — every live session in the same directory is a candidate peer.

**Two environment variables** carry the addressing and the gate:

| Var | Meaning |
|---|---|
| `CLAUDE_CODE_MESSAGING_SOCKET` | the socket path |
| `CLAUDE_CODE_MESSAGING_TOKEN`  | the auth token — **the real gate** |

**The binary ships the injection recipe itself.** Two newline-delimited JSON frames over the socket — an `auth` frame first, then a `user` frame:

```sh
{ echo '{"type":"auth","token":"'"$CLAUDE_CODE_MESSAGING_TOKEN"'"}';
  echo '{"type":"user","message":{"role":"user","content":"hello"}}';
} | socat - UNIX-CONNECT:"$CLAUDE_CODE_MESSAGING_SOCKET"
```

The `user` frame is **routed into the session's queue as a real turn** — the same queue an operator's typed message lands in. This is the fidelity we want: not a scrollback annotation the agent might ignore, but an actual turn.

**Address grammar** — load-bearing, because the binary *anticipates non-local peers*:

```
^(?:uds|bridge|did):.{1,200}$
```

Three transport types are namespaced from day one:

- `uds:` — a local socket (what §2's last mile injects into).
- **`bridge:`** — an explicit relay/bridge peer. This is the address type a v2 send-side capture presents itself as (§6.2).
- **`did:`** — a decentralized identifier for cross-machine identity. This maps directly onto sandy's existing host/session identity (§7.3).

The binary having `bridge:` and `did:` in its address grammar is the strongest possible signal that a relay in front of the socket is a *sanctioned* shape, not a hack around one.

**Attachments transfer.** `file_attachments` ride in the message envelope; on receive the binary calls `materializeLocalPeerFiles` / `injectPeerFilePrefix` to write them into the receiver's filesystem and prefix them into context. This maps one-to-one onto handoff's file-moving purpose: a handoff is fundamentally *"here is a document, act on it,"* and attachments are how the document arrives live.

**Security model, in the binary's own priority order:**

1. **Token auth is the real gate** (`CLAUDE_CODE_MESSAGING_TOKEN`). Everything else is defense-in-depth around it.
2. `peerDirOwnerUids` — the socket directory must be owned by an expected uid.
3. `verifiedPeerProcStart` — reads the peer's `/proc` to check its start time, but **degrades gracefully** to "no peer pid" when it can't. It is therefore **not** a hard blocker across PID namespaces — which matters, because a `docker exec` into a container is in a different PID namespace than the host relay.
4. A `session_id` match and a `selfSent` guard.

**Relayed peer messages carry no operator authority** (changelog, 2.1.166): *"messages relayed via `SendMessage` from other Claude sessions no longer carry user authority — receivers refuse relayed permission requests, and auto mode blocks them."* This is decisive for the security story (§7.4): a UDS-delivered peer message initiates a turn but **cannot answer a permission dialog or exercise operator authority** — the exact hazard #132 flags for `send-keys`, closed at the protocol level by the binary itself.

### 2.2 The handoff substrate (#132, shipped as substrate in 1.7.0)

```
$SANDBOX_DIR/handoff/
  outbox/  → /home/claude/.handoff/outbox   (rw)    the agent stages outgoing files here
  inbox/   → /home/claude/.handoff/inbox    (:ro)   only the relay writes here
```

- Enabled by `SANDY_HANDOFF_DIRS=1` (passive-safe) **or** an operator-side `$SANDBOX_DIR/.handoff-enabled` marker (per-machine; a cloned repo cannot carry it). The directories are created on **every** launch as of 1.7.0, so *presence carries no information* — the flag/marker gate the **mount**, not the directory.
- **The `:ro` inbox is the load-bearing boundary.** The agent runs as the host uid (`sandy:~8948` → `exec gosu`), so file modes are not a boundary anywhere in sandy — only mount flags are. Against a plain rw mount an in-container `chmod` would succeed; against `:ro` it returns `EROFS`, verified live (#139). This is what keeps the agent from writing, or tampering with, its own inbox.
- `SANDY_HANDOFF_PEERS` is the **unshipped, privileged-tier** trust edge — where *"actually move files to peer X"* is authorized. **Today nothing moves files.** The substrate is inert.
- **Known residual (carried forward, must be handled here):** `outbox/` persists across sessions, so a committed passive `SANDY_HANDOFF_DIRS=1` lets a repo stage content *before* an operator ever approves a peer. The relay **must quarantine or ignore outbox content predating the first peer approval** (§7.2).

### 2.3 The proven precedent — sandy's channel relay (`sandy:5899`+)

Sandy already runs a host-side relay that turns an external event into an in-session turn. `generate_channel_relay()` writes `$SANDY_HOME/channel-relay.sh`, spawned as a child of the launcher/supervisor and killed in `cleanup()`. It long-polls Telegram and injects each message into the container's tmux session (`sandy:5934`):

```sh
docker exec -u "$(id -u)" "$SANDY_CONTAINER_NAME" \
    tmux send-keys -t "sandy.${TARGET_PANE}" "$text" Enter
```

Stateless, agent-agnostic, daemon-safe (it is just `docker exec` against a container name), zero upstream dependency, already in production.

**The cross-session bridge is the same architecture**, with two substitutions:

| | channel relay (shipped) | handoff relay (this doc) |
|---|---|---|
| **source** | Telegram long-poll | a peer session's `outbox/` |
| **injection** | `docker exec … tmux send-keys` | `docker exec … socat - UNIX-CONNECT:$CLAUDE_CODE_MESSAGING_SOCKET` |

Both run **`docker exec` into the target container** — the same host→container direction. The socat variant is strictly better on the receive side (§7.4), and it needs no secret extraction: because the socat runs *inside* the target container, `$CLAUDE_CODE_MESSAGING_SOCKET` and `$CLAUDE_CODE_MESSAGING_TOKEN` are already in that container's environment (§6.3).

> **This is not the anti-roadmap's rejected "live RPC pipe."** `POST_1.0_IDEAS.md:133` rejects *the agent writing to a mounted socket and a host listener acting mid-session* — an **agent→host** inbound control channel. This design is the opposite direction: the **host reaches into the container** to deliver a message, exactly as the shipped channel relay already does. The agent never gains a channel to the host; it stages a file in a rw mount and the host, at its own discretion behind a privileged gate, moves it.

---

## 3. The three-layer decomposition

Transport is separated from delivery. Each layer is independently useful and independently gated.

```
┌─ Layer 1 ── QUEUE + TRUST BOUNDARY ────────────────────────────  SHIPPED (1.7.0)
│  $SANDBOX_DIR/handoff/{outbox(rw), inbox(:ro)}
│  Durable, transport-agnostic message queue. The :ro inbox is the boundary.
│
├─ Layer 2 ── TRANSPORT (the relay) ─────────────────────────────  UNBUILT · SANDY_HANDOFF_PEERS (privileged)
│  Host-side child of the launcher/supervisor. Moves a message + attachments.
│  Because it moves bytes, it is transport-agnostic:
│    • same-host  = local filesystem copy into the peer's inbox
│    • cross-host = SSH / HTTP / message bus to the peer's host relay
│  This is the layer that makes messaging work across machines.
│
└─ Layer 3 ── LOCAL LAST-MILE DELIVERY ADAPTER (UDS) ────────────  UNBUILT · optional · Claude-only
   On the RECEIVING host, after Layer 2 has landed the message:
     docker exec <B-container> socat - UNIX-CONNECT:$CLAUDE_CODE_MESSAGING_SOCKET
   turns the delivered message into a live in-session turn, with attachments.
   The socket never leaves its host. Degrades to "the file sits in the :ro inbox."
```

**Layer 1 — the mailbox = the durable, transport-agnostic message queue and the trust boundary.** Already shipped. `outbox/` is where a sender stages; `inbox/` (`:ro`) is where a receiver reads and only the relay may write. Nothing about this layer knows or cares whether the peer is on the same host.

**Layer 2 — the relay = the transport.** A host-side background process, generated and lifecycle-managed exactly like `channel-relay.sh` (spawned as a launcher/supervisor child, killed in `cleanup()`). It reads a sender's `outbox/`, validates and secret-scans the message, resolves the destination peer, and moves the message to that peer's `inbox/`. **Because its whole job is to move a message, the move is pluggable:** a same-host peer is a filesystem copy; a cross-host peer is an SSH/HTTP/bus hop to the peer's own host relay, which performs the local copy on the far side. The privileged `SANDY_HANDOFF_PEERS` trust edge lives on this layer, because this is the layer that actually crosses the isolation boundary.

**Layer 3 — UDS messaging = the local last-mile delivery adapter.** *Optional.* After Layer 2 has landed a message in receiver B's `inbox/` on B's host, an adapter on B's host injects it into B's running Claude session as a live turn (with attachments) via `docker exec … socat`. This is a fidelity upgrade over B polling its own inbox: the message arrives *now*, as a real turn, queued in order with any others, and — per 2.1.166 — with peer provenance that forbids it from answering a permission dialog. If B is not a Claude session, or is running a binary without the socket, or has no live session, **the message simply stays in the `:ro` inbox** and Layer 1+2 have already done a complete job.

**The load-bearing consequence: cross-host works because UDS is only ever the receive-side adapter.** A socket cannot span H1→H2; the *relay* spans H1→H2. UDS is the last hop on H2 and nothing more. Handoff makes messaging **general** (any transport, any distance); UDS makes the far-side delivery **live** (a turn, not a poll) instead of the inbox-file baseline.

---

## 4. Cross-host data flow

The headline path — a message that originates on one machine and becomes a live turn on another:

```
   HOST H1 (sender)                              HOST H2 (receiver)
   ════════════════                              ══════════════════

  ┌───────────────────┐
  │  A's container    │
  │  agent writes     │
  │  handoff_x.md ────┼──▶ ~/.handoff/outbox            ┌────────────────────┐
  └───────────────────┘        (rw mount)               │   B's container    │
                                    │                    │                    │
                                    ▼                    │                    │
                          ┌──────────────────┐           │                    │
                          │  H1 relay        │           │                    │
                          │  (host child)    │           │                    │
                          │  • validate      │           │                    │
                          │  • secret-scan   │           │                    │
                          │  • resolve peer  │           │                    │
                          │    B  →  did:… @ H2           │                    │
                          └────────┬─────────┘           │                    │
                                   │                      │                    │
              transport (Layer 2): │  ssh / https / bus   │                    │
              the ONLY cross-host  │                      │                    │
              hop in the design    ▼                      │                    │
                          ┌──────────────────┐            │                    │
                          │  H2 relay        │            │                    │
                          │  (host child)    │            │                    │
                          │  write body +    │            │                    │
                          │  manifest  ──────┼──▶ B's $SANDBOX_DIR/handoff/inbox
                          │                  │            │      (:ro mount) ──┼─▶ readable
                          │  [Layer 3, opt]  │            │                    │
                          │  docker exec B \ │            │                    │
                          │   socat - UNIX-  │            │                    │
                          │   CONNECT:$SOCK ─┼────────────┼─▶ auth + user{     │
                          └──────────────────┘            │      file_attach}  │
                                                          │        │           │
                                                          │        ▼           │
                                                          │  live turn +       │
                                                          │  attachments in    │
                                                          │  B's Claude queue  │
                                                          └────────────────────┘

  Note: the socket on H2 is dialed only by H2's own relay, in-container.
  It never appears on the wire. The wire hop is entirely Layer 2's.
```

Same-host is the degenerate case: H1 == H2, the "transport (Layer 2)" hop is a local filesystem copy, and everything else is identical.

---

## 5. The relay, concretely (buildable spec)

Enough to implement Layer 2. Follows #132's mechanism and the `channel-relay.sh` precedent.

**Lifecycle.** `generate_handoff_relay()` writes `$SANDY_HOME/handoff-relay.sh`, mirroring `generate_channel_relay()` (`sandy:5899`). It is spawned as a background child of the launcher (or, under `--start`, the supervisor) only when `SANDY_HANDOFF_PEERS` is non-empty and approved, and is reaped in `cleanup()`. It holds no lock and manages no state beyond files under `$SANDBOX_DIR`.

**Consent — proven by the receiver's own launch.** At B's launch, B's *resolved* config writes `$SANDBOX_DIR_B/handoff/peers.json` (mounted `:ro` into B). The relay reads *that*; it **never re-parses another workspace's `.sandy/config`**, which would evaluate a privileged key without its approval prompt. Consequence, and it is the right one: **a workspace that has never launched with handoff enabled cannot receive a handoff.** Both ends must list each other; **no wildcards in v1**.

```jsonc
// $SANDBOX_DIR/handoff/peers.json  (:ro in-container; written by this side's launch)
{
  "schema": 1,
  "self":  { "workspace": "/Users/dr/dev/sandy",    "host_id": "h1", "did": "did:sandy:h1:sandy-a1b2c3d4" },
  "peers": [
    { "workspace": "/Users/dr/dev/sandy-ui", "host_id": "h2",
      "did": "did:sandy:h2:sandy-ui-9f8e7d6c", "transport": "ssh://h2" }
  ]
}
```

**Per-iteration loop (~1 s poll), per staged `outbox/handoff_<topic>.md`:**

1. **Validate** name `^handoff_[a-z0-9][a-z0-9._-]{0,63}\.md$`, `.md` only, ≤256 KiB, UTF-8, not a symlink, frontmatter well-formed, `expires_at` not past.
2. **Secret-scan** the body (best-effort, documented as discipline not guarantee): reject `sk-ant-`, `gh[pousr]_`, `AKIA[0-9A-Z]{16}`, `xox[baprs]-`, `AIza…`, PEM `BEGIN … PRIVATE KEY`; write a rejection note into the sender's own inbox.
3. **Quarantine gate** (§7.2): refuse any body whose mtime predates this pair's first-approval timestamp.
4. **Resolve** the frontmatter `to:` (a canonical workspace path) to the peer entry in `peers.json`. Same-host targets resolve to `SANDBOX_NAME` via the exact `--reset-sandbox` recipe (`sandy:~2382`: `pwd -P` → `basename-<8-char-sha256>`) — **never guess the hash** (#16's lesson).
5. **Both-ends consent:** target must be in this side's `peers`, and this side must be in the target's `peers.json`.
6. **Hop / quota / dedupe:** `hop` starts at 1, caps at 2 (A→B→A); over cap → deliver, no turn, warn both sides. Per-session quota (10), min inter-delivery interval (30 s), per-`(sender, receiver, sha256)` dedupe. A handback never auto-generates a further handoff.
7. **Deliver (Layer 2 transport):**
   - **same-host:** atomic write of body + manifest into the target's `$SANDBOX_DIR/handoff/inbox`.
   - **cross-host:** ship body + manifest to the peer's host relay over the `transport` (`ssh://…`, `https://…`, or a bus); the far relay performs the atomic local write. The wire transport carries its own auth (SSH keys / mTLS); it delivers **data into a `:ro` inbox** and grants no further reach — it cannot weaken the receiving sandbox's boundary.
8. **Archive** the sender's copy relay-side (see §8: no `archive/` mount; the relay uses `outbox/processed/`).
9. **Deliver-live (Layer 3, optional, receive-side):** if the target is a live Claude session with a socket, inject (§6.3). Otherwise stop — the file is in the `:ro` inbox.

**Manifest** (host-written, lands beside the body in the `:ro` inbox):

```jsonc
{ "schema": 1, "topic": "autoupdate", "kind": "handoff", "hop": 1, "in_reply_to": null,
  "from_workspace": "/Users/dr/dev/sandy", "from_sandbox": "sandy-a1b2c3d4",
  "from_host_id": "h1", "from_did": "did:sandy:h1:sandy-a1b2c3d4",
  "from_session_nonce": "…", "from_sandy_version": "1.9.1",
  "sha256": "…", "bytes": 4213,
  "created_at": "…", "expires_at": "…", "delivered_at": "…", "delivered_by": "handoff-relay" }
```

`from_session_nonce` is copied by the relay from the host-side original of the sender's `sandy-session.json` (`sandy:~11131`), so a handoff ties to a specific *launch* — and to an externally-chosen value when the operator pinned `SANDY_SESSION_NONCE`. Because the inbox is `:ro`, the receiver cannot manufacture one. **Honest limit:** the nonce proves which launch produced the mailbox, not which process inside the sender's container wrote the bytes.

---

## 6. Phases

### 6.1 v1 — outbox send + relay + inbox delivery (+ optional UDS live injection on receive)

The agent stages a message file in `outbox/`; the relay routes it (same-host copy or cross-host hop); the far side writes it into the `:ro` inbox **and optionally** injects it live via UDS.

- **Claude-agnostic on the send side.** Staging a `.md` file in `outbox/` is a filesystem write any agent (codex/gemini/opencode/grok) can do; a thin `sandy-handoff` helper (precedent: `sandy-ss-paths`) provides `send`/`list`/`read` from any agent's bash escape.
- **The live-injection upgrade is Claude-only on receive.** codex/gemini/opencode/grok receivers get the inbox file and nothing more; that is a complete delivery. Only a Claude receiver gets the UDS last mile.
- This is the minimal shippable slice and it matches a real consumer's need exactly (§8): delivery is complete without turn initiation.

### 6.2 v2 — UDS-native capture on the send side

The agent uses **Claude Code's own messaging UX** (`SendMessage`) addressed to a `bridge:` or `did:` peer. The local relay **presents itself as that bridge peer** — a discoverable entry in the socket directory advertising a `bridge:` address — captures the emission on the socket, and routes it through Layers 2–3 exactly as v1 does.

The payoff is **one messaging UX, local-vs-remote transparent**: the operator (or agent) addresses a peer the same way whether it is a pane away or a continent away, and the relay decides the transport underneath. This uses the `bridge:` address type the binary **already has** (§2.1). It is tighter than v1's file-staging, and permanently **Claude-only** — it depends on the socket protocol on the *send* side too.

v1 and v2 are not either/or: v1's file-staging remains the agent-agnostic floor; v2 is a Claude-only ergonomic capture layer over the same relay.

### 6.3 The env-pin that makes the last mile secret-free (both phases)

For `docker exec <B> socat …` to work without extracting a secret to the host, `$CLAUDE_CODE_MESSAGING_SOCKET` and `$CLAUDE_CODE_MESSAGING_TOKEN` must be in **B's container environment** — where both Claude Code (to serve the socket) and the relay's `docker exec` (to dial it) will see identical values. `docker exec` inherits the container's configured env, so sandy **pins both at launch**, exactly as it already pins `SANDY_EGRESS_MODE` and mints the per-launch `session_nonce`:

- `CLAUDE_CODE_MESSAGING_SOCKET` → a fixed path under an accepted directory (`/run/user/<uid>/cc-socks` on Linux, `/tmp/cc-socks` otherwise — both in the binary's regex).
- `CLAUDE_CODE_MESSAGING_TOKEN` → a **per-launch** token minted with the same portable chain as the nonce (`openssl rand`, `/dev/urandom` fallback). It is a **per-launch capability for the local socket only**, not a durable credential — it dies with the session and grants nothing off-host.

The relay's injection then reads those two values out of the container it is exec-ing into:

```sh
docker exec -u "$(id -u)" "sandy-<B>" sh -c '
  { printf "%s\n" "{\"type\":\"auth\",\"token\":\"$CLAUDE_CODE_MESSAGING_TOKEN\"}";
    printf "%s\n" "$FRAME"; } | socat - UNIX-CONNECT:"$CLAUDE_CODE_MESSAGING_SOCKET"'
```

where `$FRAME` is the `{"type":"user","message":{…, "file_attachments":[…]}}` envelope built host-side from the delivered body + manifest. No socket on the host, no token on the wire, no extraction.

---

## 7. Trust model and residuals

### 7.1 The edge stays privileged

Everything that *moves a message* stays behind `SANDY_HANDOFF_PEERS` — **privileged tier**. A committed workspace `.sandy/config` can *declare intent* (list a peer) but cannot *grant the edge*: setting the key from a passive source triggers the standard per-workspace approval prompt, and headless/non-TTY **drops it** (as with `SANDY_EXTRA_ENV` / `SANDY_AGENT_ARGS`). This is the same boundary handoff already chose — *a repo declares intent, an operator grants the edge* — and the same layering as `SANDY_CHANNELS` (passive) vs. `TELEGRAM_BOT_TOKEN` (privileged). The approval gate is **mandatory, not optional**: this is real cross-project (and cross-host) communication, which is precisely the boundary sandy exists to draw.

### 7.2 The `:ro` inbox, and the pre-approval quarantine residual

Only the relay writes the inbox; the mount flag enforces it above the permission check. The carried-forward residual: `outbox/` persists across sessions, so a repo could stage content before any peer approval. **The relay must quarantine or ignore outbox content predating the first peer approval** (§5 step 3) — record the pair's first-approval timestamp and refuse any older body. Until then, the operator remedy is `sandy --reset-sandbox`, which destroys `handoff/` while preserving the `.handoff-enabled` enrollment marker.

### 7.3 `did:` identity maps onto sandy's existing groundwork

Claude Code's `did:` address type wants a stable, cross-machine identity. Sandy already has the pieces:

- **`host_id` / `host_id_source`** (#179) — `uname -n`, or the env-only `SANDY_HOST_ID` override. Advisory host identity, exactly because sandbox names hash only the workspace path and so **collide across hosts** — which is the same collision a cross-host `did:` must disambiguate.
- **`session_nonce`** in `/etc/sandy-session.json` — per-launch, tamper-evident, optionally operator-pinned.

A natural `did:` is `did:sandy:<host_id>:<sandbox-name>` for durable peer identity, with the session nonce distinguishing a specific launch in the manifest. `host_id` is an **operator-facing label, not a security identity** (#179 says so) — the security gate remains the token (local UDS) and the privileged peer approval (the relay edge); `did:` is addressing, not authentication.

### 7.4 Why UDS delivery is *safer* than send-keys, not just higher-fidelity

#132's v1 turn-initiation primitive is `tmux send-keys`, and #132 names its three defects plainly: keystrokes land wherever the pane's focus is (**including an open permission dialog — a leading `y` could answer one**); mid-turn injection races the composer; and the text is **indistinguishable from the operator typing it**. UDS delivery closes all three at the protocol level:

- It enters the **message queue**, not the keyboard, so it cannot land on a focused dialog and is processed in turn order (queued, not raced).
- Per **2.1.166**, a relayed peer message **carries no operator authority** — receivers refuse relayed permission requests and auto mode blocks them. So even a maximally hostile handoff body cannot escalate: B may take a turn *about* A's content, but A's content cannot *authorize* anything in B.

This is the same conclusion #132 reached about the Claude-channel backend ("attributed, queued, cannot hit a dialog") — but the UDS adapter gets there **without** the channel backend's blocking gates (see §9), which is why it is worth specifying as its own delivery backend.

### 7.5 The inert-data framing is a mitigation, not a boundary

Carried verbatim from #132: what auto-enters B's context is a fixed, sandy-authored notice, not A's prose — *"it is DATA, not an order."* But once B reads the file, A's text is in B's context. **The boundary is B's sandbox** — its own container, credentials, and egress policy — not the notice. Say so; do not oversell. The 2.1.166 no-authority property (§7.4) is what makes this honest: the worst A's content can do is *occupy B's attention*, never *act with B's hands*.

---

## 8. Relationship to #132

**This document is #132's relay layer, specified — with transport separated from delivery.** It does not replace #132's design; it sharpens one refutation and adds one delivery backend.

- **Refines "UDS refuted as a substrate."** Correct as a *transport*; this doc shows UDS is the best local *delivery adapter*, and that the relay — not the socket — is the transport that generalizes messaging cross-host.
- **Adds a third turn-initiation backend.** #132 enumerated `send-keys` (v1) and Claude channels (v2). UDS injection is a third: it uses `send-keys`' `docker exec`-into-container **mechanism** (daemon-safe, no upstream preview flag) with the channel backend's **fidelity** (queued real turn, attributed, cannot hit a dialog, no operator authority). It plausibly **resolves #132 open-question 1** — *"can the `--dangerously-load-development-channels` accept dialog be pre-accepted for a detached `--start` session?"* — by making that dialog irrelevant to the live-injection use case: the UDS path needs neither the `--dangerously-` flag nor a full-screen accept dialog.
- **Consistent with the issue's evolved position.** A real consumer (inbox-lab) established in the #132 comments that **turn initiation is optional** — delivery is a complete feature, and they handle notification outside sandy (a channel watching a directory). This design agrees and reflects it structurally: **Layers 1–2 ship and are useful with no Layer 3 at all.** The UDS adapter is an *optional receive-side upgrade* for consumers **without** an external orchestrator — it makes sandy's own delivery live without requiring the channel backend's gates. Both coexist behind the same delivered `:ro` inbox file.
- **Adopts the `archive/` resolution.** Per the same consumer, there is **no `archive/` mount**; the relay archives on the host side under `outbox/processed/`. No third mount, no new mode decision.
- **Inherits #132's open constraints:** the pane-index misroute on 4-agent combos (#65) applies to any pane-addressed *send-keys* fallback (not to UDS, which is queue-addressed); `send-keys` remains the agent-agnostic floor for non-Claude receivers.

---

## 9. Honest constraints

State these; do not gloss them.

- **UDS is same-host-only.** A socket cannot cross a machine boundary — full stop. **All** cross-host capability lives in the Layer-2 relay. If the relay is same-host-only in a given deployment, so is the whole feature; the cross-host transport is real work (SSH/HTTP/bus with its own auth) and is specified here only in shape, not wire detail.
- **The live last mile is Claude-only and version-coupled.** It depends on this exact socket protocol, env-var names, address grammar, and the 2.1.166 authority behavior. A different agent, or a Claude build without the socket, **degrades to the inbox file** — which is the complete Layer-1+2 delivery, not a failure. Feature-detect the socket; never assume it.
- **v2 send-side capture is additionally Claude-only** (it uses `SendMessage` and `bridge:`), whereas v1 file-staging is agent-agnostic on send.
- **The approval gate is mandatory.** This is genuine cross-project/cross-host communication; `SANDY_HANDOFF_PEERS` is privileged and both-ends-mutual by design, no wildcards in v1.
- **The secret scan is regex-shaped and will miss things** — discipline, not a guarantee.
- **A live session is required for a turn.** No handoff ever *starts* a container. If B is stopped, the message queues in B's inbox and is announced at B's next launch. One container's message must never cause another container to exist.
- **Provenance is attribution, not authentication of intent** — the nonce identifies a launch, not the writing process inside the sender's container.
- **Nothing here is built or run.** Layer 1 (mounts) is shipped and tested; Layers 2–3 are unbuilt, and the relay, the cross-host transport, the env-pin, and the live UDS injection are all **unverified against a live Docker daemon**.

---

## 10. Verification reality

Stated the way daemon mode / `--gc` / #132 state theirs.

- **Layer 1** is shipped and covered: `run-tests.sh §86` (structure) + `test/acceptance-handoff-dirs.sh` (real-Docker mount/mode, invoked as `run-integration-tests.sh §23`).
- **Layers 2–3** are Docker-runtime features. `run-tests.sh` would cover structure and policy behind a **stubbed docker**: peer-consent (all four refusal cases), secret-scan, quarantine gate, hop/quota/dedupe, the env-pin presence, the `docker exec … socat` command *shape*, and that an auto-turn notice carries the fixed line and **zero bytes of the body**. `--print-schema` gains `SANDY_HANDOFF_PEERS` (+ metadata row, `regen-config-docs.sh --check`); `--print-state` gains a filesystem-only `sandboxes[].handoff_pending` count (light-mode safe, no docker spawn).
- The real round trips — **same-host** delivery + turn, the **cross-host** relay hop, the `:ro`-inbox write-refusal, and the live UDS injection with attachments — live in a maintainer-run `test/acceptance-handoff.sh`, independently runnable and invoked from `run-integration-tests.sh`, mirroring `test/acceptance-daemon.sh`.

---

## Appendix: field-note summary

| Fact | Source | Load-bearing because |
|---|---|---|
| Socket `/tmp/cc-socks/<pid>.sock`, dir regex incl. `/run/user/<uid>/cc-socks` | binary 2.1.250 | Pins the env-var values sandy must pre-set (§6.3) |
| `CLAUDE_CODE_MESSAGING_SOCKET` / `_TOKEN`; token is the gate | binary 2.1.250 | The token, pre-pinned per-launch, is what makes the last mile secret-free |
| Injection recipe: `auth` frame then `user` frame → real turn | binary 2.1.250 | The whole delivery fidelity claim |
| Address grammar `^(?:uds\|bridge\|did):…$` | binary 2.1.250 | `bridge:`/`did:` are why a relay and cross-host identity are sanctioned shapes |
| `file_attachments` → `materializeLocalPeerFiles` | binary 2.1.250 | Attachments = handoff's file-moving purpose, delivered live |
| `verifiedPeerProcStart` degrades to "no peer pid" | binary 2.1.250 | Not a hard blocker across the `docker exec` PID namespace |
| Relayed peer messages carry no operator authority | changelog 2.1.166 | Closes the send-keys "answer a dialog" hazard at the protocol level (§7.4) |
| `:ro` inbox enforced above permission check (`EROFS`) | #139 live check | The inbox boundary holds even though the agent runs as host uid |
| `host_id` (#179), `session_nonce` (`/etc/sandy-session.json`) | sandy | Map onto `did:` identity + per-launch attribution (§7.3) |
| `channel-relay.sh` `docker exec … send-keys` precedent | `sandy:5899`, `:5934` | The relay is this architecture with a better injection verb |
