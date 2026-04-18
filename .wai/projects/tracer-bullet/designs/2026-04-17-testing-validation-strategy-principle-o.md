## Testing & Validation Strategy

### Principle: Outside-In TDD

Write the end-to-end test first (definition of done), then build inward.
Each layer has its own tests; inner layers pass before outer layers can.

### Three Test Layers

#### Layer 1: End-to-End (`test/e2e/`)
Full TCP round-trip tests. Start a real server, connect a socket, send JSON, verify responses.

- `eval_test.jl` — one definitive acceptance test that is the tracer bullet's
  definition of done: send eval over TCP, get value+done stream back.
  Additional e2e tests in the same file cover error paths, concurrent
  connections, and client disconnect resilience.
- Tests use `serve(port=0)` for OS-assigned ports, `finally`-guarded shutdown

#### Layer 2: Integration (`test/integration/`)
Middleware pipeline as function call — no network, no sockets.

- `pipeline_test.jl` — feed Dict into pipeline, verify response Dicts
- Buffered output order: out/err messages before value before done
- Ephemeral session lifecycle via `session_count(manager)`:
  assert 0 before and after ephemeral eval flows (leak detection)
- Error shapes: unknown op, eval error, parse error

#### Layer 3: Unit (`test/unit/`)
Individual components in isolation.

- `message_test.jl` — JSON parse/serialize, newline termination, malformed input,
  `receive` postconditions (malformed JSON → treat as closed boundary / return nothing,
  non-object JSON → skip/nothing, client disconnect → nothing, empty/whitespace
  lines → skip), id length validation (id > 256 chars → rejected)
- `session_test.jl` — anonymous Module creation, eval isolation between sessions,
  cleanup, `session_count` accessor (0 → 1 → 0 around ephemeral eval for leak detection)
- `eval_middleware_test.jl` — buffered stdout/stderr capture, value repr, empty code → nothing,
  large-output completion, err field disambiguation (stderr message has no `status`;
  error response has `status:["error"]`)
- `middleware_test.jl` — pass-through for unhandled ops, intercept for handled ops
- `error_test.jl` — UndefVarError shape, parse error shape, status flags, id-too-long rejection

### Shared Test Infrastructure (`test/helpers/`)

#### `conformance.jl` — Protocol Conformance Checker
Reusable function run against any response stream:

```julia
function assert_conformance(msgs::Vector{Dict}, request_id::String)
    # 1. id echo — every response carries the request id
    # 2. exactly one done — stream ends with one status:["done",...] message
    # 3. ordering — buffered out/err messages before value before done
    # 4. kebab-case — no snake_case keys in any response
    # 5. err disambiguation — buffered stderr messages have "err" with NO "status";
    #    error responses have "err" WITH "status" containing "error"
end
```

Applied in all three layers wherever responses are produced.
Helpers are scaffolded early because the conformance checker is shared across
all three layers — this is deliberate front-loading, not premature abstraction.

#### `tcp_client.jl` — Test TCP Client
```julia
function collect_until_done(sock)::Vector{Dict}
    # Read lines, parse JSON, accumulate, stop at done status
end
```

#### `server.jl` — Test Server Lifecycle
```julia
function with_server(f; port=0)
    # Start server, call f(server), ensure shutdown in finally
end
```

### Test File Tree

```
test/
├── runtests.jl              # includes layers in order: helpers → unit → integration → e2e
│                            # each layer runs regardless of prior failures (@testset semantics)
├── helpers/
│   ├── conformance.jl       # protocol invariant assertions
│   ├── tcp_client.jl        # collect_until_done, send_request
│   └── server.jl            # with_server lifecycle helper
├── unit/
│   ├── message_test.jl      # JSON framing
│   ├── session_test.jl      # anonymous Module eval isolation
│   ├── eval_middleware_test.jl  # stdout capture, value repr
│   ├── middleware_test.jl    # dispatch: pass-through vs intercept
│   └── error_test.jl        # error response formatting
├── integration/
│   └── pipeline_test.jl     # full pipeline without network
└── e2e/
    └── eval_test.jl         # TCP round-trip: acceptance test, concurrent
                             # connections, client disconnect resilience
```

### TDD Progression

```
1.  Write e2e/eval_test.jl                          (RED — nothing exists)
2.  Write integration/pipeline_test.jl               (RED)
3.  Write + implement unit/message_test.jl           (RED → GREEN)
    — includes receive postconditions, id validation, blank-line handling
4.  Write + implement unit/session_test.jl           (RED → GREEN)
    — includes session_count accessor for leak detection
5.  Write + implement unit/eval_middleware_test.jl    (RED → GREEN)
    — includes buffered stderr capture, large-output completion, err field disambiguation
6.  Write + implement unit/middleware_test.jl         (RED → GREEN)
7.  Write + implement unit/error_test.jl             (RED → GREEN)
8.  Implement pipeline assembly                      (wire middleware chain + HandlerContext)
9.  Integration test passes                          (GREEN)
10. Wire up TCP transport                            (RED → GREEN on e2e)
11. Add e2e: two concurrent connections              (RED → GREEN)
12. Add e2e: client disconnect mid-eval              (RED → GREEN)
13. Tidy — separate commit
```

### Deferred: Next Increments (same architecture, additive)

- describe operation (trivial — static response)
- Clone/close/ls-sessions (persistent sessions)
- session-not-found error (requires persistent session lookup)
- Interrupt, complete, lookup, load-file, stdin ops (one middleware each)
- Unix socket transport (same interface, different listener)
- Timeout enforcement (wraps eval in deadline)

### Deferred: Separate Scope

- session-limit-reached / concurrency-limit-reached (requires ResourceLimits)
- Security (permissions, audit logging)
- MCP adapter (reference client — separate package)
- Heavy sessions (Malt.jl process isolation)
- MessagePack encoding (alternative wire format)

### Spec Scenario Coverage Matrix

| Req | Scenario | Test File | Status |
|-----|----------|-----------|--------|
| **Protocol** | | | |
| REQ-RPL-001 | Valid request message | unit/message_test.jl | COVERED |
| REQ-RPL-001 | Request without session | integration/pipeline_test.jl | COVERED |
| REQ-RPL-001b | id > 256 chars rejected | unit/message_test.jl | COVERED |
| REQ-RPL-004 | Streaming response carries request id | helpers/conformance.jl | COVERED |
| REQ-RPL-004 | Done emitted once on success | helpers/conformance.jl | COVERED |
| REQ-RPL-004 | No double done on parse error | unit/error_test.jl | COVERED |
| REQ-RPL-004b | Stdout before value before done | helpers/conformance.jl | COVERED |
| REQ-RPL-005 | Buffered stdout message precedes done | integration/pipeline_test.jl | COVERED |
| REQ-RPL-005 | err field disambiguation | unit/eval_middleware_test.jl | COVERED |
| REQ-RPL-007 | Response uses kebab-case | helpers/conformance.jl | COVERED |
| REQ-RPL-008 | Message framing with newline | unit/message_test.jl | COVERED |
| **Core-operations** | | | |
| REQ-RPL-011 | Successful eval | e2e/eval_test.jl | COVERED |
| REQ-RPL-011 | Eval with buffered stdout | integration/pipeline_test.jl | COVERED |
| REQ-RPL-011b | Empty code returns nothing | unit/eval_middleware_test.jl | COVERED |
| REQ-RPL-011c | Dotted module path | — | DEFERRED |
| REQ-RPL-011d | allow-stdin false | — | DEFERRED |
| REQ-RPL-011e | timeout-ms bounds | — | DEFERRED |
| REQ-RPL-011 | silent suppresses value | — | DEFERRED |
| REQ-RPL-011 | store-history false | — | DEFERRED |
| REQ-RPL-047i | Large repr truncated | — | DEFERRED |
| **Session-management** | | | |
| REQ-RPL-030 | Binding isolation between sessions | unit/session_test.jl | COVERED |
| REQ-RPL-030 | Concurrent sessions in parallel | — | DEFERRED |
| REQ-RPL-035 | Ephemeral leaves no persistent session | integration/pipeline_test.jl | COVERED |
| REQ-RPL-035 | Ephemeral not interruptible | — | DEFERRED |
| REQ-RPL-035b | Ephemeral counts against max_sessions | — | DEFERRED |
| REQ-RPL-035c | Ephemeral counts against max_concurrent | — | DEFERRED |
| REQ-RPL-035d | Module pool bounds memory | — | DEFERRED |
| **Middleware** | | | |
| REQ-RPL-050 | Pass through unknown ops | unit/middleware_test.jl | COVERED |
| REQ-RPL-050 | Intercept own op | unit/middleware_test.jl | COVERED |
| REQ-RPL-050 | Streaming intermediate responses | unit/eval_middleware_test.jl | COVERED |
| REQ-RPL-051 | EvalMiddleware declares provides | — | DEFERRED |
| REQ-RPL-055 | Default stack 9 middleware | — | DEFERRED |
| **Error-handling** | | | |
| REQ-RPL-061 | Exception without .msg field | unit/error_test.jl | COVERED |
| REQ-RPL-063 | Eval runtime error shape | unit/error_test.jl | COVERED |
| REQ-RPL-063 | Parse error shape | unit/error_test.jl | COVERED |
| REQ-RPL-063 | Unknown operation | unit/error_test.jl | COVERED |
| REQ-RPL-063 | Session not found | — | DEFERRED |
| **Transport** | | | |
| REQ-RPL-040b | Partial read → nothing | unit/message_test.jl | COVERED |
| REQ-RPL-040b | Malformed JSON → close boundary / no response | unit/message_test.jl, e2e/eval_test.jl | COVERED |
| REQ-RPL-040b | Non-object JSON → skip | unit/message_test.jl | COVERED |
| REQ-RPL-042 | TCP accepts connections | e2e/eval_test.jl | COVERED |
| REQ-RPL-042 | Two concurrent connections | e2e/eval_test.jl | COVERED |
| REQ-RPL-043 | Port conflict logged | — | DEFERRED |

**Totals:** 27 COVERED, 14 DEFERRED across 6 spec domains (41 scenarios total)

Note: the tracer bullet currently buffers stdout/stderr per stream during eval and emits those messages before the terminal value/done pair; it does not promise live chunk streaming or stdout/stderr interleaving fidelity.
