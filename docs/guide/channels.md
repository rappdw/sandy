# Notifications and channels

Terminal notifications, and reaching a session from Telegram or Discord. Part of the [sandy guides](README.md); back to the [project README](../../README.md).

## Terminal Notifications

Sandy passes through OSC escape sequences (9/99/777) from Claude Code to the outer terminal. This enables notification features in terminals like [cmux](https://www.cmux.dev/) and iTerm2 — pane rings, desktop alerts, and badges when Claude needs attention.

**cmux auto-setup**: When sandy detects it's running inside cmux (via the `CMUX_WORKSPACE_ID` environment variable), it automatically installs a notification hook that emits OSC 777 sequences on Claude Code events. No manual configuration needed — just run `sandy` in a cmux pane.

**Custom hooks**: If you have Claude Code hooks configured on the host (`~/.claude/hooks/`), sandy mounts them read-only into the container automatically. Host hooks take precedence over auto-setup (cmux auto-setup is skipped if `~/.claude/hooks/` exists on the host).

**Clipboard**: Sandy's tmux uses OSC 52 to copy mouse selections to the system clipboard. In iTerm2, enable this under **Settings > General > Selection > "Applications in terminal may access clipboard"**. With this enabled, click-drag selections in the container are automatically copied to your Mac clipboard.

## Channels (Telegram, Discord)

Sandy supports [Claude Code channels](https://code.claude.com/docs/en/channels) — push messages from Telegram or Discord into your running session. Sandy auto-installs the channel plugin and seeds credentials on startup.

## Quick setup (Telegram)

1. Create a bot via [BotFather](https://t.me/BotFather) and copy the token
2. Add to `.sandy/.secrets` (gitignored):
   ```
   TELEGRAM_BOT_TOKEN=123456789:AAH...
   TELEGRAM_ALLOWED_SENDERS=your_telegram_user_id
   ```
3. Add to `.sandy/config`:
   ```
   SANDY_CHANNELS=plugin:telegram@claude-plugins-official
   ```
4. Run `sandy` — the plugin is auto-installed, credentials are seeded, and Claude starts with the channel active

To find your Telegram user ID, message [@userinfobot](https://t.me/userinfobot).

**`TELEGRAM_ALLOWED_SENDERS` is required for the host-side relay**, which is what runs for `gemini`, `codex`, `opencode`, `grok` and every multi-agent combo. Without it the relay refuses to start, because an empty allowlist would let any Telegram user who finds your bot send keystrokes to the agent. Pairing mode is the **in-container Claude plugin only** (single-agent `claude`): there, omitting the allowlist starts `pairing` — DM your bot, then run `/telegram:access pair <code>` inside the session. The host relay has no pairing flow.

## Quick setup (Discord)

1. Create an application at the [Discord Developer Portal](https://discord.com/developers/applications)
2. In the **Bot** section, create a bot, reset the token, and copy it
3. Enable **Message Content Intent** under **Privileged Gateway Intents**
4. Use **OAuth2 > URL Generator** with the `bot` scope and these permissions: View Channels, Send Messages, Send Messages in Threads, Read Message History, Attach Files, Add Reactions. Open the generated URL to invite the bot to your server.
5. Add to `.sandy/.secrets` (gitignored):
   ```
   DISCORD_BOT_TOKEN=your_discord_bot_token
   DISCORD_ALLOWED_SENDERS=your_discord_user_id
   ```
6. Add to `.sandy/config`:
   ```
   SANDY_CHANNELS=plugin:discord@claude-plugins-official
   ```
7. Run `sandy` — the plugin is auto-installed, credentials are seeded, and Claude starts with the channel active

If `DISCORD_ALLOWED_SENDERS` is omitted, sandy starts in `pairing` mode — DM your bot, then run `/discord:access pair <code>` inside the session.

## Using both channels

Set both tokens in `.sandy/.secrets` and list both plugins in `.sandy/config`:

```
SANDY_CHANNELS=plugin:telegram@claude-plugins-official plugin:discord@claude-plugins-official
```

## Channels with Gemini / Codex / multi-agent mode

For any `SANDY_AGENT` value other than single-agent `claude`, sandy uses a **host-side Telegram relay** instead of the in-container plugin — it long-polls the Telegram Bot API on the host and injects messages into the container's tmux session via `docker exec … tmux send-keys`. This is agent-agnostic but lower-fidelity: no chat threading, no edit-message updates, no attachments. Set `SANDY_CHANNEL_TARGET_PANE=0|1|2|3` to route messages to a specific agent in multi-agent mode — `N` is the Nth agent listed in `SANDY_AGENT`, 0-based (default `0` = the first); the relay looks up that agent's pane by its tag rather than trusting the tmux pane number. Discord via relay is not supported yet — use single-agent `SANDY_AGENT=claude` for Discord.

> ⚠️ **`SANDY_CHANNELS` format for the relay is different.** The relay matches the **bare channel name** — `SANDY_CHANNELS=telegram` — *not* the `plugin:telegram@claude-plugins-official` form used for single-agent `claude` above (that qualified form is what `claude --channels` needs, but it won't trigger the relay). Use bare names when the relay is in play (any non-single-`claude` `SANDY_AGENT`). This dual-format wart is tracked in [#30](https://github.com/rappdw/sandy/issues/30) and will be unified.
