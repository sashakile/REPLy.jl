## ADDED Requirements

### Requirement: EvalRequest Parsed at Handler Boundary
The eval handler SHALL parse the raw request dict into a typed `EvalRequest` struct at the handler boundary. All semantic fields SHALL be validated once during parsing. Downstream code SHALL read from the typed struct, not re-fetch from the raw dict. (ARCH-010)

#### Scenario: Invalid EvalRequest rejected at boundary
- **WHEN** an eval request arrives with a missing `code` field
- **THEN** the parse step returns an error response before any handler logic runs