# Decisions: git directories outside the workspace, shared git dirs, and worktrees (2026-11-24)

Decided by the maintainer on 2026-11-24, for 2.12.0. Four issues found around #582 (git inside the container for linked worktrees) and its security review.

| # | Decision | Choice | Deciding reason |
|---|----------|--------|-----------------|
| 1 | #598 gitdir outside the workspace | Recognized submodule / (later) linked-worktree relationships with no prompt; anything else a one-time approval naming the target, remembered per workspace and target; headless fails closed; not covered by `SANDY_AUTO_APPROVE_PRIVILEGED` | closes the sibling-repo read-write hole without prompting for the common submodule case |
| 2 | #596 sessions sharing a git dir | A per-git-dir hold registry under `$SANDY_HOME`; seed and macOS locks released only by the last live holder; unknown holder state counts as alive | parallel agents in worktrees are #582's reason to exist; refusing a second session would take that away |
| 3 | #597 worktree admin dirs | Other worktrees' admin dirs mounted `:ro`; an admin dir recorded at launch but missing at session end is reported; `gc.worktreePruneExpire=never` in the container | losing worktrees to a routine prune/gc is data loss: prevent, don't just report |
| 4 | #582 git inside the container for default (absolute-path) worktrees | A translated, read-only, container-only `.git` file (and the session's own `worktrees/<name>/gitdir` back-pointer) under `$SANDBOX_DIR/launch/<id>/`, mounted over the originals | default worktrees work with no host change and no second spelling of protected paths |

Options considered and not taken:

- **1:** an approval for every gitdir outside the workspace, submodules included; refusing every gitdir sandy does not recognize (breaks `--separate-git-dir`); documenting the exposure only.
- **2:** refusing a second session on the same git dir; refusing now and adding the registry later.
- **3:** detecting and hardening only; documenting only.
- **4:** also mounting the common dir at its literal host path; a warning plus documentation of a hand edit.

## Implementation of decision 1 (#598)

`_sandy_gitdir_judge` / `_sandy_gitdir_gate` in `sandy`, called by the launch (the R5a block) and by the `--start` approval pass (`_sandy_approve_only_finish`). Test: host-suite §260.

- The structural check (`HEAD`, `objects/`, `refs/`) still runs first, wherever the gitdir lies, with its 1.14.0 message.
- **Inside** the workspace (as `_sandy_gitdir_host` spells it: its parent resolved physically, its last component as named, so `gitdir: vendor/lnk` with `vendor/lnk` a link is the dangerous-symlink gate's to judge, as before): unchanged.
- **Recognized: a submodule gitdir.** All paths are physical (`cd -P`, `pwd -P`); a workspace reached through a link is judged where it physically lies. The superproject is the *nearest* ancestor of the workspace that holds a `.git` entry, as git finds it. Its `.gitmodules` must be a regular file that declares a submodule whose `path` (trailing `/` dropped) is the workspace's path relative to the superproject, and the gitdir must be exactly `<superproject gitdir>/modules/<name>`, using the submodule's NAME, not its path. The name must not be empty or absolute and must have no `.`, `..` or empty component and no backslash. Since both sides are physical, an equal spelling means the same directory with no link below the superproject's gitdir, so `.git/modules/x` as a link to another repository is not recognized. The superproject's gitdir is its `.git` directory, or, for a submodule of a submodule, the gitdir its own `.git` file names, which must be recognized the same way, up to 8 levels. `.gitmodules` is read by `git config -z -f` (run from `/`, so no repository's config is read) when git is on `PATH`, else by a parser of the same syntax (`_sandy_gitmodules_parse`).
- **Linked-worktree admin dirs** are still refused by the structural check (they have no `objects/`). The place #582 adds them as a recognized relationship is marked in `_sandy_gitdir_judge`.
- **A gitdir in `$SANDY_HOME`** is refused outright, as #209 refuses a link there.
- **Anything else** asks once: the prompt names the `gitdir:` value and the physical directory, says it is not a submodule gitdir of a repository containing the workspace, and that approved it is mounted read-write, giving the agent read-write access to that repository's history (config, hooks and info stay read-only). A `y` writes `$SANDBOX_DIR/.sandy-approved-gitdir` (never mounted; replaced whole with `mktemp` + `mv`, a link at its path removed first): a `# approved: <UTC>` line and one line holding the workspace's and the target's physical paths, hex-encoded. Only the latest approval is kept, so a different target asks again (naming the approved one). A headless or non-TTY launch refuses (exit `1`, the daemon `.fatal` marker, so `--start` exits `6`), saying how to approve. `SANDY_AUTO_APPROVE_PRIVILEGED` does not answer it. `--reset-sandbox --keep-approvals` keeps the file.
- The mount source of an outside gitdir is the physical directory judged, so re-pointing a link along the spelled path between the gate and `docker run` cannot mount another directory. The container path stays the spelled one.
- `--approvals` reports the verdict under the existing `symlinks` gate (still three gates), as an added `gitdir` member, and that gate's `status` is the more severe of the two.
- The `.git` file is now read as git reads it (`_sandy_gitfile_read`: content after `gitdir: `, trailing newlines and carriage returns removed). Before, every whitespace character was deleted from the value, so a submodule whose name holds a space was refused as "not a git directory".
