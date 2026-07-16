## ADDED Requirements

### Requirement: Global Stream Restoration on Shutdown
When the server shuts down, it SHALL restore `Base.stdout` and `Base.stderr` to their original values. (ARCH-008)

#### Scenario: Streams restored after close
- **WHEN** a server session completes and the server is closed
- **THEN** `Base.stdout` and `Base.stderr` are restored to their pre-server values