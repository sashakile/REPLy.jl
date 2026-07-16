## ADDED Requirements

### Requirement: Internal Error Boundary
Server-internal failures (e.g., resource exhaustion, assertion failures, unexpected exceptions) SHALL return a response with a stable error code and a correlation identifier. Full stack traces SHALL NOT be included in the response. (ARCH-005)

#### Scenario: Internal failure returns correlation id, not trace
- **WHEN** a server-internal error occurs
- **THEN** the response contains `"err":"Internal server error"`, a stable code (e.g., `"internal-error"` in status), and a `"correlation_id"` field
- **AND** the response does NOT contain `"stacktrace"` or absolute file paths

### Requirement: Server-Side Internal Error Logging
The server SHALL log the full stack trace and correlation identifier for every internal failure at `Logging.Error` level. (ARCH-006)

#### Scenario: Internal error logged with trace
- **WHEN** a server-internal error occurs with correlation id `"abc-123"`
- **THEN** the server log contains the full stack trace associated with correlation id `"abc-123"`

### Requirement: Opt-In Internal Trace Exposure
The server SHALL expose full internal error traces to clients when `expose_internal_traces` is set to `true` AND the connection is from a loopback address. (ARCH-007)

#### Scenario: Opt-in trace on loopback
- **WHEN** `expose_internal_traces=true` and the client is connected via loopback
- **THEN** the internal error response includes `"stacktrace"` and `"ex"`
