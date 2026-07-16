## MODIFIED Requirements

### Requirement: Resource Limit Enforcement
The server SHALL enforce all configured `ResourceLimits` fields (see `resource-limits/spec.md` for the complete field table and defaults). Default values apply when not overridden. (REQ-RPL-047a..047i)

#### Scenario: Non-interruptible eval releases slot on timeout
- **WHEN** an eval exceeds `max_eval_time_ms` due to a non-interruptible operation (tight `ccall`, BLAS, native)
- **THEN** the eval slot is released and the client receives a timeout response
- **AND** the eval task continues as a zombie (logged server-side) until it completes or the process exits
