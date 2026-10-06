# Change: Add explicit connect and launch execution modes

## Why

Julia tool builders need both access to a live application's state and a Julia environment they can start and stop themselves. Current REPLy starts an in-process server and advertises deadline guarantees that a non-yielding eval can suppress. Separate ownership contracts make both workflows usable without presenting cooperative interruption as process isolation.

## What Changes

- Add a documented connect workflow for an endpoint explicitly enabled inside the target Julia application, at startup or later through an existing Julia prompt. Connecting does not inject code into an arbitrary PID.
- Add `REPLy.launch` returning an owned managed-runtime handle: a dedicated supervisor OS process hosts the public endpoint and starts one Julia worker containing that runtime's sessions.
- Preserve existing client connection constructors and `serve` behavior. Offer a foreground `replyc launch` command and explicit MCP connect/managed configuration; existing MCP configuration remains in-process.
- Distinguish execution ownership from namespace selection: ordinary sessions retain anonymous modules; application `Main` access is an explicit host opt-in.
- On a managed deadline, the supervisor atomically returns one timeout terminal, retires the worker generation, and attempts process termination. Other pending requests receive runtime-lost; every session in that worker loses state. Relaunch is explicit and never replays code.
- Add opt-in connect_endpoint discovery with one configurable 5-second default budget; keep existing Client constructors compatible.
- Confirm cancellation only after identified eval cessation; submitted-work disconnect can escalate after 100 ms and lose sibling state.
- Bound asynchronous transport queues and distinguish terminal selection from delivery to a stalled reader.
- Require OS-backed direct-worker cleanup on supervisor death before managed readiness; initially target Linux and report descendant cleanup separately.
- Advertise mode, capabilities, effective resource controls and limits without changing flat request/response framing.
- **BREAKING contract clarification:** attached deadlines/interrupts are cooperative and cannot guarantee a response while their scheduler is blocked. Managed deadline/control-plane latency is measured separately from process-reaping latency. Existing wire keys and default execution remain unchanged.
- Make memory-enforcement support explicit. Attached execution reports unsupported. Managed launch fails when a caller requires an unavailable OS limit backend; optional enforcement never reports an unenforced cap as effective.

## Impact

- Delta specs: execution-management (new), security, resource-limits, mcp-adapter. Existing light/heavy session selection remains unchanged: launch owns a runtime, not a new per-session clone type.
- Implementation areas: src/client.jl, src/server.jl, src/middleware/describe.jl, src/middleware/eval.jl, src/mcp/server.jl, src/mcp/results.jl, src/replyc.jl, src/config/resource_limits.jl; new runtime/supervisor code and integration/E2E tests.
- Tracks REPLy_jl-0em8; proposes the outcome for decision REPLy_jl-nv28 and implementation REPLy_jl-q8dz under milestone REPLy_jl-xbb9. Approval is pending; these tickets remain open.
- Reuse add-first-class-client for TCP/Unix client framing. Coordinate with refactor-mcp-adapter and update-cli-spec; those changes must not duplicate ownership APIs or revert new guarantees.
- Completed fix-eval-timeout governs post-timeout accounting, not scheduler-independent response. Before applying this change, archive/adopt its deployed lifecycle delta, then apply this security delta as the subsequent contract. Do not implement this proposal concurrently with an overlapping security/spec archive.

## Approval Scope

Approve both modes, one worker per managed runtime, unchanged defaults, runtime-wide loss on worker termination, explicit relaunch/no replay, the proposed APIs and latency tests, dedicated supervisor topology, cancellation/disconnect escalation, bounded transport policies, Linux-first managed owner-death support and the capability-based memory contract. This is a design proposal, not authorization to implement, publish or deploy.
