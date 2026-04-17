# Transport Layer

_Version: 1.1 — 2026-04-17_

## Purpose

Specify the abstract transport interface and concrete implementations (TCP, Unix domain socket, newline-delimited JSON) that carry Reply messages between clients and server. A new transport implementing four methods works without any changes to middleware, sessions, or operations.

## Requirements

### Requirement: Abstract Transport Interface
The transport layer SHALL be abstracted behind four methods: `send!(transport, msg)`, `receive(transport)`, `close(transport)`, and `isopen(transport)`. A new transport implementing these four methods SHALL function with no changes to middleware, sessions, or operations. (REQ-RPL-002, REQ-RPL-040)

#### Scenario: Custom transport works unchanged with core
- **WHEN** a `WebSocketTransport` implementing the four abstract methods is added
- **THEN** it works with the existing middleware pipeline and sessions without modification

### Requirement: receive Postcondition
`receive(transport)` SHALL return a fully-parsed `Dict` or `nothing`. It SHALL NOT propagate parse exceptions from partial reads or disconnects. Invalid-but-complete JSON that is not an object SHOULD be logged and skipped. (REQ-RPL-040b)

#### Scenario: Partial read on disconnect returns nothing
- **WHEN** a client disconnects mid-message
- **THEN** `receive` returns `nothing` instead of propagating a parse error

#### Scenario: Non-object JSON is skipped
- **WHEN** a line of valid JSON that is not an object arrives (e.g., `"[1,2,3]"`)
- **THEN** it is logged and skipped, not propagated as an exception

### Requirement: TCP Transport
The server SHALL support TCP connections on a configurable host and port (default `5555`). `send!` SHALL be thread-safe via a lock. (REQ-RPL-042, REQ-RPL-043)

#### Scenario: TCP server accepts connections
- **WHEN** a client opens a TCP connection to `127.0.0.1:5555`
- **THEN** the server accepts and begins processing messages

#### Scenario: Port conflict is logged
- **WHEN** port `5555` is already in use at startup
- **THEN** the server logs an informative error

### Requirement: Unix Domain Socket Transport
The server SHALL support Unix domain socket connections. The socket SHALL be created with `umask(0o077)` before `listen()` and `chmod`'d to `0o600` after creation, closing the permission race window. (REQ-RPL-041)

#### Scenario: Socket file is owner-only
- **WHEN** the server starts with Unix socket transport
- **THEN** the socket file has permissions `0o600` and only the server's UID can connect

#### Scenario: umask prevents briefly-world-accessible socket
- **WHEN** the server calls `listen()` on the socket path
- **THEN** the socket is created with restrictive permissions from the start via umask wrapping

#### Scenario: Stale socket removed at startup
- **WHEN** a stale socket file exists at the configured path
- **THEN** it is removed before creating the new socket

### Requirement: Newline-Delimited JSON Transport
The default JSON transport SHALL write each message as a single JSON object terminated by `\n`, using a lock for thread safety. (REQ-RPL-040)

#### Scenario: Message framing is newline-terminated
- **WHEN** the server sends a response
- **THEN** the encoded bytes end with exactly one `\n` byte

### Requirement: Transport Agnostic Protocol
Middleware, sessions, and core operations SHALL have no dependency on any specific transport implementation. (REQ-RPL-002)

#### Scenario: Same middleware stack works across transports
- **WHEN** two server instances start—one TCP, one Unix socket—with the same middleware stack
- **THEN** both handle identical protocol operations identically

### Requirement: Multi-Listener Support
The server SHALL support running multiple listeners concurrently (e.g., TCP and Unix socket simultaneously). Resource limits (max_sessions, max_concurrent_evals, rate_limit_per_min) SHALL apply globally across all listeners, not per-listener. Where listener-specific encodings are configured, each listener SHALL use its configured encoding independently. (REQ-RPL-042)

#### Scenario: TCP and Unix socket listeners run simultaneously
- **WHEN** the server starts with both a TCP listener on port 5555 and a Unix socket listener
- **THEN** clients can connect via either transport and both share the same session pool and middleware stack

#### Scenario: Resource limits are global across listeners
- **WHEN** `max_sessions` is 100 and 60 sessions exist via TCP and 40 via Unix socket
- **THEN** a new `clone` on either transport returns `{"status":["done","error","session-limit-reached"],"err":"Session limit reached"}`
