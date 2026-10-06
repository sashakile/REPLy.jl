---
id: spec
kind: intent
statement: "WHEN a user chooses execution ownership, THE REPLy runtime SHALL connect to a prepared application or launch an owned worker with explicit supervision and recovery guarantees."
---

## Constraints

| id | kind | expr | traces_to |
|----|------|------|-----------|
| MODE_SELECTION | invariant | Connect and launch are explicit; defaults and host ownership remain unchanged | [[spec]] |
| BOOTSTRAP_CONTRACT | invariant | Connection requires an enabled endpoint and preserves explicit namespace selection | [[spec]] |
| READINESS_CONTRACT | invariant | One ready worker belongs to each launched runtime; startup has a bounded handshake | [[spec]] |
| DEADLINE_CONTRACT | invariant | Supervisor deadlines distinguish unsent queue cancellation from submitted-work retirement | [[spec]] |
| RECOVERY_CONTRACT | invariant | Generation retirement loses runtime state and never replays accepted requests | [[spec]] |
| CLEANUP_CONTRACT | invariant | Owned cleanup preserves unrelated processes and charges unconfirmed worker exit | [[spec]] |
| ENTRYPOINT_CONTRACT | invariant | Owned launch is available through the Julia API and foreground CLI | [[spec]] |
| TRANSPORT_CONTRACT | invariant | Bounded asynchronous queues keep transport backpressure outside deadline arbitration | [[spec]] |
| CANCELLATION_CONTRACT | invariant | Only identity-matched observed cessation confirms cancellation; disconnect may retire submitted work | [[spec]] |
| OWNER_DEATH_CONTRACT | invariant | Managed readiness requires scheduler-independent direct-worker owner-death cleanup | [[spec]] |
| TERMINAL_ARBITRATION | invariant | Completion, deadline and cancellation escalation choose one terminal per connection-scoped request | [[spec]] |
| CAPABILITY_CONTRACT | invariant | Discovery reports execution ownership and actual guarantees without changing session type semantics | [[spec]] |

## Model

This model follows one ownership handle and one representative admitted request. Queued/submitted/cancelling are request substates of a ready runtime; concurrent requests use independent terminal arbitration in the generation registry. Retirement invalidates that registry atomically. Retired/unreaped are cleanup states, not mute failure terminals; they can progress only toward closed. Owner_lost is an external-observer state with no functioning supervisor or promised terminal delivery; it is not an accounting service. New launch creates a separate model instance, never reopens a lost handle.

### States

- `unconfigured`
- `connecting`
- `attached`
- `starting`
- `ready`
- `queued`
- `submitted`
- `cancelling`
- `retired`
- `closing`
- `unreaped`
- `owner_lost`
- `closed`

### Transitions

| id | from | to | guard |
|----|------|----|-------|
| select_connect | unconfigured | connecting | [[spec.MODE_SELECTION]] |
| connect_ready | connecting | attached | [[spec.BOOTSTRAP_CONTRACT]] and validated discovery within budget |
| connect_refused | connecting | closed | [[spec.BOOTSTRAP_CONTRACT]] and discovery failed or budget expired; no worker exists |
| disconnect_attached | attached | closed | [[spec.CANCELLATION_CONTRACT]] and connection closed; host survives |
| select_launch | unconfigured | starting | [[spec.MODE_SELECTION]] and explicit project |
| publish_ready | starting | ready | [[spec.READINESS_CONTRACT]] and [[spec.OWNER_DEATH_CONTRACT]] and validated worker handshake |
| startup_cleanup | starting | closing | [[spec.READINESS_CONTRACT]] and [[spec.OWNER_DEATH_CONTRACT]] and startup deadline or validation failure |
| admit_request | ready | queued | [[spec.TRANSPORT_CONTRACT]] and terminal reservation available |
| submit_request | queued | submitted | [[spec.DEADLINE_CONTRACT]] and first request byte sent before effective deadline |
| expire_partial_submission | queued | retired | [[spec.DEADLINE_CONTRACT]] and [[spec.TRANSPORT_CONTRACT]] and any IPC byte may have arrived before writer deadline |
| cancel_unsent | queued | ready | [[spec.CANCELLATION_CONTRACT]] and no bytes sent before disconnect, interrupt or queue deadline |
| complete_request | submitted | ready | [[spec.TERMINAL_ARBITRATION]] and completion observed before retirement |
| request_cancel | submitted | cancelling | [[spec.CANCELLATION_CONTRACT]] and cancellation grace starts once |
| confirm_cessation | cancelling | ready | [[spec.CANCELLATION_CONTRACT]] and [[spec.TERMINAL_ARBITRATION]] and matching cessation wins |
| expire_submitted | submitted | retired | [[spec.DEADLINE_CONTRACT]] and [[spec.TERMINAL_ARBITRATION]] and deadline wins |
| expire_cancellation | cancelling | retired | [[spec.CANCELLATION_CONTRACT]] and [[spec.TERMINAL_ARBITRATION]] and effective deadline or grace wins |
| retire_ipc | ready | retired | [[spec.TRANSPORT_CONTRACT]] and IPC corruption or worker EOF |
| retire_ipc_queued | queued | retired | [[spec.TRANSPORT_CONTRACT]] and IPC corruption or worker EOF |
| retire_ipc_submitted | submitted | retired | [[spec.TRANSPORT_CONTRACT]] and IPC corruption or worker EOF |
| retire_ipc_cancelling | cancelling | retired | [[spec.TRANSPORT_CONTRACT]] and IPC corruption or worker EOF |
| cleanup_retired | retired | closing | [[spec.RECOVERY_CONTRACT]] and owned termination initiated |
| close_ready | ready | closing | [[spec.CLEANUP_CONTRACT]] and explicit close or owner EOF |
| close_queued | queued | closing | [[spec.CLEANUP_CONTRACT]] and explicit close or owner EOF |
| close_submitted | submitted | closing | [[spec.CLEANUP_CONTRACT]] and explicit close or owner EOF |
| close_cancelling | cancelling | closing | [[spec.CLEANUP_CONTRACT]] and explicit close or owner EOF |
| retain_unconfirmed | closing | unreaped | [[spec.CLEANUP_CONTRACT]] and exit not confirmed after escalation |
| observe_exit | closing | closed | [[spec.CLEANUP_CONTRACT]] and actual exit confirmed |
| observe_delayed_exit | unreaped | closed | [[spec.CLEANUP_CONTRACT]] and actual exit confirmed |
| supervisor_dies_starting | starting | owner_lost | [[spec.OWNER_DEATH_CONTRACT]] and external observer sees supervisor death |
| supervisor_dies_ready | ready | owner_lost | [[spec.OWNER_DEATH_CONTRACT]] and external observer sees supervisor death |
| supervisor_dies_queued | queued | owner_lost | [[spec.OWNER_DEATH_CONTRACT]] and external observer sees supervisor death |
| supervisor_dies_submitted | submitted | owner_lost | [[spec.OWNER_DEATH_CONTRACT]] and external observer sees supervisor death |
| supervisor_dies_cancelling | cancelling | owner_lost | [[spec.OWNER_DEATH_CONTRACT]] and external observer sees supervisor death |
| supervisor_dies_retired | retired | owner_lost | [[spec.OWNER_DEATH_CONTRACT]] and external observer sees supervisor death |
| supervisor_dies_closing | closing | owner_lost | [[spec.OWNER_DEATH_CONTRACT]] and external observer sees supervisor death |
| supervisor_dies_unreaped | unreaped | owner_lost | [[spec.OWNER_DEATH_CONTRACT]] and external observer sees supervisor death |
| confirm_external_exit | owner_lost | closed | [[spec.OWNER_DEATH_CONTRACT]] and external observer confirms owned worker exit |

## Properties

| id | kind | derives_from | generator | predicate |
|----|------|--------------|-----------|-----------|
| mode_selection_holds | unit | [[spec.MODE_SELECTION]] | `test/e2e/execution_modes_test.jl` | connect failure launches zero processes; disconnect kills zero hosts |
| bootstrap_contract_holds | unit | [[spec.BOOTSTRAP_CONTRACT]] | `test/e2e/execution_modes_test.jl` | startup and late bootstrap connect; an unprepared endpoint fails within the shared 5-second discovery budget; valid legacy metadata remains unknown |
| readiness_contract_holds | unit | [[spec.READINESS_CONTRACT]] | `test/e2e/managed_runtime_test.jl` | ready handshake precedes publication and failed startup leaves no published endpoint |
| deadline_contract_holds | unit | [[spec.DEADLINE_CONTRACT]] | `test/e2e/managed_runtime_test.jl` | 100 warmed trials per workload meet 100 ms p99 timeout and ping bounds with reading clients and one terminal per request |
| recovery_contract_holds | unit | [[spec.RECOVERY_CONTRACT]] | `test/e2e/managed_runtime_test.jl` | sibling sessions are invalidated and relaunch has fresh IDs without executing old requests |
| cleanup_contract_holds | unit | [[spec.CLEANUP_CONTRACT]] | `test/e2e/managed_runtime_test.jl` | post-completion disconnect retains worker; close is idempotent; unconfirmed exit retains charges |
| entrypoint_contract_holds | unit | [[spec.ENTRYPOINT_CONTRACT]] | `test/e2e/replyc_test.jl` | one readiness record precedes client eval and stopping the owner closes only its runtime |
| capability_contract_holds | unit | [[spec.CAPABILITY_CONTRACT]] | `test/e2e/execution_modes_test.jl` | legacy fields yield unknown and unsupported memory yields effective limit zero |

| transport_contract_holds | unit | [[spec.TRANSPORT_CONTRACT]] | `test/e2e/managed_runtime_test.jl` | stalled reader stays within 32 MiB and 128 frames; healthy ping and deadline progress |
| cancellation_contract_holds | unit | [[spec.CANCELLATION_CONTRACT]] | `test/e2e/managed_runtime_test.jl` | receipt alone never stops grace; disconnect cancels only its connection and may lose sibling state |
| owner_death_contract_holds | unit | [[spec.OWNER_DEATH_CONTRACT]] | `test/e2e/managed_runtime_test.jl` | forced owner/supervisor death exits direct worker within external watchdog without worker scheduling |
| terminal_arbitration_holds | unit | [[spec.TERMINAL_ARBITRATION]] | `test/e2e/managed_runtime_test.jl` | completion, deadline and grace races select one terminal; retired frames cannot select another |

## ADDED Requirements

### Requirement: Execution Ownership Selection
REPLy SHALL support connecting to an application-owned endpoint and launching a supervisor-owned Julia runtime as explicit choices. Existing serve, Client connection and MCP defaults SHALL remain attached/in-process; no failed connection SHALL implicitly launch a worker.

#### Scenario: Existing application endpoint
- **WHEN** a client connects to an application-owned endpoint
- **THEN** requests run in that application's process and client disconnect leaves the application running

#### Scenario: Explicit owned launch
- **WHEN** launch is explicitly selected with a project
- **THEN** REPLy returns an owned runtime handle only after the worker is ready

### Requirement: Prepared Application Connection
Connect SHALL require an endpoint enabled by code running in the target Julia process, whether during startup, an opt-in bootstrap file, or later through an existing execution channel. The opt-in connect_endpoint TCP/Unix API SHALL validate an ordinary describe stream within one configurable connect_timeout_s budget (default 5 seconds) covering name resolution, connection and matching done terminal; timeout, malformed responses or EOF SHALL close the attempted connection. Existing Client constructors SHALL remain compatible without mandatory discovery. Valid legacy describe without capability fields SHALL yield unknown guarantees. Discovery SHALL require the existing ops/versions objects, json encoding support and the matching done terminal; a done-only peer SHALL fail discovery. It SHALL report an unreachable endpoint within that budget and SHALL NOT inject code into an arbitrary PID. Namespace selection SHALL remain separate: default sessions use anonymous modules and existing Main access requires host opt-in.

#### Scenario: Late bootstrap from a Julia prompt
- **WHEN** the application loads REPLy and starts serve from its existing prompt
- **THEN** another client can connect without restarting that application

#### Scenario: Unprepared headless process
- **WHEN** an application has no enabled endpoint or execution channel
- **THEN** connect reports the missing/unreachable endpoint and does not alter that process

#### Scenario: Discovery shares one bounded budget
- **WHEN** connect_endpoint contacts a silent acceptor, malformed peer or valid legacy describe endpoint
- **THEN** silent/malformed discovery closes within connect_timeout_s, while a valid legacy terminal succeeds with unknown capability guarantees

### Requirement: Managed Runtime Readiness
Launch SHALL resolve an explicit Julia project and start one dedicated supervisor process plus one worker for one owned runtime, with the supervisor serving the public endpoint independently of caller and worker scheduling. API/MCP owners SHALL retain an exclusive control pipe; foreground CLI launch SHALL itself be the supervisor. Managed readiness SHALL require a tested OS-backed direct-worker owner-death mechanism; unsupported platforms SHALL reject launch before readiness. It SHALL enforce startup_timeout_s (default 30 seconds) from launch entry through project resolution, process startup, controls and handshake, publish readiness only after a validated handshake, and close owned startup resources on failure.

#### Scenario: Persistent managed bindings
- **WHEN** two evals address a named session in one ready managed runtime
- **THEN** the second sees the first's bindings while sessions in another runtime remain independent

#### Scenario: Startup deadline expires
- **WHEN** the worker cannot become ready within startup_timeout_s
- **THEN** launch reports startup failure, publishes no usable endpoint and initiates bounded cleanup

### Requirement: Managed Deadline Supervision
The supervisor SHALL own monotonic effective deadlines from execution admission, including queue time. A queued request not yet sent to the worker SHALL time out without retiring the worker. For an overdue request with at least one byte sent to a worker whose completion has not been observed, the supervisor SHALL atomically retire the generation, initiate termination and emit exactly one done/error/timeout/runtime-lost terminal without waiting for process reaping. With continuously reading local clients and runnable supervisor CPU capacity, on reference hardware over at least 100 warmed trials per workload, timeout-response and concurrent supervisor-ping p99 SHALL each be at most 100 ms after their respective trigger for non-yielding Julia and blocking native work.

#### Scenario: Busy worker cannot block supervisor
- **WHEN** a managed eval runs a non-yielding loop beyond timeout-ms while another connection pings the supervisor
- **THEN** timeout and ping satisfy the reference latency bounds and the worker generation is retired

#### Scenario: Queue deadline before submission
- **WHEN** a queued eval reaches its deadline before being sent to the worker
- **THEN** it receives one timeout terminal, never executes and does not destroy other session state

#### Scenario: API caller cannot block supervisor
- **WHEN** non-yielding caller work runs after API launch while an overdue worker eval runs and an independent process pings
- **THEN** the supervisor has its own PID and reading observer timeout/ping satisfy the reference bounds

### Requirement: Runtime Loss and Explicit Recovery
Retiring a managed worker SHALL invalidate every session in that runtime and select exactly one done/error/runtime-lost terminal for each other accepted nonterminal request, without submitting queued work or replaying execution; selected terminals for disconnected peers SHALL be discarded and delivery to reading peers SHALL follow the backpressure contract. Late frames SHALL be discarded by generation. Recovery SHALL require an explicit new launch with a fresh runtime ID and session IDs; external side effects SHALL NOT be represented as rolled back.

#### Scenario: Worker timeout loses sibling sessions
- **WHEN** a submitted eval times out in one of several managed sessions
- **THEN** the triggering request receives timeout plus runtime-lost, other pending requests receive runtime-lost, and no old session remains usable

#### Scenario: Explicit relaunch
- **WHEN** the caller launches a replacement after runtime loss
- **THEN** it starts with fresh identity/state, does not execute previous requests and rejects frames/handles from the retired generation

### Requirement: Owned Runtime Cleanup
Disconnect SHALL close its connection without closing the runtime handle, remove its unsent requests and cooperatively cancel its submitted requests. Only observed cessation matched to generation/connection/request identity SHALL confirm cancellation; receipt or exception scheduling SHALL NOT suffice. Unconfirmed cessation after 100 ms SHALL retire the runtime and notify surviving clients of runtime-lost. Disconnected-client terminals SHALL be selected once and discarded; identical wire ids on other connections SHALL remain distinct. Explicit managed close SHALL be idempotent, stop admissions and initiate owned worker/process-tree termination with shutdown_grace_s (default 5 seconds) before escalation, without killing external applications or another runtime. Resource charges SHALL remain until actual worker exit and any enforced contained process-tree exit are confirmed; an unreaped worker SHALL remain visible to capacity accounting. Manual interrupt SHALL first attempt cooperative cancellation and retire the managed runtime if matching cessation has not been observed within 100 ms of accepted cancellation; the triggering eval SHALL select one done/interrupted/runtime-lost terminal when grace wins, or done/error/timeout/runtime-lost when its deadline wins. Repeated cancellation SHALL NOT reset grace; completion, deadline and escalation SHALL share atomic terminal arbitration.

#### Scenario: Disconnect preserves worker
- **WHEN** a client disconnects after completing a request
- **THEN** the owned runtime remains available for another client

#### Scenario: Unconfirmed termination
- **WHEN** the OS has not confirmed exit after termination escalation
- **THEN** the supervisor remains responsive and retains the worker's resource charge rather than reporting successful reclamation

#### Scenario: Cancellation receipt is not cessation
- **WHEN** the worker confirms receipt of cancellation but the identified eval remains live
- **THEN** the grace timer continues and retires the runtime at 100 ms unless completion or its deadline already won

#### Scenario: Disconnect cancels unsent work
- **WHEN** a client disconnects with an eval queued but zero request bytes sent
- **THEN** that eval never runs, its terminal is discarded and unrelated session state remains usable

#### Scenario: Disconnect escalates submitted work
- **WHEN** a client disconnects with a submitted eval whose cessation cannot be confirmed within 100 ms
- **THEN** the runtime retires, surviving clients receive runtime-lost and an equal request id on a different connection is not mistaken for the disconnected request

### Requirement: Execution Capability Discovery
Describe SHALL expose flat scalar execution-mode, timeout-enforcement, memory-enforcement and effective-memory-limit-mb metadata, plus runtime-id/runtime-state and orphan-cleanup/process-tree-cleanup for managed endpoints. Internal request substates SHALL report runtime-state=ready until retirement; public runtime states SHALL be starting, ready, retired, unreaped or closed; closing SHALL be reported as retired until exit is confirmed or delayed cleanup is reported as unreaped. Owner_lost is an external observation only, not a reachable discovery endpoint. Closed endpoints need not serve discovery; handles report their last observed state. Attached endpoints SHALL report cooperative timeout and unsupported memory enforcement; managed endpoints SHALL report supervised deadlines and their actual OS memory capability. Clients connecting to an endpoint without this metadata SHALL report unknown guarantees. Runtime cloning across endpoints SHALL be unsupported; existing light clones within one runtime and reserved heavy-type behavior SHALL remain unchanged.

#### Scenario: Capability reporting without an OS memory backend
- **WHEN** a managed endpoint runs without memory enforcement
- **THEN** describe reports memory-enforcement=unsupported and effective-memory-limit-mb=0

#### Scenario: Legacy endpoint
- **WHEN** a connected endpoint has no execution capability fields
- **THEN** the client does not infer supervised deadlines or memory enforcement


### Requirement: Owned Runtime Entry Points
REPLy SHALL expose launch with explicit project and startup/cleanup options, Client(runtime), idempotent close(runtime), and a foreground replyc launch command with TCP/Unix endpoint selection. The CLI SHALL print one JSON readiness record on stdout only after the ready handshake, place diagnostics on stderr, and retain supervisor ownership until explicitly stopped; ordinary eval/session CLI commands SHALL connect to the published endpoint without change.

#### Scenario: Foreground launch and ordinary CLI eval
- **WHEN** replyc launch --project PATH publishes its ready endpoint
- **THEN** an existing replyc eval command can evaluate there, and stopping the launch owner initiates only that runtime's cleanup


### Requirement: Managed Transport Backpressure
Managed IPC SHALL bound serialized frames to 16 MiB; larger indivisible public requests SHALL be rejected before submission with done/error/request-too-large. Each asynchronous outbound link/connection queue SHALL include its in-progress write in a 32 MiB and 128-frame ceiling. Each admitted eval SHALL reserve one terminal slot of at most 64 KiB in a registry bounded by three times max_concurrent_evals globally. Non-eval requests SHALL reserve from a separate pool of at most eight per connection bounded by max_connections; overflow SHALL close that connection. Deadline arbitration and readers SHALL NOT wait on writes. Output text SHALL be chunked within the IPC ceiling. Full public queues SHALL close the slow connection and use its disconnect cancellation policy while other worker output continues draining. Partial worker-link submission SHALL count as submitted work; a blocked write reaching deadline SHALL retire its generation if any bytes may have arrived. Exactly-one terminal selection SHALL survive discard; delivery bounds SHALL apply to continuously reading local peers, while stalled peers receive closure.

#### Scenario: Slow client cannot stall control handling
- **WHEN** one client stops reading and fills its output queue during an overdue eval while a healthy client pings
- **THEN** queue bounds hold, the slow connection closes, the healthy observer retains the reference ping bound and cancellation/deadline retirement progresses

#### Scenario: Partial worker write reaches deadline
- **WHEN** a request reaches its deadline after a partial IPC write whose completion is unknown
- **THEN** the generation is retired rather than treating the request as safely unsent

### Requirement: Managed Owner Death Cleanup
Loss of the API/MCP owner's exclusive control pipe SHALL stop admissions and initiate owned close without relying on owner finally handlers. Abrupt supervisor death SHALL trigger tested OS-backed direct-worker termination independently of worker scheduling, including checking the supervisor PID supplied at spawn against getppid after parent-death setup before readiness. Workers SHALL disable startup files and install controls before caller-selected bootstrap/request code. Managed launch SHALL fail when this backend is unavailable. Initial managed support SHALL target Linux; connect/attached support remains unchanged elsewhere. Direct-worker owner-death support SHALL NOT imply descendant cleanup; capabilities SHALL report orphan-cleanup=worker and process-tree-cleanup=unsupported unless a separately tested backend covers descendants after supervisor death. No terminal delivery or live accounting service SHALL be claimed after supervisor death; a dead handle SHALL NOT imply confirmed reclamation.

#### Scenario: Owner disappears without graceful close
- **WHEN** the API or MCP owner is forcibly killed with a live supervisor and worker
- **THEN** exclusive control-pipe EOF stops admissions and initiates cleanup without affecting another runtime

#### Scenario: Supervisor dies during non-yielding eval
- **WHEN** a supervisor is forcibly killed while its worker cannot schedule Julia tasks
- **THEN** the direct worker exits through the OS-backed mechanism within the 30-second external test watchdog and no descendant-cleanup guarantee is inferred

#### Scenario: Owner-death setup races with startup
- **WHEN** the supervisor dies before the worker completes parent-death setup or the backend is unavailable
- **THEN** the parent identity check prevents readiness and the worker exits or managed startup is rejected

## Requirements


### Requirement: Execution Ownership Selection
REPLy SHALL support connecting to an application-owned endpoint and launching a supervisor-owned Julia runtime as explicit choices. Existing serve, Client connection and MCP defaults SHALL remain attached/in-process; no failed connection SHALL implicitly launch a worker.

#### Scenario: Existing application endpoint
- **WHEN** a client connects to an application-owned endpoint
- **THEN** requests run in that application's process and client disconnect leaves the application running

#### Scenario: Explicit owned launch
- **WHEN** launch is explicitly selected with a project
- **THEN** REPLy returns an owned runtime handle only after the worker is ready

### Requirement: Prepared Application Connection
Connect SHALL require an endpoint enabled by code running in the target Julia process, whether during startup, an opt-in bootstrap file, or later through an existing execution channel. The opt-in connect_endpoint TCP/Unix API SHALL validate an ordinary describe stream within one configurable connect_timeout_s budget (default 5 seconds) covering name resolution, connection and matching done terminal; timeout, malformed responses or EOF SHALL close the attempted connection. Existing Client constructors SHALL remain compatible without mandatory discovery. Valid legacy describe without capability fields SHALL yield unknown guarantees. Discovery SHALL require the existing ops/versions objects, json encoding support and the matching done terminal; a done-only peer SHALL fail discovery. It SHALL report an unreachable endpoint within that budget and SHALL NOT inject code into an arbitrary PID. Namespace selection SHALL remain separate: default sessions use anonymous modules and existing Main access requires host opt-in.

#### Scenario: Late bootstrap from a Julia prompt
- **WHEN** the application loads REPLy and starts serve from its existing prompt
- **THEN** another client can connect without restarting that application

#### Scenario: Unprepared headless process
- **WHEN** an application has no enabled endpoint or execution channel
- **THEN** connect reports the missing/unreachable endpoint and does not alter that process

#### Scenario: Discovery shares one bounded budget
- **WHEN** connect_endpoint contacts a silent acceptor, malformed peer or valid legacy describe endpoint
- **THEN** silent/malformed discovery closes within connect_timeout_s, while a valid legacy terminal succeeds with unknown capability guarantees

### Requirement: Managed Runtime Readiness
Launch SHALL resolve an explicit Julia project and start one dedicated supervisor process plus one worker for one owned runtime, with the supervisor serving the public endpoint independently of caller and worker scheduling. API/MCP owners SHALL retain an exclusive control pipe; foreground CLI launch SHALL itself be the supervisor. Managed readiness SHALL require a tested OS-backed direct-worker owner-death mechanism; unsupported platforms SHALL reject launch before readiness. It SHALL enforce startup_timeout_s (default 30 seconds) from launch entry through project resolution, process startup, controls and handshake, publish readiness only after a validated handshake, and close owned startup resources on failure.

#### Scenario: Persistent managed bindings
- **WHEN** two evals address a named session in one ready managed runtime
- **THEN** the second sees the first's bindings while sessions in another runtime remain independent

#### Scenario: Startup deadline expires
- **WHEN** the worker cannot become ready within startup_timeout_s
- **THEN** launch reports startup failure, publishes no usable endpoint and initiates bounded cleanup

### Requirement: Managed Deadline Supervision
The supervisor SHALL own monotonic effective deadlines from execution admission, including queue time. A queued request not yet sent to the worker SHALL time out without retiring the worker. For an overdue request with at least one byte sent to a worker whose completion has not been observed, the supervisor SHALL atomically retire the generation, initiate termination and emit exactly one done/error/timeout/runtime-lost terminal without waiting for process reaping. With continuously reading local clients and runnable supervisor CPU capacity, on reference hardware over at least 100 warmed trials per workload, timeout-response and concurrent supervisor-ping p99 SHALL each be at most 100 ms after their respective trigger for non-yielding Julia and blocking native work.

#### Scenario: Busy worker cannot block supervisor
- **WHEN** a managed eval runs a non-yielding loop beyond timeout-ms while another connection pings the supervisor
- **THEN** timeout and ping satisfy the reference latency bounds and the worker generation is retired

#### Scenario: Queue deadline before submission
- **WHEN** a queued eval reaches its deadline before being sent to the worker
- **THEN** it receives one timeout terminal, never executes and does not destroy other session state

#### Scenario: API caller cannot block supervisor
- **WHEN** non-yielding caller work runs after API launch while an overdue worker eval runs and an independent process pings
- **THEN** the supervisor has its own PID and reading observer timeout/ping satisfy the reference bounds

### Requirement: Runtime Loss and Explicit Recovery
Retiring a managed worker SHALL invalidate every session in that runtime and select exactly one done/error/runtime-lost terminal for each other accepted nonterminal request, without submitting queued work or replaying execution; selected terminals for disconnected peers SHALL be discarded and delivery to reading peers SHALL follow the backpressure contract. Late frames SHALL be discarded by generation. Recovery SHALL require an explicit new launch with a fresh runtime ID and session IDs; external side effects SHALL NOT be represented as rolled back.

#### Scenario: Worker timeout loses sibling sessions
- **WHEN** a submitted eval times out in one of several managed sessions
- **THEN** the triggering request receives timeout plus runtime-lost, other pending requests receive runtime-lost, and no old session remains usable

#### Scenario: Explicit relaunch
- **WHEN** the caller launches a replacement after runtime loss
- **THEN** it starts with fresh identity/state, does not execute previous requests and rejects frames/handles from the retired generation

### Requirement: Owned Runtime Cleanup
Disconnect SHALL close its connection without closing the runtime handle, remove its unsent requests and cooperatively cancel its submitted requests. Only observed cessation matched to generation/connection/request identity SHALL confirm cancellation; receipt or exception scheduling SHALL NOT suffice. Unconfirmed cessation after 100 ms SHALL retire the runtime and notify surviving clients of runtime-lost. Disconnected-client terminals SHALL be selected once and discarded; identical wire ids on other connections SHALL remain distinct. Explicit managed close SHALL be idempotent, stop admissions and initiate owned worker/process-tree termination with shutdown_grace_s (default 5 seconds) before escalation, without killing external applications or another runtime. Resource charges SHALL remain until actual worker exit and any enforced contained process-tree exit are confirmed; an unreaped worker SHALL remain visible to capacity accounting. Manual interrupt SHALL first attempt cooperative cancellation and retire the managed runtime if matching cessation has not been observed within 100 ms of accepted cancellation; the triggering eval SHALL select one done/interrupted/runtime-lost terminal when grace wins, or done/error/timeout/runtime-lost when its deadline wins. Repeated cancellation SHALL NOT reset grace; completion, deadline and escalation SHALL share atomic terminal arbitration.

#### Scenario: Disconnect preserves worker
- **WHEN** a client disconnects after completing a request
- **THEN** the owned runtime remains available for another client

#### Scenario: Unconfirmed termination
- **WHEN** the OS has not confirmed exit after termination escalation
- **THEN** the supervisor remains responsive and retains the worker's resource charge rather than reporting successful reclamation

#### Scenario: Cancellation receipt is not cessation
- **WHEN** the worker confirms receipt of cancellation but the identified eval remains live
- **THEN** the grace timer continues and retires the runtime at 100 ms unless completion or its deadline already won

#### Scenario: Disconnect cancels unsent work
- **WHEN** a client disconnects with an eval queued but zero request bytes sent
- **THEN** that eval never runs, its terminal is discarded and unrelated session state remains usable

#### Scenario: Disconnect escalates submitted work
- **WHEN** a client disconnects with a submitted eval whose cessation cannot be confirmed within 100 ms
- **THEN** the runtime retires, surviving clients receive runtime-lost and an equal request id on a different connection is not mistaken for the disconnected request

### Requirement: Execution Capability Discovery
Describe SHALL expose flat scalar execution-mode, timeout-enforcement, memory-enforcement and effective-memory-limit-mb metadata, plus runtime-id/runtime-state and orphan-cleanup/process-tree-cleanup for managed endpoints. Internal request substates SHALL report runtime-state=ready until retirement; public runtime states SHALL be starting, ready, retired, unreaped or closed; closing SHALL be reported as retired until exit is confirmed or delayed cleanup is reported as unreaped. Owner_lost is an external observation only, not a reachable discovery endpoint. Closed endpoints need not serve discovery; handles report their last observed state. Attached endpoints SHALL report cooperative timeout and unsupported memory enforcement; managed endpoints SHALL report supervised deadlines and their actual OS memory capability. Clients connecting to an endpoint without this metadata SHALL report unknown guarantees. Runtime cloning across endpoints SHALL be unsupported; existing light clones within one runtime and reserved heavy-type behavior SHALL remain unchanged.

#### Scenario: Capability reporting without an OS memory backend
- **WHEN** a managed endpoint runs without memory enforcement
- **THEN** describe reports memory-enforcement=unsupported and effective-memory-limit-mb=0

#### Scenario: Legacy endpoint
- **WHEN** a connected endpoint has no execution capability fields
- **THEN** the client does not infer supervised deadlines or memory enforcement


### Requirement: Owned Runtime Entry Points
REPLy SHALL expose launch with explicit project and startup/cleanup options, Client(runtime), idempotent close(runtime), and a foreground replyc launch command with TCP/Unix endpoint selection. The CLI SHALL print one JSON readiness record on stdout only after the ready handshake, place diagnostics on stderr, and retain supervisor ownership until explicitly stopped; ordinary eval/session CLI commands SHALL connect to the published endpoint without change.

#### Scenario: Foreground launch and ordinary CLI eval
- **WHEN** replyc launch --project PATH publishes its ready endpoint
- **THEN** an existing replyc eval command can evaluate there, and stopping the launch owner initiates only that runtime's cleanup


### Requirement: Managed Transport Backpressure
Managed IPC SHALL bound serialized frames to 16 MiB; larger indivisible public requests SHALL be rejected before submission with done/error/request-too-large. Each asynchronous outbound link/connection queue SHALL include its in-progress write in a 32 MiB and 128-frame ceiling. Each admitted eval SHALL reserve one terminal slot of at most 64 KiB in a registry bounded by three times max_concurrent_evals globally. Non-eval requests SHALL reserve from a separate pool of at most eight per connection bounded by max_connections; overflow SHALL close that connection. Deadline arbitration and readers SHALL NOT wait on writes. Output text SHALL be chunked within the IPC ceiling. Full public queues SHALL close the slow connection and use its disconnect cancellation policy while other worker output continues draining. Partial worker-link submission SHALL count as submitted work; a blocked write reaching deadline SHALL retire its generation if any bytes may have arrived. Exactly-one terminal selection SHALL survive discard; delivery bounds SHALL apply to continuously reading local peers, while stalled peers receive closure.

#### Scenario: Slow client cannot stall control handling
- **WHEN** one client stops reading and fills its output queue during an overdue eval while a healthy client pings
- **THEN** queue bounds hold, the slow connection closes, the healthy observer retains the reference ping bound and cancellation/deadline retirement progresses

#### Scenario: Partial worker write reaches deadline
- **WHEN** a request reaches its deadline after a partial IPC write whose completion is unknown
- **THEN** the generation is retired rather than treating the request as safely unsent

### Requirement: Managed Owner Death Cleanup
Loss of the API/MCP owner's exclusive control pipe SHALL stop admissions and initiate owned close without relying on owner finally handlers. Abrupt supervisor death SHALL trigger tested OS-backed direct-worker termination independently of worker scheduling, including checking the supervisor PID supplied at spawn against getppid after parent-death setup before readiness. Workers SHALL disable startup files and install controls before caller-selected bootstrap/request code. Managed launch SHALL fail when this backend is unavailable. Initial managed support SHALL target Linux; connect/attached support remains unchanged elsewhere. Direct-worker owner-death support SHALL NOT imply descendant cleanup; capabilities SHALL report orphan-cleanup=worker and process-tree-cleanup=unsupported unless a separately tested backend covers descendants after supervisor death. No terminal delivery or live accounting service SHALL be claimed after supervisor death; a dead handle SHALL NOT imply confirmed reclamation.

#### Scenario: Owner disappears without graceful close
- **WHEN** the API or MCP owner is forcibly killed with a live supervisor and worker
- **THEN** exclusive control-pipe EOF stops admissions and initiates cleanup without affecting another runtime

#### Scenario: Supervisor dies during non-yielding eval
- **WHEN** a supervisor is forcibly killed while its worker cannot schedule Julia tasks
- **THEN** the direct worker exits through the OS-backed mechanism within the 30-second external test watchdog and no descendant-cleanup guarantee is inferred

#### Scenario: Owner-death setup races with startup
- **WHEN** the supervisor dies before the worker completes parent-death setup or the backend is unavailable
- **THEN** the parent identity check prevents readiness and the worker exits or managed startup is rejected
