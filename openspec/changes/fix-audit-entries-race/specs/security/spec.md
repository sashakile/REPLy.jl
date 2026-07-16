## ADDED Requirements

### Requirement: Thread-Safe Audit Log Read Access
The audit log SHALL provide a thread-safe read accessor that locks `log.lock` before copying `log.entries`. (ARCH-003)

#### Scenario: Concurrent read during write does not race
- **WHEN** `audit_entries` is called while `record_audit!` is writing
- **THEN** the read returns a consistent snapshot (no `BoundsError` or torn entries)
