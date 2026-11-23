# Decisions: the lossy hex records, and release 2.11.0 (2026-11-23)

Decided by the maintainer on 2026-11-23 (plan row 38 follow-up).

## The defect

`_sandy_hex` encodes a path as `od -An -tx1 | tr -d ' \n'`. Without `-v`, `od` prints a repeated 16-byte line as `*`, and with `-An` the repeat count is lost. A path containing a run of 47 or more identical bytes therefore encodes to a hex string with a `*` in it. `_sandy_unhex` rejects such a string, and two different paths can encode to the same one.

The effects, in v2.9.0 through v2.10.1, for a workspace whose absolute path contains such a run:

- `_sandy_protected_hash_changed` skips every `#hash` record (`_sandy_unhex … || continue`). A rewrite of a protected file is then not reported at session end. On a case-insensitive macOS file system that record is the only check that catches a protected file rewritten through another spelling. Files outside the lock list, such as `.npmrc`, `.tool-versions` and `.gitconfig`, have no other check, and for such a workspace the files on the lock list are not locked either (next item).
- On macOS, the lock pass writes the `.uchg-locked` record and then decodes each entry from it before calling `chflags uchg`. An entry containing `*` cannot be decoded, so that file is silently not locked. The entry is dropped from the record, and the lock notice leaves the file out. No file is left immutable. `_sandy_uchg_unlock` warns `Not unlocking an entry sandy cannot read … (kept)` only if a launch died between those two record writes and left such an entry behind. (Corrected 2026-11-23 while implementing: the first draft said the file stays immutable. Measured by §257 against v2.10.1, where `.envrc` and `.git/config` were not locked during the run.)
- `.commondir-seeded` records containing `*` are never cleaned up. This is harmless.
- Collisions between `#envfile`, `#gitdir` and `#gitlink` keys can hide a change only when a related path already existed at launch.

It was found during the row 38 work (#591) and confirmed by that PR's independent security review. That review rated it medium impact and low likelihood. The plausible attack is a repository whose name holds a long run of one character, cloned under its default name, with an agent made to rewrite an unlocked protected file.

| # | Decision | Choice | Deciding reason |
|---|----------|--------|-----------------|
| 1 | Disclosure | An ordinary public bug-fix PR, with no private security advisory. | The maintainer judged the exposure low. It needs a path with a long repeated-byte run, the most sensitive files are also locked on macOS, and the defect only silences detection; it lifts no read-only mount. A private advisory's process (draft advisory, temporary private fork, a ruleset bypass) was not worth that. |
| 2 | Fix scope | `od -v` in `_sandy_hex`'s fallback, which makes every hex record exact. Records already written by v2.9.0–2.10.1 that contain `*` are not recovered. | No legacy-format code to carry. A stuck lock already produces a warning, and the affected paths are rare. `od -v` changes output only for strings that hit the defect, so every other record is byte-identical across versions. Reading records across versions only gets louder (false REPLACED or created reports), never quieter. |
| 3 | Release | 2.11.0, cut once #591 (fewer processes per launch) and the `od -v` fix have both merged. It also carries #588–#590 (parallel host suite, the bash 5 requirement, the doctor warning). | One release. A minor version fits a new platform requirement and a new doctor warning, under the versioning rule in CLAUDE.md. The `od -v` fix is built on #591, which rewrote `_sandy_hex`; #591's bash fast path avoids repeated rows only to match `od` without `-v`, and that restriction can go with the fix. |

Options considered and not taken:

- **1:** a private advisory handled like GHSA-wjw9-4x75-x5vx, whose detection this defect weakens; a public PR followed by an advisory published afterwards.
- **2:** recovering old `.uchg-locked` entries by matching the legacy hex of each `_sandy_uchg_targets` candidate (exact, about 15 lines); a warning naming the manual `chflags nouchg` step instead.
- **3:** 2.10.2 now with what is on `main`, then 2.11.0 later; 2.10.2 with `od -v` alone, ahead of #591.

Correction to the reasons above (2026-11-23, found while implementing; the decisions themselves are unchanged and are the maintainer's to revisit): for an affected workspace the macOS lock is skipped too (see the effects list), so in decision 1 "the most sensitive files are also locked on macOS" does not hold for that workspace. Its protected files there had neither the lock nor the content check. In decision 2, no lock is ever left stuck, so there is nothing for a recovery to unlock. That makes the no-recovery choice simpler, not riskier.

Implementation (2.11.0): `_sandy_hex` passes `-v` to `od`, and its bash fast path now covers every all-ASCII string, since without the collapse there is nothing to decline. `od -v` output equals `od` output for every string that never collapsed. The other `od` calls in `sandy` take `-v` too: the link-target hex in `_sandy_tree_fingerprint` and the `/dev/urandom` fallbacks of the launch id, the `--provision` id and the session nonce. The fallbacks read at most 16 bytes, one `od` line, so their output is unchanged. Test: host-suite §257.
