# Project Context

## Purpose
REPLy.jl is intended to provide a network-accessible REPL implemented in Julia.
At the moment, the repository is still specification-heavy: OpenSpec capabilities
and the external specification document define the expected system before the
full Julia package scaffold is in place.

## Domain Model

REPLy is a structured message protocol for REPL interaction, inspired by
Clojure's nREPL. The core abstraction is a **session** — an isolated evaluation
context backed by an anonymous Julia Module. Clients send **operations** (`eval`,
`complete`, `lookup`, etc.) over a **transport** (TCP, Unix socket) using a flat
JSON envelope. Operations flow through a composable **middleware** pipeline
before reaching their handler. The protocol supports **streaming responses** — a
single request may produce multiple response messages before a terminal `done`
message.

The **MCP adapter** is the first reference client: it bridges the REPLy protocol
to the Model Context Protocol so AI assistants can evaluate Julia code.

## Capability Specs

The full external specification is in `Reply_jl_Specification_v1_3_1.md`. The
OpenSpec capability specs decompose it into focused, independently modifiable
units:

| Capability | Purpose | Key Req IDs |
|---|---|---|
| `protocol` | Wire format, message structure, status flags, encoding | REQ-RPL-001..009 |
| `core-operations` | Built-in operations (`eval`, `clone`, `close`, etc.) | REQ-RPL-010..020 |
| `session-management` | Light sessions, lifecycle, idle timeout, ephemeral | REQ-RPL-030..038 |
| `transport` | TCP, Unix socket, abstract interface, multi-listener | REQ-RPL-040..043 |
| `middleware` | middleware pipeline, descriptors, stack validation | REQ-RPL-050..056 |
| `security` | Permissions, resource enforcement, audit, shutdown | REQ-RPL-041, 047, 048 |
| `error-handling` | Error format, status flags, exception serialization | REQ-RPL-061, 063 |
| `mcp-adapter` | MCP-to-REPLy bridge, tool catalog, error mapping | REQ-RPL-070..076 |
| `resource-limits` | ResourceLimits struct definition, defaults | REQ-RPL-047 |

### Cross-Reference Map

```
protocol ← (referenced by all specs for wire-format rules)
    ↑
core-operations → session-management (clone, close, ls-sessions via SessionMiddleware)
    ↑               ↑
middleware ─────────┘ (SessionMiddleware handles session ops)
    ↑
security → resource-limits (enforcement of limits defined there)
    ↑         ↑
transport ──┘ (Unix socket permissions, multi-listener)

error-handling → protocol (cross-refs done semantics)
              → core-operations (cross-refs malformed input)

mcp-adapter → error-handling (interrupted → isError mapping rationale)
           → core-operations (maps Reply ops to MCP tools)
```

## Requirement Prioritization

Unless a requirement says otherwise, capability-spec requirements are classified as:
- **P0 (v1.0 mandatory):** required for the v1.0 release and release-gating in validation/testing plans.
- **P1 (v1.0 stretch):** targeted for v1.0 when feasible, but may slip without invalidating the core release.
- **P2 (post-v1.0):** explicitly deferred or future-facing.

Priority exceptions SHOULD be documented in the relevant capability spec or implementation plan when a requirement needs to deviate from this default classification.

## Requirement ID Scheme

Requirements use multiple ID prefixes reflecting their origin in the spec:

| Prefix | Category | Examples |
|---|---|---|
| `REQ-RPL-NNN` | Protocol requirements | REQ-RPL-001 (flat envelope), REQ-RPL-011 (`eval`) |
| `ARCH-NNN` | Architectural decisions | ARCH-001 (empty vector guard), ARCH-006 (handler caching) |
| `FAIL-NNN` | Failure-mode requirements | FAIL-007 (audit log rotation) |
| `BIZ-NNN` | Business-logic requirements | BIZ-008 (orphan `eval` cleanup) |
| `MATH-NNN` | Boundary/math requirements | MATH-007 (rate limit minimum warning) |
| `FORM-NNN` | Formal correctness | FORM-001 (session state machine) |
| `HUM-NNN` | Human factors | HUM-002 (MCP session semantics) |

## Reference Hardware

Performance requirements (e.g., session creation latency) reference this
baseline:

- **OS:** Linux x86_64
- **CPU:** 4+ physical cores, single-core PassMark >= 2500
- **RAM:** >= 8 GB

## Tech Stack
- Julia (>= 1.11 for task-scoped `redirect_stdout`)
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

## Important Constraints
- The repository may temporarily lack a full Julia package scaffold.
- Tooling should degrade gracefully when code, tests, or coverage inputs do not
  yet exist.
- Spec files and workflow metadata are first-class project artifacts.

## External Dependencies
- GitHub for source hosting and CI
- `wai`, `bd`, and `openspec` CLIs in contributor environments
- `prek`, `typos`, and `vale` for local hygiene automation
