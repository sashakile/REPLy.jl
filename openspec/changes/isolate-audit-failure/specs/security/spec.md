## ADDED Requirements

### Requirement: Audit Write Failure Degradation
Audit-log write failures SHALL NOT propagate to the request path. If `record_audit!` fails (e.g., disk full), the server SHALL log a warning and continue; the eval result is returned to the client as if the audit succeeded. (ARCH-004)

#### Scenario: Disk-full audit does not abort successful eval
- **WHEN** an eval completes successfully but the audit log write fails
- **THEN** the client receives the eval result, not an internal error