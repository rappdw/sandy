# Plugin Skills Loading Analysis in Sandy

**Date**: 2026-03-20
**Claude Code version analyzed**: 2.1.80
**Context**: Investigating why synthkit plugin shows "0 skills" in `/reload-plugins` and slash commands don't appear inside sandy containers.

## Symptom

```
/plugin       → ✓ Installed 1 plugin. Run /reload-plugins to activate.
/reload-plugins → Reloaded: 1 plugin · 0 skills · 5 agents · 0 hooks · 0 plugin MCP servers · 0 plugin LSP servers
```

Skills appear in the system prompt (AI can invoke them via the Skill tool), but:
- The count shows "0 skills"
- Slash commands (e.g., `/md2pdf`) don't appear in autocomplete
- Outside sandy (non-isolated), counts are correct and slash commands work

## Root Cause

Claude Code has **two separate plugin content loading systems** with confusing naming:

### 1. Plugin "Commands" (`_$_()`)

- Loaded from a plugin's `commands/` directory
- Uses `pt9()` with `isSkillMode: false`
- Stored in `state.plugins.commands`
- **Counted by `/reload-plugins` as "skills"** (misleading label)

### 2. Plugin "Skills" (`MQq()` / `getPluginSkills`)

- Loaded from a plugin's `skills/` directory
- Uses `Bt9()` with skill mode
- Returned by `getSkills()` alongside `skillDirCommands`, `bundledSkills`, and `builtinPluginSkills`
- Injected into the system prompt for AI use via the `Skill` tool
- **NOT counted by `/reload-plugins`**
- **NOT stored in `state.plugins.commands`**

### Impact on Synthkit

Synthkit has only a `skills/` directory (9 skills) and no `commands/` directory. Therefore:
- `command_count = 0` → displayed as "0 skills"
- `getPluginSkills` finds 9 skills → they appear in the system-reminder

## Key Code Paths (from binary analysis)

### Plugin loading (`Ze9`)

```javascript
// Checks for default directories (only if NOT declared in manifest)
let [D, j, z, w] = await Promise.all([
    !R.commands    ? FK(path.join(_, "commands"))      : false,
    !R.agents      ? FK(path.join(_, "agents"))        : false,
    !R.skills      ? FK(path.join(_, "skills"))        : false,
    !R.outputStyles? FK(path.join(_, "output-styles")) : false,
]);

if (D) $.commandsPath = Y;   // commands/ exists → set commandsPath
if (j) $.agentsPath = P;     // agents/ exists → set agentsPath
if (z) $.skillsPath = f;     // skills/ exists → set skillsPath
```

- `FK()` is `async function FK(_) { try { return await stat(_), true; } catch { return false; } }`
- For synthkit: `z = true` (skills/ exists), `D = false` (no commands/)
- So `skillsPath` is set but `commandsPath` is not

### `/reload-plugins` handler (`YnO`)

```javascript
YnO = async (_, T) => {
    let q = await Ny_(T.setAppState);  // refreshActivePlugins
    let O = `Reloaded: ${[
        l$_(q.enabled_count, "plugin"),
        l$_(q.command_count, "skill"),     // ← counts COMMANDS, labels as "skill"
        l$_(q.agent_count, "agent"),
        l$_(q.hook_count, "hook"),
        l$_(q.mcp_count, "plugin MCP server"),
        l$_(q.lsp_count, "plugin LSP server")
    ].join(" · ")}`;
};
```

### `refreshActivePlugins` (`Ny_`)

```javascript
async function Ny_(_) {
    // Clear both caches
    eH();    // clears _$_ (commands) cache
    wU9();   // clears MQq (skills) cache

    let [T, q, K] = await Promise.all([
        RR(),        // T = {enabled, disabled, errors}
        _$_(),       // q = commands (re-executed after cache clear)
        kI(sq())     // K = agent definitions
    ]);

    // NOTE: MQq() is NOT called here — skills cache is cleared but not repopulated

    _((Y) => ({
        ...Y,
        plugins: {
            ...Y.plugins,
            enabled: O,
            disabled: H,
            commands: q,   // ← only commands, NOT skills
            errors: ...
        },
        agentDefinitions: K,
    }));

    return {
        command_count: q.length,  // ← 0 for synthkit (no commands/)
        ...
    };
}
```

### `getSkills` (`asO`) — system prompt injection

```javascript
async function asO(_) {
    let [T, q] = await Promise.all([
        Idq(_).catch(...),   // T = skill directory commands (~/.claude/skills/)
        MQq().catch(...)     // q = plugin skills (from plugin skills/ dirs)
    ]);
    let K = hz7();           // bundled skills
    let O = Je9();           // builtin plugin skills

    return {
        skillDirCommands: T,
        pluginSkills: q,        // ← synthkit's 9 skills come from here
        bundledSkills: K,
        builtinPluginSkills: O
    };
}
```

## Why It Works Outside Sandy

Most likely: the host runs a **newer version of Claude Code** than the container's v2.1.80. Since `DISABLE_AUTOUPDATER=1` is set inside sandy, the container only updates when the image is rebuilt (`sandy --rebuild`).

A newer version may have:
- Fixed the counting to include both commands and skills
- Added skills to the slash command autocomplete UI
- Unified the two systems

## Sandy-Specific Details

### Plugin installation path inside container

```
/home/claude/.claude/plugins/cache/sandy-plugins/synthkit/0.6.0/
├── .claude-plugin/plugin.json
├── skills/
│   ├── boardroom/SKILL.md
│   ├── ciso-review/SKILL.md
│   ├── explore-with-me/SKILL.md
│   ├── init-discovery/SKILL.md
│   ├── map-the-repo/SKILL.md
│   ├── md2docx/SKILL.md
│   ├── md2email/SKILL.md
│   ├── md2html/SKILL.md
│   └── md2pdf/SKILL.md
├── src/
├── guidelines/
└── ...
```

### Verified working

- Plugin cache is writable (bind-mounted from `$SANDBOX_DIR`)
- `installed_plugins.json` has correct container path
- `settings.json` has `enabledPlugins: { "synthkit@sandy-plugins": true }`
- All SKILL.md files are readable and have correct frontmatter (`user-invocable: true`)
- Skills appear in the system-reminder (AI can invoke them)
- `git clone` works inside sandy (SSH→HTTPS rewrite via `url.insteadOf`)

### Not a sandy isolation issue

The read-only filesystem, tmpfs, bind mounts, and network isolation do NOT prevent plugin skill loading. The issue is purely in how Claude Code v2.1.80 counts and registers skills vs commands.

## Remediation

1. **Rebuild sandy image** (`sandy --rebuild`) to pick up latest Claude Code
2. If the issue persists in newer versions, it's a Claude Code bug to report
3. Workaround: synthkit could add a `commands/` directory that re-exports skills, but this shouldn't be necessary
