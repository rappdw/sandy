---
name: Bug report
about: Something in sandy doesn't work as documented
title: "[bug] "
labels: bug
assignees: ''
---

<!--
  SECURITY ISSUES: do NOT file them here. See SECURITY.md — email rappdw@gmail.com
  or open a private GitHub security advisory. A public issue discloses the
  weakness before there's a fix.
-->

## What happened

<!-- A clear description of the bug and what you expected instead. -->

**Expected:**

**Actual:**

## Environment

- `sandy --version`:
- Host OS (and version): <!-- e.g. macOS 15.4 / Ubuntu 24.04 -->
- Docker runtime: <!-- Docker Desktop / OrbStack / Colima / Rancher Desktop / Lima -->
- Agent(s) used (`SANDY_AGENT`): <!-- claude / gemini / codex / opencode / a combo -->
- Egress mode: <!-- SANDY_EGRESS_STRICT / SANDY_EGRESS_NO_ISOLATION / SANDY_EGRESS_PROXY, or default -->
- Other relevant config: <!-- skill packs, SANDY_SSH, local-LLM, .sandy/config keys, etc. -->

## Steps to reproduce

1.
2.
3.

<!-- If it's config-related, the minimal `.sandy/config` + workspace layout that
     triggers it is the most useful thing you can include. -->

## Verbose output

<!--
  Re-run with `-vvv` and paste the relevant part. Sandy REDACTS secret VALUES in
  `-vvv` output, but please still scrub anything sensitive (paths, hostnames,
  tokens) before pasting.
-->

```
(paste relevant -vvv output here)
```

## Anything else

<!-- Screenshots, `sandy --print-state` output, workarounds you've tried, etc. -->
