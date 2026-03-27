# Tech Debt Review: Session Migration (v0.7.10)

Review date: 2026-03-26
Scope: Migration code (sandy lines 565-630), auto-resume logic (lines 815-825), tests (test/run-tests.sh section 27)

This review covers tech debt accumulated during iterative development of the session migration feature across v0.7.10.

---

## RESOLVED

### ~~1. `.claude.json` write is not atomic~~ — FIXED

Atomic write via tmp + rename pattern now in place (lines 623-626).

### ~~2. `.claude.json` migration has no test coverage~~ — FIXED

Added tests 6-9 in section 27: trust consolidation, no-op, malformed JSON, trailing newline.

### ~~3. Missing trailing newline on `.claude.json` write~~ — FIXED

Now writes `JSON.stringify(d, null, 2) + "\n"` (line 625).

### ~~5. Silent error swallowing masks migration failures~~ — FIXED

All three migration steps now emit yellow warnings on failure (lines 581, 589, 628) instead of silently continuing.

### ~~10. Comment on `cp -an` doesn't explain no-clobber behavior~~ — FIXED

Comment now explains both `-a` (archive) and `-n` (no-clobber) semantics (lines 576-577).

---

## OPEN — MEDIUM Severity

### 4. `sed` replacement on `history.jsonl` doesn't escape `$WORKSPACE`

**Line:** 588

```bash
sed -i "s|\"project\":\"[^\"]*\"|\"project\":\"$WORKSPACE\"|g" "$HOME/.claude/history.jsonl"
```

If `$WORKSPACE` contains `&` (sed replacement metacharacter) or `\`, the replacement will be corrupted. In practice, `$WORKSPACE` is always a container path like `/home/claude/dev/...` (constructed at sandy line 1506), so special characters are extremely unlikely. But the code is fragile by construction.

**Fix:** Escape the replacement string:
```bash
_ws_escaped="$(printf '%s\n' "$WORKSPACE" | sed 's/[&/\]/\\&/g')"
sed -i "s|\"project\":\"[^\"]*\"|\"project\":\"$_ws_escaped\"|g" ...
```

### 6. Migration merges ALL `.claude.json` project entries, including unrelated ones

**Lines:** 605, 619

The `.claude.json` is seeded from the host's `~/.claude.json` on first sandbox creation (line 1360). The host file may contain entries for unrelated projects (e.g., `/Users/rappdw/dev/mws`). The migration deletes ALL entries except the current workspace, merging their `allowedTools` and trust state into the current entry.

**Impact:** Minimal in practice — extra `allowedTools` are harmless in a sandboxed environment, and inheriting `hasTrustDialogAccepted: true` from an unrelated project is benign (the sandbox IS trusted). But it conflates stats like `lastCost` and `lastSessionId` from unrelated projects.

**Possible fix:** Only migrate entries whose paths match known era patterns for the current project. This would require reverse-mapping the sandbox to its host project path, which adds complexity. May not be worth it given the low impact.

### 7. `_sessions_migrated` flag has misleading semantics

**Lines:** 570, 579, 820

The flag is set when `cp -an` succeeds (project dirs merged) and used to choose `--resume` vs `--continue`. But it doesn't reflect whether `history.jsonl` or `.claude.json` migration succeeded. The flag name suggests "all session state was migrated" when it only means "some files were copied."

**Fix:** Rename to `_project_dirs_merged` for clarity, or set the flag based on a broader condition.

---

## OPEN — LOW Severity

### 8. Underscore-prefixed variables pollute global scope in heredoc

**Lines:** 569-583

Variables `_cur_proj`, `_sessions_migrated`, `_old_proj` are set in the heredoc's top-level scope (not inside a function). Since `user-setup.sh` runs as a script (not sourced), this is harmless — the variables die with the process. Not a real issue unless `user-setup.sh` execution model changes.

### 9. `ls` glob for session detection

**Line:** 819

```bash
if ls "$SESSION_DIR"*.jsonl &>/dev/null; then
```

Using `ls` for existence testing is discouraged (see ShellCheck SC2012). A more robust alternative:

```bash
if compgen -G "${SESSION_DIR}*.jsonl" >/dev/null 2>&1; then
```

---

## Documentation Gap

### 11. CLAUDE.md has no section on session migration or auto-resume

The CLAUDE.md documents workspace mount paths and per-project sandboxes but never explains:
- How Claude Code session state is structured (project dirs, `history.jsonl`, `.claude.json` project entries)
- The three path eras and why migration exists
- The auto-resume/auto-continue behavior (`SANDY_AUTO_CONTINUE`)
- What `--resume` vs `--continue` means for the user after migration

This context is critical for anyone debugging session issues in the future.

---

## Summary

| # | Issue | Severity | Status |
|---|-------|----------|--------|
| 1 | `.claude.json` write not atomic | HIGH | FIXED |
| 2 | `.claude.json` migration untested | HIGH | FIXED |
| 3 | Missing trailing newline | HIGH | FIXED |
| 5 | Silent error swallowing | MEDIUM | FIXED |
| 10 | Comment missing `-n` explanation | LOW | FIXED |
| 4 | `sed` doesn't escape `$WORKSPACE` | MEDIUM | Open |
| 6 | Merges unrelated project entries | MEDIUM | Open |
| 7 | `_sessions_migrated` naming | MEDIUM | Open |
| 8 | Underscore vars in global scope | LOW | Open |
| 9 | `ls` for session detection | LOW | Open |
| 11 | CLAUDE.md missing session docs | LOW | Open |
