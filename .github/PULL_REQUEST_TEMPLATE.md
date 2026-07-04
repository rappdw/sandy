<!--
  Thanks for contributing to sandy! Please keep the change focused and remember
  the hard constraint: `sandy` stays a single self-contained, `--upgrade`-compatible
  bash script. See CONTRIBUTING.md.
-->

## Summary

<!-- What does this change do, and why? -->

## Linked issue

<!-- e.g. Closes #123 -->

## Checklist

- [ ] Ran **both** test suites on the host (not inside sandy):
      `bash test/run-tests.sh` and `bash test/run-integration-tests.sh`
      <!-- paste a one-line result / note which platform + Docker runtime -->
- [ ] Ran the regen `--check` scripts (`test/regen-config-docs.sh --check`,
      `test/regen-template.sh --check`) — no drift
- [ ] Updated `SPECIFICATION.md` / `README.md` / `CLAUDE.md` if behavior changed
      (flags, config keys, generated files, JSON schemas, platform logic)
- [ ] If I added/changed/re-tiered a config key: updated `_sandy_key_metadata`
      **and** the tier arrays, then regenerated the config docs
- [ ] `sandy` is still a single file (no split, no new runtime dependency)
- [ ] Commits are focused, branched from `main`

## Notes for the reviewer

<!-- Anything platform-specific, follow-up work, or context worth calling out. -->
