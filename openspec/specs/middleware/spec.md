# Middleware System

_Version: 1.1 — 2026-04-17_

## Purpose

Specify the composable middleware pipeline that routes messages through a stack of handlers. Each middleware declares what operations it provides, requires, and expects via descriptors, enabling third parties to extend the protocol without modifying core code. The middleware stack is immutable after server startup.

## Requirements

### Requirement: Middleware Protocol
Every middleware SHALL implement `handle_message(mw, msg, next, ctx)`. When a middleware handles an operation that produces intermediate responses, it SHALL emit those responses through the response sink carried in `ctx` before returning the terminal response. Sink emissions SHALL preserve intra-request ordering, SHALL be associated with the current request `id`, and SHALL follow the same closed-channel discard semantics defined for `send_response`. The return value SHALL be one of: `Dict` (single terminal response), `Vector{Dict}` (multiple terminal responses), or `Nothing` (pass to next middleware). (REQ-RPL-050)

#### Scenario: Middleware passes through unknown ops
- **WHEN** a middleware receives an `op` it does not handle
- **THEN** it calls `next(msg)` and returns the result

#### Scenario: Middleware intercepts its own op
- **WHEN** a middleware receives an `op` it handles synchronously
- **THEN** it returns a `Dict` response without calling `next`

#### Scenario: Streaming middleware emits intermediate responses
- **WHEN** a middleware handles a streaming operation such as `eval`
- **THEN** it emits `out`/`err` chunks through `ctx` before returning the terminal response
### Requirement: Third-Party Operation Registration
A third-party middleware SHALL register new operations without modifying core code. (REQ-RPL-050)

#### Scenario: Custom op via middleware
- **WHEN** a `DebuggerMiddleware` is added to the stack
- **THEN** `{"op":"set-breakpoint",...}` is handled by that middleware without any core changes

### Requirement: Middleware Descriptors
Each middleware SHALL provide a `descriptor` method returning a `MiddlewareDescriptor` with `provides`, `requires`, and `expects` symbol sets, plus a `handles` dict of operation descriptors. (REQ-RPL-051)

#### Scenario: EvalMiddleware declares provides
- **WHEN** `EvalMiddleware.descriptor()` is called
- **THEN** `provides` contains `:eval`

### Requirement: Unique Provides Symbols
Two middleware providing the same symbol in `provides` SHALL cause a startup error. The error SHALL name all conflicting symbols and the middleware types involved. (REQ-RPL-052)

#### Scenario: Duplicate provides symbol at startup
- **WHEN** two middleware both declare `:eval` in `provides`
- **THEN** server startup fails with an error naming both conflicting types

### Requirement: requires Ordering Enforced
Unsatisfied `requires` dependencies SHALL cause a startup error naming the middleware and the missing symbol. (REQ-RPL-052)

#### Scenario: Missing required symbol causes startup failure
- **WHEN** a middleware declares `requires = Set([:session])` but `SessionMiddleware` is absent
- **THEN** startup fails with an error identifying the missing `:session` symbol

### Requirement: expects Ordering Enforced
Unsatisfied `expects` constraints SHALL cause a startup error by default (configurable to warning via `expects_enforcement = :warn`). All validation errors SHALL be collected and reported together. (REQ-RPL-052)

#### Scenario: Violated expects causes startup failure
- **WHEN** a middleware declares `expects = Set([:eval])` but no eval middleware follows
- **THEN** startup fails naming the violated constraint

#### Scenario: All descriptor errors reported together
- **WHEN** multiple descriptor violations exist
- **THEN** all are reported in a single error message, not fail-fast on the first

### Requirement: Default Middleware Stack Order
The default middleware stack SHALL be: DescribeMiddleware, SessionMiddleware, EvalMiddleware, InterruptMiddleware, LoadFileMiddleware, CompletionMiddleware, LookupMiddleware, StdinMiddleware, UnknownOpMiddleware. (REQ-RPL-055)

`SessionMiddleware` handles `clone`, `close`, and `ls-sessions` operations in addition to session resolution for all requests.

#### Scenario: Default stack has nine built-in middleware
- **WHEN** `serve()` is called with no `middleware` argument
- **THEN** `default_middleware_stack()` returns the nine built-in middleware in the specified order

### Requirement: Middleware Stack Immutability
The middleware stack SHALL be immutable after server startup. Middleware cannot be added, removed, or reordered at runtime. (ARCH-007)

#### Scenario: Stack is fixed after startup
- **WHEN** the server has started and is accepting connections
- **THEN** the middleware stack composition is fixed for the lifetime of the server process

### Requirement: Empty Response Vector Guard
When a middleware returns an empty `Vector{Dict}`, the server SHALL emit `{"status":["done"]}` and log a warning, satisfying the one-done-per-request invariant (see `protocol/spec.md`, REQ-RPL-004). (ARCH-001)

#### Scenario: Empty vector replaced with done response
- **WHEN** a middleware returns `[]`
- **THEN** the client receives `{"id":"...","status":["done"]}` rather than no response

### Requirement: Handler Caching Per Connection
The server SHALL support calling `build_handler` once per connection and reusing the resulting handler for all messages on that connection, since `HandlerContext` is constant per connection lifetime. This caching is RECOMMENDED for performance. (ARCH-006)

#### Scenario: Handler composed once per connection
- **WHEN** a new client connects
- **THEN** the middleware chain is composed once and reused for every subsequent message on that connection
