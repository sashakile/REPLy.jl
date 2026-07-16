## ADDED Requirements

### Requirement: First-Class Client
REPLy SHALL provide a `REPLy.Client` type that implements the wire protocol: connection management, message framing, send, receive, and disconnect. The client SHALL support TCP and Unix socket transports. (ARCH-017)

#### Scenario: Client connects and sends eval
- **WHEN** a user creates a `REPLy.Client`, connects to a REPLy server, and sends an eval request
- **THEN** the client receives the response stream and returns the terminal result

#### Scenario: Client handles connection error
- **WHEN** a user attempts to connect to a non-existent server
- **THEN** the client raises a descriptive error (not a protocol-level crash)
