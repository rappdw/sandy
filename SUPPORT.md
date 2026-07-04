# Getting help with sandy

## Start here

- **README** — installation, configuration, the full environment-variable and
  flag reference, and how each isolation layer works: [`README.md`](README.md).
- **`doctor.sh`** — checks your host for everything sandy needs (Docker daemon
  reachable, git, curl, `gh`, Claude credentials, `~/.local/bin` on PATH) and
  prints copy-pasteable fixes. It only reports; it never changes anything:

  ```sh
  curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/doctor.sh | bash
  ```
- **`sandy --version`** — confirm which version you're on before reporting
  anything. Sandy updates in place with `sandy --upgrade`.
- **Deeper reference** — `SPECIFICATION.md` (implementation detail),
  `SPEC_INTROSPECTION.md` (the `--print-schema` / `--print-state` /
  `--validate-config` contract), and `docs/security/` (threat model and
  isolation stress tests).

## Where to go

- **Bug reports** → open a GitHub **issue** using the bug-report template.
  Include `sandy --version`, your host OS and Docker runtime, and relevant
  `-vvv` output.
- **Questions, ideas, "is this supposed to work?"** → GitHub **Discussions**
  (or a feature-request issue if it's a concrete proposal).
- **Security vulnerabilities** → **do not** open a public issue. Follow
  [`SECURITY.md`](SECURITY.md): email **rappdw@gmail.com** or file a private
  GitHub security advisory.

This is a small project maintained on a best-effort basis — a clear, reproducible
report with the details above is the fastest path to a fix.
