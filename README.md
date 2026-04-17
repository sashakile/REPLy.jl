# REPLy.jl
[![tracked with wai](https://img.shields.io/badge/tracked%20with-wai-blue)](https://github.com/charly-vibes/wai)

Network REPL in Julia.

## repo hygiene

This repository is configured with lightweight automation for local and CI checks.

### Common commands

- `just bootstrap` — install git hooks with `prek`
- `just hooks` — run git-hook checks on all files
- `just lint` — run spelling and prose checks
- `just test` — run Julia tests when package files exist
- `just coverage` — run Julia coverage when package files exist
- `just check` — lint + test + coverage
- `just full-check` — `just check` plus OpenSpec and `wai` health checks

### Tooling added

- `justfile` for common commands
- `prek.toml` for git hook management
- `.editorconfig` for formatting conventions
- `_typos.toml` for spelling checks
- `.vale.ini` for prose linting
- `llm.txt` for AI-oriented repo context
- `.github/workflows/ci.yml` for CI
- `.devcontainer/devcontainer.json` for a reproducible dev environment
