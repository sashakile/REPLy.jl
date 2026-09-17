## MODIFIED Requirements

### Requirement: Middleware Protocol
Every middleware SHALL implement `handle_message(mw, msg, next, ctx)`. [...] (REQ-RPL-050)

#### Scenario: Invalid middleware stack caught at handler build time
- **WHEN** a custom middleware stack drops or reorders `SessionMiddleware`
- **THEN** `build_handler` throws a descriptive error before any request is processed

### Requirement: expects Ordering Enforced
`expects` SHALL be a `Set{String}` of op names that must be provided by some middleware *later* in the stack (forward-looking, unlike `requires`). Unsatisfied `expects` constraints SHALL cause a startup error by default (configurable to warning via `expects_enforcement = :warn`). All validation errors SHALL be collected and reported together. (REQ-RPL-052)

#### Scenario: Violated expects causes startup failure
- **WHEN** a middleware declares `expects = Set(["eval"])` but no later middleware provides `"eval"`
- **THEN** startup fails naming the violated constraint

#### Scenario: expects satisfied by a later middleware
- **WHEN** a middleware declares `expects = Set(["eval"])` and a later middleware provides `"eval"`
- **THEN** startup succeeds

#### Scenario: expects satisfied only by an earlier middleware is a violation
- **WHEN** a middleware declaring `expects = Set(["eval"])` is preceded by a middleware providing `"eval"` and followed by none
- **THEN** startup fails — `expects` is forward-looking, unlike `requires`

#### Scenario: expects enforcement downgraded to warning
- **WHEN** `expects_enforcement = :warn` and an `expects` constraint is violated
- **THEN** no startup error is raised and the violation is emitted as a warning

#### Scenario: All descriptor errors reported together
- **WHEN** multiple descriptor violations exist
- **THEN** all are reported in a single error message, not fail-fast on the first
