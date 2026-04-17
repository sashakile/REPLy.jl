# Project Context

## Purpose
REPLy.jl is intended to provide a network-accessible REPL implemented in Julia.
At the moment, the repository is still specification-heavy: OpenSpec capabilities
and the external specification document define the expected system before the
full Julia package scaffold is in place.

## Tech Stack
- Julia
- OpenSpec for executable/spec-driven project documentation
- wai for reasoning, handoffs, and workflow guidance
- beads (`bd`) for issue tracking
- GitHub Actions for CI

## Project Conventions

### Code Style
- Use `.editorconfig` as the baseline formatting contract.
- Prefer small, composable scripts and `just` recipes for repo automation.
- Keep automation commands safe to run before a full package scaffold exists.

### Architecture Patterns
- Treat `openspec/specs/` as the source of truth for capability boundaries.
- Prefer incremental implementation that follows the existing capability split
  rather than introducing large unstructured features.

### Testing Strategy
- Follow TDD when implementing package code.
- `just test` and `just coverage` should pass once `Project.toml` and
  `test/runtests.jl` exist.
- Until then, quality gates focus on repo hygiene, specification quality, and
  documentation linting.

### Git Workflow
- Track work in beads issues.
- Use `wai` to preserve reasoning and session continuity.
- Keep changes small and push them once local checks pass.

## Domain Context
This repository is for a network REPL system. Existing capability specs cover
transport, protocol, middleware, session management, security, error handling,
and MCP adapter concerns.

## Important Constraints
- The repository may temporarily lack a full Julia package scaffold.
- Tooling should degrade gracefully when code, tests, or coverage inputs do not
  yet exist.
- Spec files and workflow metadata are first-class project artifacts.

## External Dependencies
- GitHub for source hosting and CI
- `wai`, `bd`, and `openspec` CLIs in contributor environments
- `prek`, `typos`, and `vale` for local hygiene automation
