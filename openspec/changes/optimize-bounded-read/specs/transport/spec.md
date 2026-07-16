## ADDED Requirements

### Requirement: Chunked Message Read
The message reading implementation SHALL use chunked reads (not byte-at-a-time) with a reusable per-connection buffer. (ARCH-020)

#### Scenario: Chunked read produces same result
- **WHEN** a message of any size is received
- **THEN** the chunked read produces the same message content as a byte-at-a-time read