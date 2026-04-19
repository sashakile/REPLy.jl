# Spec Gap Implementation Plan

Date: 2026-04-19

## Overview

Close the largest gaps between the current REPLy tracer-bullet implementation and the OpenSpec capability specs, in dependency order, while preserving the current outside-in TDD workflow. The plan prioritizes the minimum session and lifecycle work needed to unblock the MCP adapter, then fills in missing core operations, session semantics, resource limits, and middleware/transport completeness.

## Related

- Spec: `openspec/specs/session-management/spec.md`
- Spec: `openspec/specs/core-operations/spec.md`
- Spec: `openspec/specs/mcp-adapter/spec.md`
- Spec: `openspec/specs/middleware/spec.md`
- Spec: `openspec/specs/security/spec.md`
- Spec: `openspec/specs/resource-limits/spec.md`
- Spec: `openspec/specs/transport/spec.md`
- Issue: `REPLy_jl-ulg` — Implement named session lifecycle for MCP adapter
- Issue dependency note: `REPLy_jl-ulg` blocks `REPLy_jl-wjz`
- Research/design: `.wai/projects/tracer-bullet/designs/2026-04-17-testing-validation-strategy-principle-o.md`
- Context: `.wai/projects/tracer-bullet/handoffs/2026-04-19-session-end.md`

## Current State

The repository has a working tracer bullet for:
- newline-delimited JSON message transport
- TCP and Unix socket listeners
- a small middleware chain
- ephemeral module-backed `eval`
- structured eval error responses
- MCP helper primitives for tool catalog, request shaping, and Reply→MCP result mapping

The largest missing areas are:
- persistent named sessions and lifecycle operations (`clone`, `close`, `ls-sessions`)
- MCP adapter default-session behavior
- most core operations (`describe`, `load-file`, `complete`, `lookup`, `interrupt`, `stdin`)
- session lifecycle/state semantics, timeouts, and serialization
- resource limits, audit logging, and graceful shutdown semantics
- middleware descriptors and spec-compliant default stack ordering
- transport multi-listener/global-limit behavior

## Desired End State

The implementation should satisfy the near-term v1.0-targeted parts of the current OpenSpec capability specs with independent, testable milestones. For planning purposes, treat all requirements as in scope unless they are explicitly deferred/P2 in the spec or explicitly deferred in this plan. In particular:
- the server supports persistent named sessions in addition to ephemeral evals
- the MCP adapter can own and use a persistent default session
- the core built-in operations are implemented behind middleware
- session state and eval concurrency semantics match the spec
- resource limits and shutdown behavior are enforced
- middleware descriptors and stack validation are implemented
- transport behavior matches the spec for TCP, Unix sockets, and concurrent listeners

How to verify:
- `just test` passes after each phase
- `just specs` continues to pass
- new unit/integration/e2e tests cover each newly implemented requirement scenario
- MCP default-session behavior persists bindings across calls
- session lifecycle operations are observable via protocol tests

## Out of Scope

- Heavy session full behavior beyond the current spec minimum gate (`"type":"heavy"` rejection when Malt.jl is unavailable)
- New encodings beyond JSON newline-delimited framing
- Remote security features outside the current local-only security model
- Broad performance optimization beyond what is required to satisfy explicit spec behavior

## Risks & Mitigations

- Risk: bolting persistent sessions onto the ephemeral-only manager creates architectural drift.
  - Mitigation: refactor `SessionManager` first into explicit persistent + ephemeral responsibilities.
- Risk: interrupt/timeout logic becomes brittle without explicit session state.
  - Mitigation: add lifecycle state and `eval_task` tracking before interrupt and timeout work.
- Risk: cross-cutting features (limits, audit, shutdown) create oversized tickets.
  - Mitigation: split them into separately testable phases after session/core-op foundations land.
- Risk: middleware descriptors are added too early and churn as middleware grows.
  - Mitigation: add descriptor validation after the main built-in middleware set is in place.

## Phase 1: Persistent named sessions and lifecycle ops

### Changes Required

File: `src/session/module_session.jl`
- Changes: expand session representation to include persistent metadata (`id`, `type`, timestamps, lifecycle/eval state) while retaining access to the backing `Module`.
- Tests: add unit tests for session identity, metadata, and state transitions.

File: `src/session/manager.jl`
- Changes: replace the ephemeral-only vector with a persistent session registry keyed by session id; preserve ephemeral-session support in a separate internal structure; add lookup, create, destroy, list, and activity update APIs.
- Tests: write unit tests first for create/list/lookup/destroy behavior and unknown-session handling.

Invariant for Phase 1:
- Ephemeral sessions are tracked separately from persistent named sessions.
- Ephemeral sessions MUST never appear in `ls-sessions` output.
- Persistent session ids MUST refer only to named sessions.

File: `src/middleware/session.jl`
- Changes: resolve a provided `session` id for session-bearing requests; keep ephemeral behavior for sessionless evals/loads; return `session-not-found` when needed.
- Tests: integration tests for named session routing and fallback ephemeral behavior.

File: `src/middleware/clone.jl`
- Changes: implement `clone` as persistent session creation. Phase 1 scope is limited to empty-session creation and parent-session existence validation only; deep-copy/typed clone semantics remain for later phases.
- Tests: failing integration tests for `clone` returning `new-session` and storing the created session.

File: `src/middleware/close.jl`
- Changes: implement `close` for named sessions.
- Tests: integration tests for successful close and unknown-session error.

File: `src/middleware/ls_sessions.jl`
- Changes: implement `ls-sessions` returning spec-required metadata.
- Tests: integration tests for session listing contents.

File: `src/middleware/core.jl`
- Changes: update eval flow so requests targeting persistent sessions reuse the existing session module instead of always creating ephemeral state.
- Tests: integration and e2e tests showing bindings persist across repeated evals in the same session.

File: `src/REPLy.jl`
- Changes: include/export new middleware/session APIs as needed.
- Tests: covered by unit/integration/e2e additions above.

### Implementation Approach

Follow TDD from outside in:
1. Add failing integration tests for `clone`, `close`, `ls-sessions`, and named-session eval persistence.
2. Add focused unit tests for the session registry and metadata/state API.
3. Refactor `SessionManager` and `ModuleSession` to support persistent identity.
4. Reach an intermediate green checkpoint: persistent registry APIs are green under unit tests before middleware is added.
5. Add the new middleware modules and update the default stack.
6. Refactor ephemeral-session handling to coexist with persistent sessions without leaks.
7. Tidy once the new tests pass.

### Success Criteria

Automated:
- [ ] `just test` passes
- [ ] `clone` creates a named session and returns `new-session`
- [ ] repeated `eval` requests against the same session persist bindings
- [ ] `ls-sessions` returns created session metadata
- [ ] `close` removes the session and later access returns `session-not-found`

Manual:
- [ ] Start a server, create a session, set a binding, read it back in a second request, then close the session

### Dependencies

- None; this is the foundation phase
- Unblocks `REPLy_jl-ulg` and Phase 2

---

## Phase 2: MCP adapter default-session lifecycle

### Changes Required

File: `src/mcp_adapter.jl`
- Changes: extend the helper/client abstraction only so adapter-facing logic can create and own a default persistent session, route omitted-session calls to it, and preserve the `"ephemeral"` sentinel behavior. A full stdio-hosted MCP adapter runtime remains out of scope for this phase.
- Tests: add failing unit tests for default-session routing and repeated-call persistence; add integration coverage only if a transport-backed client abstraction is introduced.

File: `test/unit/mcp_adapter_test.jl`
- Changes: extend tests from helper-level behavior to default-session lifecycle behavior.
- Tests: verify omitted `session` uses the persistent default and session-scoped bindings survive multiple calls.

### Implementation Approach

Keep the adapter work minimal and strictly dependent on the new server session APIs. The scope of this phase is helper/client behavior inside this repo, not a full stdio-hosted adapter runtime.

### Success Criteria

Automated:
- [ ] `just test` passes
- [ ] omitted `session` maps to a persistent adapter-owned default session
- [ ] `julia_new_session`, `julia_list_sessions`, and `julia_close_session` can be wired to server lifecycle ops

Manual:
- [ ] Evaluate `x = 41` through the adapter without specifying a session, then evaluate `x + 1` and get `42`

### Dependencies

- Phase 1
- Unblocks `REPLy_jl-wjz`
- `REPLy_jl-ulg` can be closed when Phase 1 and Phase 2 acceptance criteria pass

---

## Phase 3: Describe operation and server introspection

Note: In Phase 3, `describe` may use a static ops catalog for currently implemented built-ins. In Phase 8, it can be upgraded to consume descriptor metadata.

### Changes Required

File: `src/middleware/describe.jl`
- Changes: implement `describe` response shape with ops catalog, versions, encodings, and done status.
- Tests: unit/integration tests for minimum required response contents.

File: `src/middleware/core.jl`
- Changes: update default stack wiring to include `DescribeMiddleware`.
- Tests: ensure `describe` is present in the advertised ops set.

### Implementation Approach

Implement `describe` as a low-risk, mostly static middleware before the remaining operational middleware are added. The ops catalog can begin with built-ins already implemented and expand as later phases land.

### Success Criteria

Automated:
- [ ] `just test` passes
- [ ] `describe` returns `ops`, `versions`, `encodings-available`, `encoding-current`, and `status:["done"]`

Manual:
- [ ] Send a `describe` request to a running server and inspect the advertised operations

### Dependencies

- Phase 1 recommended
- Improved further by Phase 8 descriptor work

---

## Phase 4A: Self-contained core operations

### Changes Required

File: `src/middleware/load_file.jl`
- Changes: implement `load-file` with path-read error handling and allowlist enforcement hook.
- Tests: file-loaded, unreadable-file, and allowlist-rejection scenarios.

File: `src/middleware/complete.jl`
- Changes: implement `complete` with cursor-position validation.
- Tests: completion results and out-of-bounds empty result.

File: `src/middleware/lookup.jl`
- Changes: implement `lookup` for found/not-found symbol inspection.
- Tests: found and not-found scenarios.

### Implementation Approach

Implement in this order:
1. `load-file`
2. `complete`
3. `lookup`

These operations are relatively self-contained and should remain independent of interrupt/time-control machinery.

### Success Criteria

Automated:
- [ ] `just test` passes
- [ ] tests cover the core-op scenarios above

Manual:
- [ ] Load a file, request completions, inspect a symbol, interrupt a long-running eval, and resume normal operation

### Dependencies

- Phase 1

---

## Phase 4B: Interactive control operations

### Changes Required

File: `src/middleware/interrupt.jl`
- Changes: implement request-targeted and session-wide interrupts once per-session eval tracking exists.
- Tests: interrupt running eval, idempotent interrupt, interrupt-all.

File: `src/middleware/stdin.jl`
- Changes: implement stdin delivery and buffering semantics.
- Tests: `need-input`, immediate delivery, and buffered-input behavior.

### Implementation Approach

Implement these only after Phase 5 introduces explicit session/eval state, stdin buffering, and task tracking.

### Success Criteria

Automated:
- [ ] `just test` passes
- [ ] interrupt and stdin scenarios behave per spec

Manual:
- [ ] Interrupt a long-running eval and provide stdin to a blocked eval without destabilizing the session

### Dependencies

- Phase 5

---

## Phase 5: Session semantics and lifecycle correctness

### Changes Required

File: `src/session/module_session.jl`
- Changes: add explicit lifecycle state, per-session serialization primitive, eval task reference, history store, stdin buffer, and last-activity tracking.
- Tests: unit tests for lifecycle transitions, FIFO serialization, and eval task assignment timing.

File: `src/session/manager.jl`
- Changes: add atomic transition helpers, idle-sweep support, and cleanup policies for persistent and ephemeral sessions.
- Tests: race-oriented unit/integration coverage where possible.

File: `src/middleware/core.jl`
- Changes: route eval through per-session FIFO serialization, update activity/history, and assign `eval_task` before execution starts.
- Tests: integration tests for same-session FIFO ordering and cross-session concurrency independence.

### Implementation Approach

Introduce the session state machine before adding timeout and interrupt complexity. Keep the serialization mechanism explicit and test-driven; prefer a queue/channel-based approach aligned with the spec guidance.

### Success Criteria

Automated:
- [ ] `just test` passes
- [ ] same-session evals are serialized FIFO
- [ ] different sessions can still progress independently
- [ ] idle sessions time out correctly
- [ ] lifecycle races resolve to a single terminal outcome

Manual:
- [ ] Observe two evals submitted to one session complete in order, while another session remains responsive

### Dependencies

- Phase 1
- Unblocks the harder parts of Phase 4 and Phase 6/7

---

## Phase 6: Eval option compliance

### Changes Required

File: `src/middleware/core.jl`
- Changes: add support for `module`, `allow-stdin`, `timeout-ms` validation/capping, `silent`, `store-history`, and `value` truncation.
- Tests: one spec-scenario test per option/branch.

File: `src/session/module_session.jl`
- Changes: add history support required by `store-history` and bounded history limits.
- Tests: history update and suppression tests.

File: `src/config/resource_limits.jl` (new)
- Changes: define `ResourceLimits` and defaults referenced by eval behavior.
- Tests: default values and per-field override tests.

### Implementation Approach

Add behavior one option at a time with failing tests copied directly from spec scenarios. Avoid mixing timeout enforcement internals with request-shape validation in the same test cycle.

### Success Criteria

Automated:
- [ ] `just test` passes
- [ ] module resolution, timeout request validation/capping, silent mode, store-history, and value truncation behave per spec
- [ ] runtime timeout cancellation remains explicitly deferred to Phase 7

Manual:
- [ ] Exercise eval options against a running server and inspect the response stream for the expected differences

### Dependencies

- Phase 5 for task/session tracking
- Phase 7 for full timeout enforcement backing

---

## Phase 7A: ResourceLimits configuration and shared server-state guardrails

### Changes Required

File: `src/config/resource_limits.jl`
- Changes: finalize the full `ResourceLimits` surface.
- Tests: unit coverage for defaults and overrides.

File: `src/server.jl`
- Changes: introduce shared server state for limits/audit/session coordination so future multi-listener support does not depend on listener-local state.
- Tests: integration tests asserting shared state is not stored only in a single listener/transport path.

### Implementation Approach

Create the configuration surface and shared-state boundary first. All limits, audit state, and session state added in later phases MUST live in shared server state, not listener-local transport instances.

### Success Criteria

Automated:
- [ ] `just test` passes
- [ ] `ResourceLimits` defaults and overrides are covered by unit tests
- [ ] shared server-state plumbing exists for later listener-global enforcement

Manual:
- [ ] Inspect server construction and verify limit/session state is shared above individual listeners

### Dependencies

- Phase 5

---

## Phase 7B: Resource enforcement

### Changes Required

File: `src/security/limits.jl` (new)
- Changes: centralize session-count, concurrency, rate-limit, and message-size enforcement.
- Tests: one failing test per rejection path.

File: `src/transport/tcp.jl`
- Changes: enforce oversize-message close behavior and connection-scoped rate-limit hooks using shared server state.
- Tests: e2e tests for oversized message closure and rate-limit rejection.

### Implementation Approach

Implement enforcement in small vertical slices: session-count, concurrency, rate-limit, then oversized-message handling.

### Success Criteria

Automated:
- [ ] `just test` passes
- [ ] configured limits enforce the expected error/close behavior

Manual:
- [ ] Exceed each limit intentionally and observe the expected rejection behavior

### Dependencies

- Phase 7A
- Phase 5

---

## Phase 7C: Timeout, disconnect cleanup, and closed-channel resilience

### Changes Required

File: `src/middleware/core.jl`
- Changes: implement runtime timeout enforcement, disconnect cleanup, and closed-channel-safe response emission.
- Tests: timeout, disconnect cleanup, and post-disconnect output discard.

File: `src/server.jl`
- Changes: integrate timeout and disconnect behavior with shared server/session state.
- Tests: integration/e2e timeout and disconnect tests.

### Implementation Approach

Keep runtime timeout cancellation separate from request-shape validation from Phase 6.

### Success Criteria

Automated:
- [ ] `just test` passes
- [ ] runtime timeout cancellation works per spec
- [ ] disconnect cleanup and closed-channel discard behavior are covered

Manual:
- [ ] Run a long eval, disconnect the client, and verify the server remains healthy

### Dependencies

- Phase 7A
- Phase 5
- Phase 6

---

## Phase 7D: Audit logging and graceful shutdown

### Changes Required

File: `src/security/audit.jl` (new)
- Changes: add bounded in-memory audit logging and optional NDJSON file appends/rotation.
- Tests: entry shape, bounded eviction, file rotation behavior.

File: `src/server.jl`
- Changes: add graceful shutdown ordering and listener stop behavior on top of shared state and cleanup hooks.
- Tests: integration/e2e shutdown tests.

### Implementation Approach

Add audit and shutdown after enforcement and cleanup behavior are stable so shutdown logic composes with already-tested control paths.

### Success Criteria

Automated:
- [ ] `just test` passes
- [ ] graceful shutdown interrupts active work and exits cleanly
- [ ] audit log behavior is bounded and valid

Manual:
- [ ] Start a long-running eval, trigger shutdown, and verify orderly termination

### Dependencies

- Phase 7A
- Phase 7B
- Phase 7C

---

## Phase 8: Middleware descriptors and stack validation

### Changes Required

File: `src/middleware/core.jl`
- Changes: define `MiddlewareDescriptor`, descriptor lookup, and stack validation for `provides`, `requires`, and `expects`.
- Tests: duplicate provides, missing requires, violated expects, and aggregated error reporting.

File: `src/middleware/*.jl`
- Changes: add descriptor methods for each built-in middleware and update default stack order to match spec.
- Tests: unit tests asserting descriptor contents and default stack composition.

### Implementation Approach

Once the built-in middleware set is mostly stable, layer descriptor metadata on top. Use `describe` output as a consumer of the descriptor registry where helpful.

### Success Criteria

Automated:
- [ ] `just test` passes
- [ ] invalid middleware stacks fail fast with aggregated messages
- [ ] default stack order matches the spec

Manual:
- [ ] Construct an invalid middleware stack in a REPL and verify the startup error is informative

### Dependencies

- Phases 3 and 4 substantially complete

---

## Phase 9: Transport completeness and multi-listener support

### Changes Required

File: `src/server.jl`
- Changes: support multiple listeners concurrently and share one session/limit domain across them.
- Tests: e2e tests for simultaneous TCP + Unix socket listeners.

File: `src/transport/tcp.jl`
- Changes: adapt listener/client handling to coexist with multiple active listeners.
- Tests: shared limit/session behavior across transports.

### Implementation Approach

Keep the transport abstraction stable; add multi-listener orchestration at the server level rather than coupling middleware/session logic to transport details.

### Success Criteria

Automated:
- [ ] `just test` passes
- [ ] TCP and Unix socket listeners can run simultaneously
- [ ] limits and session pool are global across listeners

Manual:
- [ ] Create sessions through one transport and observe them from the other

### Dependencies

- Phase 7 for global limit semantics

---

## Testing Strategy

Following TDD:
1. Write tests first.
2. Confirm they fail.
3. Implement the minimum to pass.
4. Refactor while staying green.

Test types needed:
- Unit tests:
  - session registry/state APIs
  - request validation and resource-limit config
  - adapter helpers/default-session behavior
  - descriptor validation
- Integration tests:
  - middleware pipeline behavior for clone/close/list/eval/describe/load-file/complete/lookup/interrupt/stdin
  - session-not-found and lifecycle semantics
  - timeout and shutdown coordination where sockets are unnecessary
- E2E tests:
  - named session round-trips over TCP/Unix socket
  - malformed/oversized input behavior
  - graceful shutdown
  - multi-listener behavior

Suggested immediate red→green sequence:
1. `test/integration/session_lifecycle_test.jl` for `clone`, named-session eval, `ls-sessions`, `close`
2. `test/unit/session_registry_test.jl` for manager/state primitives
3. MCP default-session tests
4. `describe` tests
5. self-contained core-op tests (`load-file`, `complete`, `lookup`)
6. richer session-state tests before `interrupt`/`stdin`/timeouts

Execution contract:
- Every phase ends green with `just test` passing.
- Future-facing scaffolds should be isolated behind `@test_broken` or deferred to the appropriate phase rather than leaving the phase partially red.

Suggested issue-sized slices for Phase 1:
1. Session registry refactor with persistent/named session identity
2. Named-session request routing and `session-not-found`
3. `clone` / `close` / `ls-sessions` middleware
4. Named-session eval persistence integration + e2e coverage
5. MCP default-session follow-on wiring

## Rollback Strategy

- Keep each phase in a separate commit or small stack of commits.
- Preserve the current ephemeral eval path until the persistent-session path is proven green.
- If a phase destabilizes the server, revert that phase's commit(s) without rolling back unrelated completed phases.
- Avoid coupling new ops to incomplete descriptor/security work so intermediate milestones remain releasable.

## Related Links

- `openspec/project.md`
- `openspec/specs/session-management/spec.md`
- `openspec/specs/core-operations/spec.md`
- `openspec/specs/mcp-adapter/spec.md`
- `.wai/projects/tracer-bullet/designs/2026-04-17-testing-validation-strategy-principle-o.md`
