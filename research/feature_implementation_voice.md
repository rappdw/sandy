# Voice Interaction in Sandy

## How Claude Code Voice Works

| Layer | Technology |
|---|---|
| Capture (preferred) | Native `audio-capture.node` — uses **ALSA** on Linux |
| Capture (fallback 1) | `arecord` — ALSA command-line |
| Capture (fallback 2) | `rec` from SoX |
| Format | 16-bit signed LE, 16kHz, mono PCM |
| Transcription | **Server-side** via WebSocket to Anthropic (Deepgram Nova 3) |
| Auth | OAuth token (Claude Max) |

### Audio Capture Details

The native Node.js addon (`audio-capture.node`) checks `/proc/asound/cards` to verify ALSA hardware is present before using native recording. Exports: `startRecording()`, `stopRecording()`, `isRecording()`, `startPlayback()`, `writePlaybackData()`, `stopPlayback()`, `isPlaying()`, `microphoneAuthorizationStatus()`.

**`arecord` fallback**: `arecord -f S16_LE -r 16000 -c 1 -t raw -q -` — probes with a 150ms test run first.

**`rec` (SoX) fallback**: `rec -q --buffer 1024 -t raw -r 16000 -e signed -b 16 -c 1 - silence 1 0.1 3% 1 2.0 3%` — includes built-in silence detection.

### Transcription Protocol

Audio is streamed over WebSocket to Anthropic's API (not local):

- **Endpoint**: `/api/ws/speech_to_text/voice_stream`
- **URL construction**: Replace `https://` with `wss://` from `BASE_API_URL`
- **Query params**: `encoding=linear16`, `sample_rate=16000`, `channels=1`, `endpointing_ms=300`, `utterance_end_ms=1000`, `language=en`, `use_conversation_engine=true`, `stt_provider=deepgram-nova3`
- **Auth**: OAuth access token (`Authorization: Bearer {token}`)
- **Override**: `VOICE_STREAM_BASE_URL` env var can override the WebSocket endpoint

**Protocol messages**:
- Client sends raw PCM audio chunks as binary WebSocket frames
- Client sends `{"type":"KeepAlive"}` every 8 seconds
- Client sends `{"type":"CloseStream"}` to finalize
- Server responds with `TranscriptText` (interim), `TranscriptEndpoint` (final), `TranscriptError`
- Finalize timeouts: 5000ms safety, 1500ms no-data

### Remote Environment Detection

Voice mode is **explicitly disabled** when `CLAUDE_CODE_REMOTE` is set or a remote environment is detected: "Voice mode requires microphone access, but no audio device is available in this environment."

WSL2 with WSLg is supported (PulseAudio-based), but WSL1 / Windows 10 without WSLg is not.

## Critical Blockers for Docker

1. **Environment detection** — Claude Code detects it's in a container/remote and disables voice entirely
2. **Audio device access** — Container has no ALSA devices (`/proc/asound/cards` is empty, no `/dev/snd`). All three capture methods require a working audio device.

## Approaches Considered

### Approach A: PulseAudio Relay (Linux-only host)

Same pattern as sandy's SSH agent relay.

- **Container**: Install `pulseaudio-utils` + `alsa-utils` in base image, configure ALSA to use PulseAudio
- **Linux host**: Mount `$XDG_RUNTIME_DIR/pulse/native` socket into container, set `PULSE_SERVER`
- **macOS host**: Won't work — Docker Desktop VM has no access to host CoreAudio

**Verdict**: Linux-only. Doesn't solve macOS.

### Approach B: Virtual ALSA Device + Network Audio (cross-platform)

- Install `alsa-utils` + ALSA loopback module in container
- Host captures mic audio and streams PCM over TCP into the container
- Container-side `socat` feeds the TCP stream into the ALSA loopback device
- Follows the exact SSH agent relay pattern (host socat ↔ container socat)

**Verdict**: Complex. Requires kernel module loading (may not work in unprivileged container).

### Approach C: Host-Side Capture + Pipe (simplest device approach)

- Host-side helper captures mic audio (via `sox`/`rec` on Linux, CoreAudio on macOS)
- Streams 16kHz mono PCM into the container via a mounted named pipe or TCP socket
- Container runs a shim that reads from the pipe

**Verdict**: Claude Code expects to control the audio device directly (start/stop recording). A pipe doesn't provide that control surface.

### Approach D: Host-Side Voice Proxy (Recommended)

Since transcription is server-side anyway, bypass the container audio problem entirely:

- Host-side captures audio and sends it directly to Anthropic's STT WebSocket endpoint
- Injects the transcribed text into Claude Code's input inside the container via `tmux send-keys`
- Uses the same OAuth token that's already available

## Recommended Design: Host-Side Voice Proxy

```
┌─ Host ─────────────────────────────────────┐
│                                             │
│  sandy-voice (small companion binary/script)│
│    ├─ Captures mic audio (CoreAudio/ALSA)   │
│    ├─ Streams to Anthropic STT WebSocket    │
│    └─ Injects transcribed text via:         │
│         tmux send-keys -t sandy "text" Enter│
│                                             │
│  ┌─ Docker Container ────────────────────┐  │
│  │  Claude Code (tmux session)           │  │
│  │  Receives text as normal keyboard     │  │
│  │  input — no audio needed              │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

### Why This Approach

1. **No container audio infrastructure needed** — no ALSA, no PulseAudio, no device mounts
2. **Cross-platform** — works on macOS and Linux identically since audio capture runs on the host
3. **Fits sandy's architecture** — host-side helper managed alongside the container, like the SSH relay
4. **Clean separation** — audio stays on the host where it belongs, text goes to the container

### Implementation Options

The voice proxy could be implemented as:
- **Node.js script** using the same WebSocket protocol Claude Code uses (endpoint, params, and auth are known)
- **Python script** with `sounddevice` + `websockets`

### Configuration

- Toggle with `SANDY_VOICE=true` in `.sandy/config`
- Sandy launches the proxy alongside the container (like the SSH relay) and kills it on exit

### Open Question

Push-to-talk UX: Claude Code's built-in voice uses spacebar push-to-talk inside the terminal. The tmux injection approach bypasses this, so activation would need a separate mechanism:
- Host-side global hotkey
- Terminal-level key capture
- Continuous listening with voice activity detection (VAD)
