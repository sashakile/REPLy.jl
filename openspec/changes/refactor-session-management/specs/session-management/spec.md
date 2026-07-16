## ADDED Requirements

### Requirement: Lock Ownership Documentation
Every field of `NamedSession` SHALL document which lock protects it (or note that it is immutable/atomic and needs no lock). Mutators for lock-guarded fields SHALL include a runtime assertion that the relevant lock is held. (ARCH-014)

#### Scenario: Mutator asserts lock is held
- **WHEN** a field of `NamedSession` is mutated
- **THEN** an `@assert islocked(lock)` check fires if the protecting lock is not held