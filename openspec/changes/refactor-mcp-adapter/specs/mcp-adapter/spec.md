---
id: spec
kind: intent
statement: "WHEN the migrated delta is elaborated, THE author SHALL replace this scaffold statement with the real requirement."
---

## Constraints

| id | kind | expr | traces_to |
|----|------|------|-----------|
| scaffold_constraint | invariant | `true` | [[spec]] |

## Model

### States

- `draft`

### Transitions

| id | from | to | guard |
|----|------|----|-------|
| scaffold_transition | draft | draft | [[spec.scaffold_constraint]] |

## Properties

| id | kind | derives_from | generator | predicate |
|----|------|--------------|-----------|-----------|
| scaffold_property | unit | [[spec.scaffold_constraint]] | `todo()` | `true` |

## ADDED Requirements

### Requirement: In-Process Bridge
The MCP adapter SHALL support an in-process bridge mode that calls the server's `handler` closure directly, avoiding a TCP loopback hop. A real-socket mode SHALL be retained as a configurable option for out-of-process deployment. (ARCH-015)

#### Scenario: In-process mode bypasses TCP
- **WHEN** the MCP adapter is in in-process mode
- **THEN** requests are dispatched to the handler closure without creating a TCP connection

### Requirement: Modular MCP Package
The MCP adapter SHALL be split into focused modules: `mcp/tools.jl` (tool catalog), `mcp/requests.jl` (request building), `mcp/results.jl` (result adaptation), and `mcp/server.jl` (server protocol). (ARCH-016)

#### Scenario: Module imports resolve after split
- **WHEN** the MCP adapter is loaded
- **THEN** each sub-module can be imported independently

## Requirements

### Requirement: In-Process Bridge
The MCP adapter SHALL support an in-process bridge mode that calls the server's `handler` closure directly, avoiding a TCP loopback hop. A real-socket mode SHALL be retained as a configurable option for out-of-process deployment. (ARCH-015)

#### Scenario: In-process mode bypasses TCP
- **WHEN** the MCP adapter is in in-process mode
- **THEN** requests are dispatched to the handler closure without creating a TCP connection

### Requirement: Modular MCP Package
The MCP adapter SHALL be split into focused modules: `mcp/tools.jl` (tool catalog), `mcp/requests.jl` (request building), `mcp/results.jl` (result adaptation), and `mcp/server.jl` (server protocol). (ARCH-016)

#### Scenario: Module imports resolve after split
- **WHEN** the MCP adapter is loaded
- **THEN** each sub-module can be imported independently
