---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

* REPLy_jl-umg.1 — runtime and test architecture map
:PROPERTIES:
:Date: 2026-04-29
:Question: Establish a factual baseline for runtime structure, request flow, session lifecycle, and test layout.
:END:

* Summary
REPLy.jl is organized as a single top-level module that composes protocol, session, middleware, transport, server, security, configuration, and MCP helper layers through ordered =include= statements in =src/REPLy.jl:1-58=. The exported surface mixes wire-level helpers (=send!=, =receive=, =validate_request=), server constructors (=serve=, =serve_multi=), session/state APIs, middleware APIs, audit logging, and MCP adapter helpers.

The runtime path for the default server is: =serve= builds shared =ServerState=, materializes the middleware stack, and constructs a request handler; the transport accept loop turns each socket into a =JSONTransport=; the transport reads one newline-delimited JSON object at a time; =build_handler= validates the request and dispatches it through middleware; middleware either emits direct responses or forwards to later layers; responses are normalized into a done-terminated response stream before the transport writes them back. See =src/server.jl:33-75=, =src/transport/tcp.jl:36-130=, =src/protocol/message.jl:26-118=, and =src/middleware/core.jl:111-154=.

Persistent session state is isolated in =NamedSession= objects keyed by UUID, while ephemeral evals use short-lived =ModuleSession= objects that are never listed in named-session inventory. The test suite mirrors that layering: helpers provide socket/server/conformance scaffolding, unit tests target individual modules and protocol features, integration tests exercise handler pipelines and lifecycle behavior, and end-to-end tests drive full TCP/Unix/multi-listener servers. See =src/session/module_session.jl:55-217=, =src/session/manager.jl:18-347=, =test/runtests.jl:1-65=, and =test/helpers/*.jl=.

* Architecture overview
** Top-level composition
- =src/REPLy.jl:1-58= is the package entrypoint.
- It loads internal subsystems in this order: errors, protocol, session model, configuration, audit logging, session manager, middleware files, transport, server, and MCP adapter (=src/REPLy.jl:32-52=).
- Public exports include transport primitives, server constructors, session/state APIs, middleware APIs, audit APIs, and MCP helper APIs (=src/REPLy.jl:8-28=).

** Configuration and shared state
- =ResourceLimits= is an immutable configuration struct for eval/session/transport limits (=src/config/resource_limits.jl:19-28=).
- =ServerState= holds the active limits, inbound message size cap, a server-wide active-eval counter, and a registry of active eval tasks shared above listener-local paths (=src/config/server_state.jl:11-41=).
- Audit logging is modeled separately through =AuditLogEntry= and =AuditLog=, with optional file append/rotation behavior (=src/security/audit.jl:1-91=).

** Session model
- =ModuleSession= is the ephemeral execution container backed by an anonymous module (=src/session/module_session.jl:6-16=).
- =NamedSession= adds UUID identity, optional alias name, timestamps, lifecycle state, eval locks, stdin buffering, history, and eval counters (=src/session/module_session.jl:55-71=).
- Session states are =SessionIdle=, =SessionRunning=, and =SessionClosed= (=src/session/module_session.jl:28-32=).
- Accessors and lifecycle mutators are defined in =src/session/module_session.jl:83-217=.

** Session registry
- =SessionManager= owns two distinct registries: =ephemeral_sessions= and =named_sessions= plus =name_to_uuid= alias lookup (=src/session/manager.jl:18-25=).
- It exposes creation, lookup, destruction, lazy get-or-create, idle sweeping, and cloning functions for sessions (=src/session/manager.jl:32-347=).

** Protocol and wire helpers
- =JSONTransport= wraps an =IO= with a send lock; =receive= reads newline-delimited JSON, enforces max message size, and returns only flat object messages (=src/protocol/message.jl:3-46=).
- Request/response helpers define response envelopes, structured error payloads, and validation rules for =id=, =op=, kebab-case keys, and flat values (=src/protocol/message.jl:64-118=).
- Error helpers normalize exception rendering, stacktrace payloads, and status-flagged error responses (=src/errors.jl:1-76=).

** Middleware layer
- The middleware core defines =AbstractMiddleware=, =MiddlewareDescriptor= metadata, stack validation, request/handler contexts, recursive dispatch, and handler construction (=src/middleware/core.jl:1-154=).
- The default stack is =SessionMiddleware()=, =SessionOpsMiddleware()=, =DescribeMiddleware()=, =InterruptMiddleware()=, =StdinMiddleware()=, =EvalMiddleware()=, and =UnknownOpMiddleware()= (=src/middleware/core.jl:134-136=).
- =materialize_middleware_stack= builds the describe catalog from middleware descriptors and rewrites =DescribeMiddleware= with that catalog (=src/middleware/core.jl:138-145=).

** Transport and server layer
- =TCPServerHandle=, =UnixServerHandle=, and =MultiListenerServer= hold listeners, client task lists, shared handler/middleware/state references, and shutdown flags (=src/transport/tcp.jl:1-30=).
- =handle_client!= runs the request loop on a socket, applying transport-level oversized-message and per-connection rate-limit behavior before calling the handler (=src/transport/tcp.jl:36-101=).
- =accept_loop!= accepts sockets and spawns one task per client (=src/transport/tcp.jl:104-130=).
- =listen_unix= creates Unix sockets with a restrictive umask and explicit =0o600= mode (=src/transport/tcp.jl:133-152=).
- =serve= constructs one TCP or Unix listener; =serve_multi= constructs multiple listeners sharing the same =SessionManager=, =ServerState=, handler, and middleware stack (=src/server.jl:33-75=, =src/server.jl:152-180=).
- Shutdown closes listeners, interrupts active evals, waits within a grace window, closes clients, and calls middleware shutdown hooks (=src/server.jl:77-149=, =src/server.jl:182-216=).

** MCP adapter helpers
- =src/mcp_adapter.jl= is a helper layer rather than a listener or middleware.
- It defines static MCP metadata (=mcp_initialize_result=, =mcp_tools=), request/result conversion helpers, default-session creation, session lifecycle helper calls, a buffered reply-stream collector, and conversion from Reply response streams into MCP =CallToolResult= payloads (=src/mcp_adapter.jl:1-395=).
- =mcp_call_tool= statically dispatches only lifecycle operations and stubbed operations; =julia_eval= is explicitly rejected there because it requires a live transport (=src/mcp_adapter.jl:217-248=).

* Key runtime components
** Server bootstrap and listener ownership
Location: =src/server.jl:33-75=, =src/server.jl:152-180=
Purpose: Build shared runtime state and start one or more listeners.
Depends on: =SessionManager=, =ResourceLimits=, =ServerState=, middleware stack materialization, transport accept loop.
Used by: direct library callers, test helpers such as =with_server=, =with_unix_server=, and =with_multi_server= (=test/helpers/server.jl:3-35=).

How it works:
1. Validates =max_message_bytes= and listener arguments.
2. Creates a shared =ServerState=.
3. Materializes middleware and builds a handler closure.
4. Creates either TCP/Unix handles (=serve=) or a vector of mixed handles (=serve_multi=).
5. Starts =accept_loop!= asynchronously for each listener.

** Transport request loop
Location: =src/transport/tcp.jl:36-130=
Purpose: Bind sockets to the handler and enforce connection-local behavior.
Depends on: =JSONTransport=, =receive=, =send!=, handler closure, =ServerState= limit fields.
Used by: =accept_loop!= spawned client tasks.

How it works:
1. Wraps the socket in =JSONTransport=.
2. Repeatedly reads one request object with =receive=.
3. Converts oversized messages into an immediate error response and returns.
4. Enforces per-connection rate limiting using a sliding 60-second window when enabled.
5. Calls the handler and streams each returned response object back to the client.
6. Removes the socket/task from handle bookkeeping in the spawned-task =finally= block.

** Handler construction and middleware dispatch
Location: =src/middleware/core.jl:111-154=
Purpose: Turn an abstract middleware vector into a callable request handler.
Depends on: request validation, recursive =dispatch_middleware=, response finalization.
Used by: =serve=, =serve_multi=, and unit/integration tests that call =build_handler= directly.

How it works:
1. =build_handler= materializes the stack and captures a connection-scoped =HandlerContext=.
2. Each request is validated with =validate_request= before middleware runs.
3. A fresh =RequestContext= is created per request.
4. =dispatch_middleware= recurses through the vector, passing a =next= closure.
5. =finalize_responses= appends emitted intermediate messages and ensures a terminal =done= if middleware returned nothing.

** Eval execution path
Location: =src/middleware/eval.jl:17-411=
Purpose: Execute Julia code in the current session and return Reply response streams.
Depends on: session selection in =RequestContext=, =ServerState= concurrency counters, global IO capture lock, named-session lifecycle helpers.
Used by: =EvalMiddleware= in the default stack.

How it works:
1. Validates =code= and optional =timeout-ms= (=src/middleware/eval.jl:204-229=).
2. Derives an effective timeout from per-request and server-wide limits (=src/middleware/eval.jl:231-239=).
3. Enforces server-wide concurrent eval limits via =ServerState.active_evals= (=src/middleware/eval.jl:247-258=).
4. Uses the session already placed in =ctx.session=, or creates an ephemeral fallback if absent (=src/middleware/eval.jl:260-266=).
5. Optionally resolves a dotted =module= path from =Main= (=src/middleware/eval.jl:268-279=, =src/middleware/eval.jl:134-152=).
6. For named sessions, serializes through =session.eval_lock=, calls =try_begin_eval!=, optionally fires the Revise hook, optionally bridges stdin through a pipe, runs the eval core, and then calls =end_eval!= (=src/middleware/eval.jl:305-355=).
7. =_run_eval_core= captures stdout/stderr, evaluates parsed expressions, returns output/value/done on success, or structured error/interrupted responses on failure (=src/middleware/eval.jl:69-132=).
8. On successful named-session evals, =_update_history!= stores the value and updates =ans= (=src/middleware/eval.jl:398-409=).

** Session operations path
Location: =src/middleware/session.jl:1-57= and =src/middleware/session_ops.jl:17-263=
Purpose: Route requests to named sessions and implement session lifecycle RPCs.
Depends on: =SessionManager= registry functions and =validate_session_name=.
Used by: all session-targeted ops in the default stack.

How it works:
- =SessionMiddleware= resolves any request with a string =session= field to a =NamedSession= and stores it in =ctx.session=; for evals without a session it creates/destroys an ephemeral session around downstream processing (=src/middleware/session.jl:26-57=).
- =SessionOpsMiddleware= intercepts =new-session=, =ls-sessions=, =close=/=close-session=, and =clone=/=clone-session= without delegating further (=src/middleware/session_ops.jl:63-84=).
- =handle_new_session= creates a persistent session and returns UUID plus optional alias (=src/middleware/session_ops.jl:88-116=).
- =handle_ls_sessions= renders registry state into protocol dictionaries including timestamps, type, module, and eval count (=src/middleware/session_ops.jl:118-139=).
- =handle_close_session= resolves the target session, then destroys it by UUID (=src/middleware/session_ops.jl:141-176=).
- =handle_clone_session= validates source/destination fields, optional clone type, session-limit constraints, then clones bindings into a new named session (=src/middleware/session_ops.jl:178-263=).

** Ancillary operation middleware
- =DescribeMiddleware= serves a capability snapshot synthesized from descriptors (=src/middleware/describe.jl:17-48=).
- =InterruptMiddleware= schedules =InterruptException= onto a running named-session eval and reports the interrupted eval id when present (=src/middleware/interrupt.jl:19-101=).
- =StdinMiddleware= pushes user input into a named session's =stdin_channel= and classifies it as delivered or buffered based on session state (=src/middleware/stdin.jl:20-69=).
- =LoadFileMiddleware= reads a source file and evaluates it in a session module using =Base.include_string= (=src/middleware/load_file.jl:18-117=).
- =CompleteMiddleware= invokes Julia REPL completion and returns completion dictionaries (=src/middleware/complete.jl:12-63=).
- =LookupMiddleware= resolves a symbol and returns doc/method metadata (=src/middleware/lookup.jl:12-94=).
- =UnknownOpMiddleware= is the terminal catch-all that emits =unknown-op= errors (=src/middleware/unknown_op.jl:1-10=).

* Public API and request-flow map
** Exported API clusters
- Package identity: =protocol_name=, =version_string= (=src/REPLy.jl:55-58=).
- Protocol/transport: =AbstractTransport=, =JSONTransport=, =send!=, =receive=, =validate_request=, response helpers, size constants (=src/REPLy.jl:8-11=, =src/protocol/message.jl:1-118=).
- Server lifecycle: =build_handler=, =serve=, =serve_multi=, =MultiListenerServer=, =server_port=, =server_socket_path=, =ServerState= (=src/REPLy.jl:12-15=).
- Session/state: registry helper =get_or_create_named_session!= plus state accessors and transitions (=src/REPLy.jl:14-20=, =src/session/module_session.jl:94-217=, =src/session/manager.jl:193-347=).
- Middleware/admin: =RequestContext=, =HandlerContext=, =dispatch_middleware=, =shutdown_middleware!=, =validate_session_name=, =MiddlewareDescriptor=, =descriptor=, =validate_stack= (=src/REPLy.jl:15-23=, =src/middleware/core.jl:14-154=, =src/middleware/session.jl:8-24=).
- MCP helpers: request/result conversion, lifecycle tool helpers, session bootstrap helper, tool catalog, and stream collector (=src/REPLy.jl:24-28=, =src/mcp_adapter.jl:10-395=).

** Default request flow
1. A caller starts a server with =serve= or =serve_multi= (=src/server.jl:33-75=, =src/server.jl:152-180=).
2. The accept loop accepts a client socket and spawns =handle_client!= (=src/transport/tcp.jl:104-130=).
3. =handle_client!= reads one JSON line with =receive= and enforces transport-local policies (=src/transport/tcp.jl:36-77=, =src/protocol/message.jl:26-46=).
4. The handler closure validates the message envelope and allocates a fresh =RequestContext= (=src/middleware/core.jl:147-154=, =src/protocol/message.jl:99-118=).
5. =SessionMiddleware= resolves or creates the session context when applicable (=src/middleware/session.jl:26-57=).
6. Downstream middleware handles the op (=SessionOps=, =Describe=, =Interrupt=, =Stdin=, =Eval=, or fallback unknown-op in the default stack) (=src/middleware/core.jl:134-136=).
7. Middleware returns a vector or single response object; =finalize_responses= ensures a terminal =done= when needed (=src/middleware/core.jl:117-132=).
8. The transport sends each response object as one JSON line back to the client (=src/protocol/message.jl:12-17=, =src/transport/tcp.jl:88-97=).

** Non-default operation availability
The package contains middleware implementations for =load-file=, =complete=, and =lookup=, but the default middleware stack built by =default_middleware_stack= does not include them (=src/middleware/core.jl:134-136= versus =src/middleware/load_file.jl:18-117=, =src/middleware/complete.jl:12-63=, =src/middleware/lookup.jl:12-94=).

* Session lifecycle map
** Ephemeral eval lifecycle
1. A request with =op="eval"= and no =session= reaches =SessionMiddleware= (=src/middleware/session.jl:43-57=).
2. =SessionMiddleware= checks =max_sessions= when =ServerState= is present, creates a =ModuleSession=, stores it in =ctx.session=, and destroys it in a =finally= block after downstream processing (=src/middleware/session.jl:47-57=).
3. =EvalMiddleware= runs the code in that anonymous module; there is no persistent registry entry for the client after the request completes (=src/middleware/eval.jl:260-266=).

** Persistent named-session lifecycle
1. =new-session= calls =create_named_session!= in =SessionOpsMiddleware=, which creates a =NamedSession= with UUID identity and optional alias (=src/middleware/session_ops.jl:88-116=; =src/session/manager.jl:89-117=).
2. Later requests carrying a string =session= field are resolved by UUID first, then alias via =lookup_named_session= (=src/middleware/session.jl:26-42=; =src/session/manager.jl:133-149=).
3. Named-session evals serialize through =session.eval_lock= and transition state through =try_begin_eval!= and =end_eval!= (=src/session/manager.jl:224-239=; =src/middleware/eval.jl:305-355=).
4. =stdin= operations write into the session channel; =interrupt= operations target the currently running eval task (=src/middleware/stdin.jl:41-69=; =src/middleware/interrupt.jl:40-101=).
5. =close= destroys the session by UUID and marks its state closed (=src/middleware/session_ops.jl:141-176=; =src/session/manager.jl:152-176=).
6. =sweep_idle_sessions!= can also transition idle named sessions to closed and remove them from the registry after a max-idle cutoff (=src/session/manager.jl:253-302=).
7. =clone_named_session!= creates a new named session with copied bindings from an existing one (=src/session/manager.jl:304-347=).

** Session identity model
- Canonical identity for named sessions is the UUID returned by =session_id= (=src/session/module_session.jl:94-99=).
- Human-readable aliases are stored separately in =name_to_uuid= and are optional (=src/session/manager.jl:18-25=, =src/session/module_session.jl:102-107=).
- =ls-sessions= is backed by =list_named_sessions= and therefore excludes ephemeral sessions (=src/session/manager.jl:119-124=; =src/middleware/session_ops.jl:118-139=).

* Test taxonomy map
** Test harness structure
- =test/runtests.jl:1-65= is the single aggregator; it includes shared helpers first, then runs =quality=, =unit=, =integration=, and =e2e= testsets.
- =test/helpers/conformance.jl:1-31= defines protocol-stream ordering and shape assertions.
- =test/helpers/tcp_client.jl:1-51= provides socket send/read helpers that collect done-terminated response streams.
- =test/helpers/server.jl:3-35= provides scoped TCP, Unix-socket, and multi-listener server fixtures.

** Quality layer
- =test/quality_test.jl:1-18= runs Aqua package-quality checks and JET package analysis.

** Unit layer by subject
- Transport/protocol/error helpers: =test/unit/message_test.jl=, =test/unit/error_test.jl=, =test/unit/disconnect_cleanup_test.jl=.
- Session model and registry: =test/unit/session_test.jl=, =test/unit/session_registry_test.jl=, =test/unit/store_history_test.jl=.
- Middleware core and descriptors: =test/unit/middleware_test.jl=, =test/unit/middleware_descriptor_test.jl=.
- Operation middleware: =test/unit/eval_middleware_test.jl=, =test/unit/describe_middleware_test.jl=, =test/unit/load_file_middleware_test.jl=, =test/unit/complete_middleware_test.jl=, =test/unit/lookup_middleware_test.jl=, =test/unit/interrupt_middleware_test.jl=, =test/unit/stdin_middleware_test.jl=, =test/unit/session_ops_middleware_test.jl=.
- Limits/shared state/security-adjacent helpers: =test/unit/resource_limits_test.jl=, =test/unit/server_state_test.jl=, =test/unit/resource_enforcement_test.jl=, =test/unit/audit_log_test.jl=.
- Option/MCP/Revise-specific paths: =test/unit/eval_option_compliance_test.jl=, =test/unit/mcp_adapter_test.jl=, =test/unit/revise_hook_test.jl=.
- A minimal package smoke import lives in =test/unit/basic_test.jl=.

Representative unit testset labels:
- ="eval middleware"=, ="eval timeout cancellation"=, ="eval-id in eval response"= in =test/unit/eval_middleware_test.jl:1,245,331=.
- ="session ops middleware"= plus later schema/identity-focused subtestsets in =test/unit/session_ops_middleware_test.jl:1,287,486,610,794,921=.
- ="named session registry"=, ="UUID session identity"=, and ="idle sweep"= in =test/unit/session_registry_test.jl:1,322,412=.
- ="Resource enforcement — session count and concurrent eval limits"= and ="Resource enforcement — rate limiting and oversized messages"= in =test/unit/resource_enforcement_test.jl:1,105=.

** Integration layer
- =test/integration/pipeline_test.jl:1= exercises the handler pipeline as a composed tracer bullet.
- =test/integration/session_lifecycle_test.jl:8= covers named-session lifecycle behavior.
- =test/integration/session_ops_test.jl:1= covers clone/close/list session ops.
- =test/integration/named_session_persistence_test.jl:1= covers persistence across requests.

** End-to-end layer
- =test/e2e/eval_test.jl:14= covers full TCP eval behavior.
- =test/e2e/unix_socket_test.jl:1= covers Unix domain socket serving.
- =test/e2e/named_session_eval_test.jl:1= covers named-session persistence over TCP.
- =test/e2e/multi_listener_test.jl:1= covers shared-state multi-listener serving.
- =test/e2e/revise_hook_test.jl:7= covers Revise hook behavior against a live server.

* Related documentation and automation surfaces
- =README.md:1-63= is the repository entrypoint with install, TCP quick start, error-handling example, and =just= commands for testing and hygiene.
- =docs/src/index.md:1-116= mirrors the quick-start narrative and links users to status, API, protocol, and session docs.
- =docs/src/reference-protocol.md:1-163= documents the request envelope, response stream contract, status flags, session ops summary, malformed-input handling, and ordering guarantees.
- =docs/src/howto-sessions.md:1-226= documents the named-session lifecycle from creation through sweeping.
- =docs/src/api.md:1-6= is a Documenter =@autodocs= entrypoint for the exported Julia API.
- =justfile:1-42= defines the common automation entrypoints: =test=, =smoke-test=, =coverage=, =docs=, =check=, and =full-check=.

* Open questions
- None for this factual inventory pass.
