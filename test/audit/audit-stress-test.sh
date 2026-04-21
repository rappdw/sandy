#!/usr/bin/env bash
#
# audit-stress-test.sh — audit host for residual payloads from the
# isolation-stress-test exercise.
#
# READ-ONLY. This script only reads files and runs informational commands.
# It writes exactly ONE file: the audit log at /tmp/sandy-audit-<ts>.log.
# Review every command below before running — nothing here modifies state.
#
# Usage:  bash audit-stress-test.sh
# Output: /tmp/sandy-audit-<timestamp>.log  (paste contents back to Claude)

set -u

LOG="/tmp/sandy-audit-$(date +%Y%m%d-%H%M%S).log"

# Mirror everything to terminal + log so you see progress while it runs.
exec > >(tee "$LOG") 2>&1

# -------- helpers --------

section()    { printf '\n================================================================\n=== %s ===\n================================================================\n' "$*"; }
subsection() { printf '\n--- %s ---\n' "$*"; }

# Portable stat: BSD (macOS) first, then GNU (Linux).
stat_brief() {
    for f in "$@"; do
        [ -e "$f" ] || { echo "(missing) $f"; continue; }
        stat -f '%Sm  size=%z  mode=%Sp  %N' "$f" 2>/dev/null \
            || stat -c '%y  size=%s  mode=%A  %n' "$f" 2>/dev/null \
            || echo "(stat failed) $f"
    done
}

show_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    subsection "$f"
    stat_brief "$f"
    shasum -a 256 "$f" 2>/dev/null || sha256sum "$f" 2>/dev/null
    echo "--- content ---"
    # Cap at 500 lines per file so a single huge file doesn't drown the log.
    head -500 "$f"
    local n; n="$(wc -l < "$f" 2>/dev/null || echo 0)"
    [ "$n" -gt 500 ] 2>/dev/null && echo "[...truncated, $n total lines...]"
    echo "--- end ---"
}

# -------- header --------

echo "sandy host audit — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "hostname: $(hostname 2>/dev/null)"
echo "user:     $(whoami)"
echo "home:     $HOME"
echo "shell:    ${SHELL:-unknown}"
echo "uname:    $(uname -a)"
echo "uptime:   $(uptime 2>/dev/null)"
echo "log path: $LOG"

# ================================================================
# 1. Shell rc / profile files — existence, mtime, full content
# ================================================================
section "1. Shell rc and profile files"
for f in \
    "$HOME/.zshenv"      \
    "$HOME/.zprofile"    \
    "$HOME/.zshrc"       \
    "$HOME/.zlogin"      \
    "$HOME/.bashrc"      \
    "$HOME/.bash_profile"\
    "$HOME/.bash_login"  \
    "$HOME/.profile"     \
    "$HOME/.config/fish/config.fish" \
    "$HOME/.config/zsh/.zshrc"       \
    "$HOME/.config/bash/bashrc"; do
    show_file "$f"
done

# ================================================================
# 2. Patterns of interest in shell configs
# ================================================================
section "2. Suspicious patterns in shell configs"
subsection "docker / prune / rmi / backgrounded spawns / nohup / disown"
grep -nE 'docker|prune|rmi|nohup|disown|&[[:space:]]*$|\(.*&[[:space:]]*\)|image[[:space:]]*rm|image[[:space:]]*delete|while[[:space:]]+read.*docker' \
    "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.zlogin" \
    "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile" \
    2>/dev/null

# ================================================================
# 3. launchd agents (user scope)
# ================================================================
section "3. User LaunchAgents"
subsection "ls -la ~/Library/LaunchAgents/"
ls -la "$HOME/Library/LaunchAgents/" 2>/dev/null

subsection "contents of every non-Apple user agent plist"
if [ -d "$HOME/Library/LaunchAgents" ]; then
    for p in "$HOME/Library/LaunchAgents"/*.plist; do
        [ -f "$p" ] || continue
        case "$(basename "$p")" in
            com.apple.*) continue ;;
        esac
        show_file "$p"
    done
fi

# ================================================================
# 4. launchd agents / daemons (system scope) — non-Apple only
# ================================================================
section "4. System LaunchAgents / LaunchDaemons (non-Apple)"
for d in /Library/LaunchAgents /Library/LaunchDaemons; do
    subsection "ls $d (filtered, non-Apple)"
    ls -la "$d" 2>/dev/null | grep -viE 'com\.apple|^total|^d' || true
done

# ================================================================
# 5. launchctl list — currently loaded non-Apple entries
# ================================================================
section "5. launchctl list (non-Apple entries, capped at 100)"
launchctl list 2>/dev/null | awk 'NR==1 || $3 !~ /^com\.apple/' | head -100

# ================================================================
# 6. crontab
# ================================================================
section "6. User crontab"
subsection "crontab -l"
crontab -l 2>/dev/null || echo "(none or not accessible)"

# ================================================================
# 7. Git hooks in ~/dev repos (including submodules)
# ================================================================
section "7. Git hooks in ~/dev (non-sample only)"
if [ -d "$HOME/dev" ]; then
    find "$HOME/dev" -maxdepth 7 -type d -name hooks -path '*/.git/*' 2>/dev/null | while IFS= read -r d; do
        # List every non-sample file in this hooks dir
        for h in "$d"/*; do
            [ -f "$h" ] || continue
            base="$(basename "$h")"
            case "$base" in
                *.sample) continue ;;
            esac
            show_file "$h"
        done
    done
fi

# ================================================================
# 8. .git/info/attributes — filter-driver injection vector
# ================================================================
section "8. .git/info/attributes and .gitattributes with filters"
if [ -d "$HOME/dev" ]; then
    find "$HOME/dev" -maxdepth 7 -type f -path '*/.git/info/attributes' 2>/dev/null | while IFS= read -r f; do
        show_file "$f"
    done
    subsection ".gitattributes files containing 'filter' directives"
    find "$HOME/dev" -maxdepth 7 -type f -name .gitattributes 2>/dev/null | while IFS= read -r f; do
        if grep -q 'filter' "$f" 2>/dev/null; then
            show_file "$f"
        fi
    done
fi

# ================================================================
# 9. Global git config — filter drivers and aliases
# ================================================================
section "9. Global .gitconfig"
show_file "$HOME/.gitconfig"
show_file "$HOME/.config/git/config"

subsection "sandy repo local .git/config"
show_file "$HOME/dev/sandy/.git/config"

# ================================================================
# 10. .vscode/ and .envrc in ~/dev repos
# ================================================================
section "10. .vscode dirs and .envrc files in ~/dev"
if [ -d "$HOME/dev" ]; then
    find "$HOME/dev" -maxdepth 5 -type d -name .vscode 2>/dev/null | while IFS= read -r d; do
        subsection "$d"
        ls -la "$d"
        for f in "$d"/*; do
            [ -f "$f" ] || continue
            show_file "$f"
        done
    done
    find "$HOME/dev" -maxdepth 5 -type f -name .envrc 2>/dev/null | while IFS= read -r f; do
        show_file "$f"
    done
fi

# ================================================================
# 11. Recently-modified files under $HOME (last 14 days, top 2 levels)
# ================================================================
section "11. Recently-modified files in \$HOME (last 14 days, maxdepth 2)"
find "$HOME" -maxdepth 2 -type f -mtime -14 \
    -not -path '*/Library/Caches/*' \
    -not -path '*/Library/Logs/*' \
    -not -path '*/Library/Containers/*' \
    -not -path '*/Library/Group Containers/*' \
    -not -path '*/Library/Application Support/*' \
    -not -path '*/Library/Metadata/*' \
    -not -path '*/Library/Saved Application State/*' \
    -not -path '*/.Trash/*' \
    -not -path '*/Downloads/*' \
    -not -path '*/.sandy/sandboxes/*' \
    2>/dev/null | head -200

# ================================================================
# 12. Dotfiles directly in $HOME modified in last 30 days
# ================================================================
section "12. Dotfiles in \$HOME root, mtime within 30 days"
find "$HOME" -maxdepth 1 -name '.*' -type f -mtime -30 2>/dev/null | while IFS= read -r f; do
    stat_brief "$f"
done

# ================================================================
# 13. Running processes that look like docker watchers
# ================================================================
section "13. Running processes matching docker/prune/image/watch"
ps auxww 2>/dev/null | grep -iE 'docker[[:space:]]+(events|image|system)|image.*prune|image.*rm|docker.*rmi|while[[:space:]]+read.*docker|watch.*docker' \
    | grep -v 'grep ' || echo "(no matches)"

# ================================================================
# 14. Docker-socket listeners
# ================================================================
section "14. Processes with docker socket open (lsof)"
for sock in \
    /var/run/docker.sock \
    "$HOME/.rd/docker.sock" \
    "$HOME/.docker/run/docker.sock" \
    "$HOME/Library/Containers/com.docker.docker/Data/docker.raw.sock"; do
    if [ -S "$sock" ]; then
        subsection "$sock"
        lsof -- "$sock" 2>/dev/null | head -30 || echo "(lsof failed — may need sudo)"
    fi
done

# ================================================================
# 15. SSH state
# ================================================================
section "15. ~/.ssh listing and authorized_keys"
ls -la "$HOME/.ssh" 2>/dev/null
show_file "$HOME/.ssh/authorized_keys"

# ================================================================
# 16. /etc/hosts
# ================================================================
section "16. /etc/hosts"
stat_brief /etc/hosts
head -100 /etc/hosts

# ================================================================
# 17. Shell history — docker rmi / prune mentions
# ================================================================
section "17. Shell history mentions of docker rmi/prune/image rm"
for h in "$HOME/.zsh_history" "$HOME/.bash_history" "$HOME/.local/share/fish/fish_history"; do
    [ -f "$h" ] || continue
    subsection "$h"
    grep -iE 'docker[[:space:]]+(rmi|image[[:space:]]*(rm|delete|prune)|system[[:space:]]*prune|prune)' "$h" 2>/dev/null | tail -30 || true
done

# ================================================================
# 18. Suspicious environment variables
# ================================================================
section "18. Suspicious environment variables"
env 2>/dev/null | grep -iE 'docker|hook|preexec|precmd|debug|trace|watch' \
    | grep -viE '^(DOCKER_HOST|DOCKER_CONFIG|DOCKER_CERT_PATH|DOCKER_TLS_VERIFY)=' || echo "(none)"

# ================================================================
# 19. Scratch files in /tmp and /var/tmp
# ================================================================
section "19. Scratch files in /tmp, /var/tmp (shallow, scripty names)"
find /tmp /var/tmp -maxdepth 2 -type f \
    \( -name '*.sh' -o -name '*.plist' -o -name 'docker*' -o -name '*watch*' -o -name '*prune*' -o -name 'sandy*' \) \
    2>/dev/null | head -50 | while IFS= read -r f; do
        stat_brief "$f"
    done

# ================================================================
# 20. Zsh / bash hook arrays currently defined
# ================================================================
section "20. Shell hook arrays (precmd, preexec, etc.)"
subsection "zsh hook arrays"
zsh -ic '
    for a in precmd_functions preexec_functions chpwd_functions zshexit_functions periodic_functions; do
        print -n "$a: "
        eval "print -l \${(P)a}"
    done
    echo "---"
    echo "functions containing docker/prune:"
    functions 2>/dev/null | grep -iE "docker|prune|rmi|image.*rm" | head -40
' 2>/dev/null || echo "(zsh -ic failed)"

subsection "bash declare -F (docker/prune matches)"
bash -ic 'declare -F 2>/dev/null | grep -iE "docker|prune|rmi|image"' 2>/dev/null || echo "(bash -ic failed)"

# ================================================================
# 21. Claude Code own session dirs (if I was run as claude-code, it may
#     have captured transcripts that show what was executed)
# ================================================================
section "21. Claude Code project history dirs in ~/.claude/projects"
ls -la "$HOME/.claude/projects/" 2>/dev/null | head
subsection "sandy-project transcripts (if any)"
find "$HOME/.claude/projects" -maxdepth 2 -type d -iname '*sandy*' 2>/dev/null | while IFS= read -r d; do
    echo "$d"
    ls -la "$d" 2>/dev/null | head
done

# ================================================================
# 22. Sandy repo working tree — any files I left behind?
# ================================================================
section "22. Sandy repo: git status + recently-modified files"
cd "$HOME/dev/sandy" 2>/dev/null && {
    subsection "git status"
    git status --short 2>/dev/null
    subsection "untracked files"
    git ls-files --others --exclude-standard 2>/dev/null | head -50
    subsection "files modified in last 14 days (maxdepth 3, excluding .git)"
    find . -maxdepth 3 -type f -mtime -14 -not -path './.git/*' -not -path './node_modules/*' 2>/dev/null | head -50
}

# ================================================================
# 23. Deep grep for the smoking-gun pattern across likely homes
# ================================================================
section "23. Deep grep for 'docker events' watcher pattern"
# Look for any script anywhere in likely payload locations that uses
# `docker events` (the event-watcher smoking gun).
for root in \
    "$HOME/Library/LaunchAgents" \
    "$HOME/Library/Application Support" \
    "$HOME/.local" \
    "$HOME/bin" \
    "$HOME/.config" \
    /tmp \
    /var/tmp \
    /usr/local/bin; do
    [ -d "$root" ] || continue
    grep -rlE 'docker[[:space:]]+events|docker[[:space:]]+image[[:space:]]+prune|docker[[:space:]]+system[[:space:]]+prune' "$root" 2>/dev/null | head -20
done

# ================================================================
section "DONE"
# ================================================================
echo
echo "Audit complete."
echo "Log file: $LOG"
echo "Size:     $(wc -c < "$LOG" 2>/dev/null) bytes"
echo
echo "Paste the contents of $LOG back to Claude for review."
