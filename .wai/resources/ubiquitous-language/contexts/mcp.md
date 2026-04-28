# MCP Adapter Context

Scope: the protocol bridge that exposes REPLy as a set of Model Context
Protocol (MCP) tools. This context translates between MCP concepts and REPLy
concepts; it does not introduce new domain logic.

---

## Entities & Value Objects

| Term | Definition |
|------|-----------|
| **MCP Client** | A Model Context Protocol consumer (e.g., Claude, another AI agent) that calls tools via the MCP protocol. |
| **MCP Tool** | A callable operation exposed to MCP clients. Each REPLy operation is wrapped as one MCP tool. |
| **MCP Tool Call** | An invocation of a tool by an MCP client, carrying input parameters. |
| **Tool Schema** | The MCP-side description of a tool's input parameters: names, types, and documentation strings. |
| **Tool Catalog** | The full list of tools the adapter exposes. |
| **Call Tool Result** | The MCP response shape: `{ isError: bool, content: [{ type: "text", text: "…" }] }`. |
| **Default Session** | A persistent REPLy session created by the adapter at startup. Used when the MCP client omits a `session` parameter. State accumulates across all calls within the adapter's lifetime. |
| **Ephemeral Sentinel** | The special value `"session": "ephemeral"` that an MCP client can pass to force ephemeral (per-call, no state) evaluation. |
| **MCP Transport** | The MCP-level transport. Default: stdio. Also supports HTTP/SSE. |
| **Error Mapping** | The translation from REPLy status flags to MCP's binary `isError: true|false`. |

## Tool Catalog

| MCP Tool | REPLy Op |
|----------|----------|
| `julia_eval` | `eval` |
| `julia_complete` | `complete` |
| `julia_lookup` | `lookup` |
| `julia_new_session` | `clone` |
| `julia_list_sessions` | `ls-sessions` |
| `julia_close_session` | `close` |
| `julia_interrupt` | `interrupt` |
| `julia_load_file` | `load-file` |

## Operations (verbs)

| Term | Definition |
|------|-----------|
| **Initialize** | Declare the MCP protocol version and tool catalog to the client at connection time. |
| **Call Tool** | Receive an MCP tool/call; translate it to a REPLy request; collect the response stream; return a `CallToolResult`. |
| **Collect Response Stream** | Read all REPLy response messages sharing the same `id` until `done` is received. |
| **Map Reply Response** | Convert REPLy `status` / `value` / `err` fields to MCP `{ isError, content }`. |
| **Create Default Session** | At adapter startup, `clone` a persistent session; store the ID for use when the client omits `session`. |
| **Route Omitted Session** | When a client call lacks a `session` parameter, substitute the default session ID. |

## Error Mapping Asymmetry

REPLy has a rich error taxonomy; MCP has only `isError: true|false`. The adapter maps as follows:

| REPLy status | `isError` |
|-------------|-----------|
| `done` (only) | `false` |
| `done` + `interrupted` | `true` (MCP treats interruption as an error) |
| `done` + `error` + anything | `true` |

This is an asymmetry: REPLy's `interrupted` is not an error at the protocol level, but MCP has no way to express "stopped but not failed", so the adapter maps it to `isError: true`.

## Stdin Blocking Prevention

The adapter always sends `allow-stdin: false` with every `julia_eval` call. This causes any `readline()` call inside the eval to raise `EOFError` immediately instead of hanging the MCP client indefinitely.

## Session Semantics in the Adapter

- **Default Session** (persistent): state accumulates across all `julia_eval` calls — behaves like a long-running REPL session.
- **Ephemeral** (`"session": "ephemeral"`): each call starts fresh with no prior state.
- The adapter owns the default session's lifetime; it is not exposed for the client to close directly.
