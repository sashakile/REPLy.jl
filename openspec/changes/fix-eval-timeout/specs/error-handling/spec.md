## MODIFIED Requirements

### Requirement: Error Status Flags
The server SHALL use distinct status flags for each error category so clients can programmatically distinguish failure modes. Canonical flags include `session-not-found`, `session-already-exists`, `session-quarantined`, `timeout`, `rate-limited`, `session-limit-reached`, `concurrency-limit-reached`, `path-not-allowed`, and `unknown-op`. (REQ-RPL-063)

#### Scenario: Session not found
- **WHEN** a request references a non-existent session
- **THEN** response has `{"status":["done","error","session-not-found"]}`

#### Scenario: Session already exists
- **WHEN** attempting to create or clone a session with a name alias that is already in use
- **THEN** response has `{"status":["done","error","session-already-exists"]}`

#### Scenario: Session quarantined
- **WHEN** a disallowed operation targets a named session permanently quarantined by a zombie eval
- **THEN** response has `{"status":["done","error","session-quarantined"],"err":"Session quarantined after eval timeout"}`

#### Scenario: Path not allowed
- **WHEN** attempting to load a file from a path blocked by the server's allowlist
- **THEN** response has `{"status":["done","error","path-not-allowed"]}`

#### Scenario: Eval timeout
- **WHEN** eval exceeds the time limit
- **THEN** response has `{"status":["done","error","timeout"]}` and `"err":"Eval timed out after N ms"`

#### Scenario: Rate limit exceeded
- **WHEN** a client exceeds `rate_limit_per_min`
- **THEN** response has `{"status":["done","error","rate-limited"]}` and `"err":"Rate limit exceeded"`

#### Scenario: Session limit exceeded
- **WHEN** a request would create a session beyond `max_sessions`
- **THEN** response has `{"status":["done","error","session-limit-reached"]}`

#### Scenario: Concurrency limit exceeded
- **WHEN** a request exceeds the bounded eval queue or zombie-held permits make an acquisition unable to progress
- **THEN** response has `{"status":["done","error","concurrency-limit-reached"]}`

#### Scenario: Unknown operation
- **WHEN** no middleware handles the op
- **THEN** response has `{"status":["done","error","unknown-op"]}`
