---
id: spec
kind: intent
statement: "WHEN the MCP adapter selects execution ownership, THE adapter SHALL route tools through that backend and preserve its cleanup and loss semantics."
---

## Constraints

| id | kind | expr | traces_to |
|----|------|------|-----------|
| MCP_BACKEND | invariant | Host configuration selects ownership and one authoritative session backend | [[spec]] |
| MCP_LOSS | invariant | Runtime loss returns an error without replay and EOF respects endpoint ownership | [[spec]] |

## Model

### States

- `unconfigured`
- `configured`

### Transitions

| id | from | to | guard |
|----|------|----|-------|
| establish_contract | unconfigured | configured | [[spec.MCP_BACKEND]] |
| exercise_contract_1 | configured | configured | [[spec.MCP_BACKEND]] |
| exercise_contract_2 | configured | configured | [[spec.MCP_LOSS]] |

## Properties

| id | kind | derives_from | generator | predicate |
|----|------|--------------|-----------|-----------|
| mcp_backend_holds | unit | [[spec.MCP_BACKEND]] | `test/unit/mcp_server_test.jl` | stdio eval and lifecycle tools use the selected runtime while default attached behavior remains |
| mcp_loss_holds | unit | [[spec.MCP_LOSS]] | `test/unit/mcp_server_test.jl` | external host survives connect EOF; managed EOF closes owned runtime; loss does not resubmit tools |

## ADDED Requirements

### Requirement: MCP Execution Backend Selection
The MCP adapter SHALL accept host-selected attached, connect or managed execution configuration, preserving attached as the default. Connect SHALL use an explicitly provided TCP/Unix endpoint without owning its application. Managed SHALL launch an explicitly configured project through a dedicated supervisor and own its lifetime via an exclusive control pipe, applying execution-management disconnect and owner-death contracts. Execution configuration SHALL NOT be selectable by tool-call arguments. Existing use_socket SHALL remain an attached transport option; conflicting configuration SHALL fail before creating resources.

#### Scenario: Connect lifecycle operations use the selected endpoint
- **WHEN** an MCP adapter is configured for connect mode
- **THEN** eval and session lifecycle operations address that endpoint's state and MCP EOF disconnects without terminating the application

#### Scenario: Managed MCP ownership
- **WHEN** a managed MCP adapter reaches EOF
- **THEN** it initiates owned close, observes confirmed exit before reporting reclamation and retains unconfirmed worker charges; EOF cancellation does not promise universal reaping latency

#### Scenario: MCP owner crashes without EOF handling
- **WHEN** the managed MCP owner is killed without running adapter cleanup
- **THEN** the supervisor observes exclusive control-pipe EOF and initiates owned cleanup; subsequent supervisor death triggers OS-backed direct-worker termination

#### Scenario: Worker lost during a tool call
- **WHEN** managed execution produces runtime-lost or an interrupted/runtime-lost terminal
- **THEN** the adapter returns isError=true naming state loss and does not restart or replay the tool call

## MODIFIED Requirements

### Requirement: MCP Adapter as Reply Client
The MCP adapter SHALL be a reference client that speaks MCP on the client-facing side and translates tools/call into Reply operations through its selected backend: attached in-process or legacy TCP, connected TCP/Unix, or a managed supervisor endpoint. (REQ-RPL-070)

#### Scenario: End-to-end MCP eval
- **WHEN** an MCP client calls `julia_eval` with `{"code":"1+1"}`
- **THEN** the adapter forwards it as a Reply `eval` op, collects the response stream, and returns `CallToolResult` with `content=[{"type":"text","text":"2"}]`

#### Scenario: Backend state is authoritative
- **WHEN** an execution backend is explicitly selected
- **THEN** requests and lifecycle tools use that backend rather than an independent adapter-local session manager


### Requirement: Adapter Default Session
The adapter SHALL create or resolve its default persistent session through the selected backend at startup after that backend is ready; it SHALL NOT create an independent adapter-local default for a connected or managed backend. When the MCP client omits `session`, the adapter SHALL route to the default persistent session — NOT ephemeral. (REQ-RPL-074)

#### Scenario: Omitted session uses persistent default
- **WHEN** `julia_eval` is called without a `session` argument
- **THEN** the adapter routes to its persistent default session; bindings persist across calls

#### Scenario: Ephemeral via sentinel value
- **WHEN** `julia_eval` is called with `"session":"ephemeral"`
- **THEN** the adapter sends a Reply `eval` with no `session` field (ephemeral mode) (REQ-RPL-074b)

#### Scenario: Lost managed default is not recreated implicitly
- **WHEN** the managed worker holding the default session is retired
- **THEN** later tools receive runtime-lost until the host explicitly configures a newly launched runtime; no previous tool call is replayed


### Requirement: MCP Error Mapping
The adapter SHALL map Reply response statuses to MCP `CallToolResult` fields per the defined mapping. (REQ-RPL-076)

> **Note:** MCP's `CallToolResult` has only `isError: true|false` — it cannot distinguish error categories. The adapter maps all non-success terminations (including `interrupted`, which is not an error at the protocol level — see `error-handling/spec.md`) to `isError = true` because the MCP client's tool call did not produce a successful result.

#### Scenario: Successful eval maps to isError false
- **WHEN** Reply returns `status:["done"]` with `value`
- **THEN** `CallToolResult.isError = false`, content contains the value text

#### Scenario: Error response maps to isError true
- **WHEN** Reply returns `status:["done","error"]`
- **THEN** `CallToolResult.isError = true`, content contains `err` text and stacktrace

#### Scenario: Timeout maps to isError true
- **WHEN** Reply returns `status:["done","error","timeout"]`
- **THEN** `CallToolResult.isError = true`, content is `"Evaluation timed out"`

#### Scenario: Interrupted maps to isError true
- **WHEN** Reply returns `status:["done","interrupted"]`
- **THEN** `CallToolResult.isError = true`, content is `"Interrupted"`

#### Scenario: Session not found maps to isError true
- **WHEN** Reply returns `status:["done","error","session-not-found"]`
- **THEN** `CallToolResult.isError = true`, content indicates the unknown session

#### Scenario: Runtime loss augments interruption or timeout diagnostics
- **WHEN** a terminal contains runtime-lost, including alongside timeout or interrupted
- **THEN** isError is true and content includes an explicit runtime state-loss indication while preserving the primary timeout/interruption category

## Requirements

### Requirement: MCP Execution Backend Selection
The MCP adapter SHALL accept host-selected attached, connect or managed execution configuration, preserving attached as the default. Connect SHALL use an explicitly provided TCP/Unix endpoint without owning its application. Managed SHALL launch an explicitly configured project through a dedicated supervisor and own its lifetime via an exclusive control pipe, applying execution-management disconnect and owner-death contracts. Execution configuration SHALL NOT be selectable by tool-call arguments. Existing use_socket SHALL remain an attached transport option; conflicting configuration SHALL fail before creating resources.

#### Scenario: Connect lifecycle operations use the selected endpoint
- **WHEN** an MCP adapter is configured for connect mode
- **THEN** eval and session lifecycle operations address that endpoint's state and MCP EOF disconnects without terminating the application

#### Scenario: Managed MCP ownership
- **WHEN** a managed MCP adapter reaches EOF
- **THEN** it initiates owned close, observes confirmed exit before reporting reclamation and retains unconfirmed worker charges; EOF cancellation does not promise universal reaping latency

#### Scenario: MCP owner crashes without EOF handling
- **WHEN** the managed MCP owner is killed without running adapter cleanup
- **THEN** the supervisor observes exclusive control-pipe EOF and initiates owned cleanup; subsequent supervisor death triggers OS-backed direct-worker termination

#### Scenario: Worker lost during a tool call
- **WHEN** managed execution produces runtime-lost or an interrupted/runtime-lost terminal
- **THEN** the adapter returns isError=true naming state loss and does not restart or replay the tool call

### Requirement: MCP Adapter as Reply Client
The MCP adapter SHALL be a reference client that speaks MCP on the client-facing side and translates tools/call into Reply operations through its selected backend: attached in-process or legacy TCP, connected TCP/Unix, or a managed supervisor endpoint. (REQ-RPL-070)

#### Scenario: End-to-end MCP eval
- **WHEN** an MCP client calls `julia_eval` with `{"code":"1+1"}`
- **THEN** the adapter forwards it as a Reply `eval` op, collects the response stream, and returns `CallToolResult` with `content=[{"type":"text","text":"2"}]`

#### Scenario: Backend state is authoritative
- **WHEN** an execution backend is explicitly selected
- **THEN** requests and lifecycle tools use that backend rather than an independent adapter-local session manager


### Requirement: Adapter Default Session
The adapter SHALL create or resolve its default persistent session through the selected backend at startup after that backend is ready; it SHALL NOT create an independent adapter-local default for a connected or managed backend. When the MCP client omits `session`, the adapter SHALL route to the default persistent session — NOT ephemeral. (REQ-RPL-074)

#### Scenario: Omitted session uses persistent default
- **WHEN** `julia_eval` is called without a `session` argument
- **THEN** the adapter routes to its persistent default session; bindings persist across calls

#### Scenario: Ephemeral via sentinel value
- **WHEN** `julia_eval` is called with `"session":"ephemeral"`
- **THEN** the adapter sends a Reply `eval` with no `session` field (ephemeral mode) (REQ-RPL-074b)

#### Scenario: Lost managed default is not recreated implicitly
- **WHEN** the managed worker holding the default session is retired
- **THEN** later tools receive runtime-lost until the host explicitly configures a newly launched runtime; no previous tool call is replayed


### Requirement: MCP Error Mapping
The adapter SHALL map Reply response statuses to MCP `CallToolResult` fields per the defined mapping. (REQ-RPL-076)

> **Note:** MCP's `CallToolResult` has only `isError: true|false` — it cannot distinguish error categories. The adapter maps all non-success terminations (including `interrupted`, which is not an error at the protocol level — see `error-handling/spec.md`) to `isError = true` because the MCP client's tool call did not produce a successful result.

#### Scenario: Successful eval maps to isError false
- **WHEN** Reply returns `status:["done"]` with `value`
- **THEN** `CallToolResult.isError = false`, content contains the value text

#### Scenario: Error response maps to isError true
- **WHEN** Reply returns `status:["done","error"]`
- **THEN** `CallToolResult.isError = true`, content contains `err` text and stacktrace

#### Scenario: Timeout maps to isError true
- **WHEN** Reply returns `status:["done","error","timeout"]`
- **THEN** `CallToolResult.isError = true`, content is `"Evaluation timed out"`

#### Scenario: Interrupted maps to isError true
- **WHEN** Reply returns `status:["done","interrupted"]`
- **THEN** `CallToolResult.isError = true`, content is `"Interrupted"`

#### Scenario: Session not found maps to isError true
- **WHEN** Reply returns `status:["done","error","session-not-found"]`
- **THEN** `CallToolResult.isError = true`, content indicates the unknown session

#### Scenario: Runtime loss augments interruption or timeout diagnostics
- **WHEN** a terminal contains runtime-lost, including alongside timeout or interrupted
- **THEN** isError is true and content includes an explicit runtime state-loss indication while preserving the primary timeout/interruption category
