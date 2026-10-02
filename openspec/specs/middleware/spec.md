---
id: spec
kind: intent
statement: "WHEN the server is started, THE middleware system SHALL compose a descriptor-declared stack into a single reused handler that routes every request through the ordered middleware pipeline, and SHALL fail startup with one error naming every descriptor violation."
---

## Constraints

| id | kind | expr | traces_to |
|----|------|------|-----------|
| PIPELINE_PROTOCOL | invariant | every middleware implements handle_message and returns a Dict (single terminal response), a Vector{Dict} (multiple terminal responses), or nothing (pass to next); intermediate responses are emitted through the request sink before the terminal response, preserving intra-request order, carrying the current request id, and following the closed-channel discard semantics of send_response | [[spec]] |
| THIRD_PARTY_REGISTRATION | invariant | a third-party middleware registers brand-new operations without modifying core code | [[spec]] |
| DESCRIPTOR_DECLARED | invariant | every middleware declares provides, requires, and expects symbol sets plus per-op metadata through its descriptor method | [[spec]] |
| STARTUP_VALIDATION_COLLECTIVE | invariant | duplicate provides, unsatisfied requires, and violated expects are all detected at startup; every violation is reported together in a single error naming the involved middleware types and symbols, and the handler cannot be built while any violation exists | [[spec]] |
| STACK_IMMUTABLE | invariant | the middleware stack is fixed for the lifetime of the server: post-startup mutation of the source vector neither re-validates, re-materializes, nor alters dispatch | [[spec]] |
| ONE_DONE_PER_REQUEST | invariant | a middleware returning an empty Vector{Dict} yields exactly one done response for the request id, accompanied by a warning | [[spec]] |
| DEFAULT_STACK_ORDER | invariant | the default stack is the fixed ordered sequence AuditMiddleware, ShutdownMiddleware, SessionMiddleware, SessionOpsMiddleware, DescribeMiddleware, PingMiddleware, InterruptMiddleware, StdinMiddleware, EvalMiddleware, ReloadFileMiddleware, LoadFileMiddleware, CompleteMiddleware, LookupMiddleware, LsBindingsMiddleware, UnknownOpMiddleware | [[spec]] |
| CONNECTION_HANDLER_REUSE | invariant | the handler composed from the stack is built once and reused for every message on every connection | [[spec]] |

## Model

### States

- `unvalidated`
- `validated`
- `serving`

### Transitions

| id | from | to | guard |
|----|------|----|-------|
| validate_stack | unvalidated | validated | [[spec.STARTUP_VALIDATION_COLLECTIVE]] |
| begin_serving | validated | serving | [[spec.STACK_IMMUTABLE]] |
| handle_request | serving | serving | [[spec.PIPELINE_PROTOCOL]] |
| register_third_party | serving | serving | [[spec.THIRD_PARTY_REGISTRATION]] |

## Properties

| id | kind | derives_from | generator | predicate |
|----|------|--------------|-----------|-----------|
| middleware_return_contract | unit | [[spec.PIPELINE_PROTOCOL]] | `test/unit/middleware_test.jl`, `test/unit/middleware_spec_test.jl` | a middleware passes unknown ops to next, intercepts its own op without delegating, and eval emits buffered out/err chunks before the terminal value and done responses |
| custom_op_registered | unit | [[spec.THIRD_PARTY_REGISTRATION]] | `test/unit/middleware_spec_test.jl` | a third-party middleware handles a brand-new op through the standard handler while eval and unknown-op routing stay unchanged |
| descriptor_declares_claims | unit | [[spec.DESCRIPTOR_DECLARED]] | `test/unit/middleware_descriptor_test.jl` | EvalMiddleware's descriptor provides eval and requires session; built-in descriptors match their handled ops |
| validation_errors_name_types | unit | [[spec.STARTUP_VALIDATION_COLLECTIVE]] | `test/unit/middleware_spec_test.jl` | duplicate provides names both conflicting middleware types, missing requires names the middleware type and the missing symbol, violated expects name the op, and all violations aggregate into one ArgumentError from build_handler |
| stack_snapshot_immutable | unit | [[spec.STACK_IMMUTABLE]] | `test/unit/middleware_spec_test.jl` | pushing a duplicate-provides middleware or emptying the source vector after build_handler leaves the handler's behavior unchanged |
| empty_vector_becomes_done | unit | [[spec.ONE_DONE_PER_REQUEST]] | `test/unit/middleware_spec_test.jl` | a middleware returning an empty vector produces a single done response echoing the request id and a Warn-level log record naming the empty response |
| default_stack_in_order | unit | [[spec.DEFAULT_STACK_ORDER]] | `test/unit/middleware_spec_test.jl` | default_middleware_stack returns exactly the fifteen built-in middleware in the specified order |
| handler_reused_per_message | unit | [[spec.CONNECTION_HANDLER_REUSE]] | `test/unit/middleware_spec_test.jl` | three messages across two connections through the real connection loop all visit the same middleware instance |

# Middleware System

_Version: 1.2 — 2026-10-02_

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
The default middleware stack SHALL be: AuditMiddleware, ShutdownMiddleware, SessionMiddleware, SessionOpsMiddleware, DescribeMiddleware, PingMiddleware, InterruptMiddleware, StdinMiddleware, EvalMiddleware, ReloadFileMiddleware, LoadFileMiddleware, CompleteMiddleware, LookupMiddleware, LsBindingsMiddleware, UnknownOpMiddleware. (REQ-RPL-055)

`SessionOpsMiddleware` handles `clone`, `close`, and `ls-sessions` operations in addition to session resolution by `SessionMiddleware` for all requests.

#### Scenario: Default stack matches the built-in order
- **WHEN** `serve()` is called with no `middleware` argument
- **THEN** `default_middleware_stack()` returns the fifteen built-in middleware in the specified order

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
