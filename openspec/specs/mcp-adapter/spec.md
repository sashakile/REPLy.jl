---
id: spec
kind: intent
statement: "WHEN the migrated spec is elaborated, THE author SHALL replace this scaffold statement with the real requirement."
---

## Constraints

| id | kind | expr | traces_to |
|----|------|------|------------|
| MCP_REFERENCE_CLIENT | invariant | the adapter is a protocol bridge speaking MCP on the client-facing side and Reply (via Unix socket) on the server-facing side; `julia_eval` forwards as a Reply `eval` op and the full response stream is collected before any `CallToolResult` is returned | [[spec]] |
| MCP_PROTOCOL_VERSION | invariant | the `initialize` response declares `protocolVersion: 2024-11-05` or the latest compatible version, and the adapter transport defaults to `stdio` | [[spec]] |
| EIGHT_TOOL_CATALOG | invariant | the adapter exposes exactly `julia_eval`, `julia_complete`, `julia_lookup`, `julia_load_file`, `julia_interrupt`, `julia_new_session`, `julia_list_sessions`, `julia_close_session` | [[spec]] |
| EVAL_SCHEMA_STDIN_OFF | invariant | `julia_eval` accepts `code` (required) plus `session`, `module`, and `timeout_ms`; the adapter sends Reply `allow-stdin:false` and collects the complete stream before returning | [[spec]] |
| STDIN_EOF_SERVING | invariant | with `allow-stdin:false` Reply serves stdin at EOF: a bare `readline()` completes immediately with an empty string, and a stdin read that requires bytes raises `EOFError` | [[spec]] |
| PERSISTENT_DEFAULT_SESSION | invariant | the adapter owns a default session created at startup; an omitted session argument routes there, never to ephemeral mode | [[spec]] |
| EPHEMERAL_SENTINEL | invariant | a `session` argument of the ephemeral sentinel omits the Reply `session` field | [[spec]] |
| STATUS_PRECEDENCE | invariant | mapping precedence over the terminal status set is `timeout`, then `interrupted`, then `error`, then success | [[spec]] |
| NON_SUCCESS_IS_ERROR | invariant | every non-success terminal status maps to `isError = true` because the MCP tool call produced no successful result | [[spec]] |

## Model

### States

- `cold`
- `ready`
- `routing`
- `mapped`

### Transitions

| id | from | to | guard |
|----|------|----|--------|
| declare_capabilities | cold | ready | [[spec.MCP_PROTOCOL_VERSION]] |
| route_tool_call | ready | routing | [[spec.EVAL_SCHEMA_STDIN_OFF]] |
| collect_stream | routing | routing | [[spec.MCP_REFERENCE_CLIENT]] |
| map_terminal_status | routing | mapped | [[spec.STATUS_PRECEDENCE]] |

## Properties

| id | kind | derives_from | generator | predicate |
|----|------|--------------|-----------|------------|
| initialize_declares_version | unit | [[spec.MCP_PROTOCOL_VERSION]] | `test/unit/mcp_adapter_test.jl` | the initialize payload carries `protocolVersion: 2024-11-05` with empty capabilities and REPLy serverInfo |
| catalog_matches_spec_order | unit | [[spec.EIGHT_TOOL_CATALOG]] | `test/unit/mcp_adapter_test.jl` | `mcp_tools()` returns exactly the eight tool names in spec order with each tool's input schema fields |
| eval_request_carries_stdin_off | unit | [[spec.EVAL_SCHEMA_STDIN_OFF]] | `test/unit/mcp_adapter_test.jl` | `mcp_eval_request` emits `allow-stdin:false`, routes an omitted session to the default, and omits the session field for the ephemeral sentinel |
| full_stream_before_result | unit | [[spec.MCP_REFERENCE_CLIENT]] | `test/unit/mcp_adapter_test.jl` | `collect_reply_stream` returns only after the terminal done status arrives (buffering interleaved ids), and `reply_stream_to_mcp_result` throws for a stream missing it |
| stdin_eof_fail_fast | unit | [[spec.STDIN_EOF_SERVING]] | `test/unit/mcp_server_test.jl` | an MCP `julia_eval` of `readline()` completes in under ten seconds with an empty value, while `read(stdin, Char)` yields `isError = true` naming `EOFError` |
| default_session_binds_persist | unit | [[spec.PERSISTENT_DEFAULT_SESSION]] | `test/unit/mcp_server_test.jl` | two `julia_eval` calls without a session argument share bindings — the second call observes the binding created by the first |
| ephemeral_bindings_vanish | unit | [[spec.EPHEMERAL_SENTINEL]] | `test/unit/mcp_server_test.jl` | a binding created in an ephemeral eval is not visible to a later default-session eval (`UndefVarError`) |
| timeout_maps_to_eval_timed_out | unit | [[spec.STATUS_PRECEDENCE]] | `test/unit/mcp_adapter_test.jl` | a `done`-`error`-`timeout` terminal yields exactly the content `Evaluation timed out` |
| interrupted_maps_to_interrupted | unit | [[spec.STATUS_PRECEDENCE]] | `test/unit/mcp_adapter_test.jl` | a `done`-`interrupted` terminal yields exactly the content `Interrupted` |
| session_not_found_names_session | unit | [[spec.NON_SUCCESS_IS_ERROR]] | `test/unit/mcp_adapter_test.jl` | a `done`-`error`-`session-not-found` terminal yields `isError = true` with content naming the unknown session |
| error_includes_stacktrace | unit | [[spec.NON_SUCCESS_IS_ERROR]] | `test/unit/mcp_adapter_test.jl`, `test/unit/mcp_server_test.jl` | a `done`-`error` terminal yields `isError = true` whose content includes the err text and the stacktrace block |

# MCP Adapter

_Version: 1.2 — 2026-10-02_

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
The `julia_eval` tool SHALL accept `code` (required), `session`, `module`, and `timeout_ms` parameters. The adapter SHALL send Reply `allow-stdin:false` for `julia_eval` calls and SHALL collect the complete Reply response stream before returning the `CallToolResult`. (REQ-RPL-073)

#### Scenario: julia_eval returns stdout as content
- **WHEN** `julia_eval` is called with `{"code":"println(\"hi\")"}`
- **THEN** the `CallToolResult` includes the stdout text as a content block

#### Scenario: julia_eval error sets isError
- **WHEN** code raises an exception
- **THEN** `CallToolResult.isError` is `true` and content includes the error message and stacktrace

#### Scenario: stdin-blocking code fails fast in MCP
- **WHEN** `julia_eval` is called on code that executes `readline()` and the adapter sends `allow-stdin:false`
- **THEN** Reply serves stdin at EOF: the eval completes immediately without hanging for interactive input (a bare `readline()` returns `""`), and any stdin read that requires bytes (e.g. `read(stdin, Char)`) raises `EOFError`, which maps to `CallToolResult.isError = true`

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
