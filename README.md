# REPLy.jl
[![tracked with wai](https://img.shields.io/badge/tracked%20with-wai-blue)](https://github.com/charly-vibes/wai)

> **WARNING: This project is entirely LLM-generated code. It has not been manually reviewed or audited. Use at your own risk.**

A network REPL server for Julia — think [nREPL](https://nrepl.org/) for Clojure, but for Julia. REPLy.jl exposes a Julia REPL over a socket-based protocol so that editors and tooling can connect, evaluate code, and inspect results interactively.

## repo hygiene

This repository is configured with lightweight automation for local and CI checks.

### Common commands

- `just bootstrap` — install git hooks with `prek` (including a pre-push test gate)
- `just hooks` — run git-hook checks on all files
- `just lint` — run spelling and prose checks
- `just test` — run Julia tests when package files exist
- `just coverage` — run Julia coverage when package files exist
- `just check` — lint + test + coverage
- `just full-check` — `just check` plus OpenSpec and `wai` health checks

### Tooling added

- `justfile` for common commands
- `prek.toml` for git hook management, including running `just test` on `pre-push`
- `.editorconfig` for formatting conventions
- `_typos.toml` for spelling checks
- `.vale.ini` for prose linting
- `llm.txt` for AI-oriented repo context
- `.github/workflows/ci.yml` for CI
- `.devcontainer/devcontainer.json` for a reproducible dev environment
