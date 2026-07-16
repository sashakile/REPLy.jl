## MODIFIED Requirements

### Requirement: Middleware Protocol
Every middleware SHALL implement `handle_message(mw, msg, next, ctx)`. [...] (REQ-RPL-050)

#### Scenario: Invalid middleware stack caught at handler build time
- **WHEN** a custom middleware stack drops or reorders `SessionMiddleware`
- **THEN** `build_handler` throws a descriptive error before any request is processed
