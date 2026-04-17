# MCP Adapter

_Version: 1.1 — 2026-04-17_

## Purpose

Specify the reference MCP adapter — the first client of the Reply protocol. It translates MCP `tools/call` invocations into Reply operations, manages a persistent default session, and maps Reply responses to MCP `CallToolResult` objects. The adapter is a protocol bridge, not a core server component.

## Requirements

### Requirement: MCP Adapter as Reply Client
The MCP adapter SHALL be a reference client that speaks MCP on the client-facing side and Reply (via Unix socket) on the server-facing side, translating `tools/call` invocations into Reply operations. (REQ-RPL-070)

#### Scenario: End-to-end MCP eval
- **WHEN** an MCP client calls `julia_eval` with `{"code":"1+1"}`
- **THEN** the adapter forwards it as a Reply `eval` op, collects the response stream, and returns `CallToolResult` with `content=[{"type":"text","text":"2"}]`

### Requirement: MCP Protocol Version Declaration
The adapter SHALL declare its supported MCP protocol version (`2024-11-05` or latest compatible) in the `initialize` response `protocolVersion` field. Transport SHALL default to `stdio`. (REQ-RPL-071)

#### Scenario: Initialize declares protocol version
- **WHEN** an MCP client sends `initialize`
- **THEN** the adapter responds with `protocolVersion:"2024-11-05"` (or current compatible)

### Requirement: MCP Tool Catalog
The adapter SHALL expose eight MCP tools: `julia_eval`, `julia_complete`, `julia_lookup`, `julia_load_file`, `julia_interrupt`, `julia_new_session`, `julia_list_sessions`, `julia_close_session`. (REQ-RPL-072)

#### Scenario: Tool list includes all eight tools
- **WHEN** an MCP client calls `tools/list`
- **THEN** all eight tools appear in the response

### Requirement: julia_eval Tool Schema and Behavior
The `julia_eval` tool SHALL accept `code` (required), `session`, `module`, and `timeout_ms` parameters. The adapter SHALL collect the complete Reply response stream before returning the `CallToolResult`. (REQ-RPL-073)

#### Scenario: julia_eval returns stdout as content
- **WHEN** `julia_eval` is called with `{"code":"println(\"hi\")"}`
- **THEN** the `CallToolResult` includes the stdout text as a content block

#### Scenario: julia_eval error sets isError
- **WHEN** code raises an exception
- **THEN** `CallToolResult.isError` is `true` and content includes the error message and stacktrace

### Requirement: Adapter Default Session
The adapter SHALL own a default session created at startup. When the MCP client omits `session`, the adapter SHALL route to the default persistent session — NOT ephemeral. (REQ-RPL-074)

#### Scenario: Omitted session uses persistent default
- **WHEN** `julia_eval` is called without a `session` argument
- **THEN** the adapter routes to its persistent default session; bindings persist across calls

#### Scenario: Ephemeral via sentinel value
- **WHEN** `julia_eval` is called with `"session":"ephemeral"`
- **THEN** the adapter sends a Reply `eval` with no `session` field (ephemeral mode) (REQ-RPL-074b)

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
