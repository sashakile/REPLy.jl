## 1. Approval and synchronization
- [ ] 1.1 Obtain approval for both ownership modes, runtime-wide loss, mode-aware deadline/memory guarantees and the proposed public APIs; record the decision in nv28 and synchronize q8dz/xbb9/xbb9.1 before implementation.
- [ ] 1.2 Adopt/archive the completed fix-eval-timeout lifecycle change before applying this security delta; reconcile add-first-class-client, refactor-mcp-adapter and update-cli-spec application order. Create/claim Beads implementation slices referencing these task numbers; keep refactoring separate.

## 2. Connect to a prepared application — red then green
- [ ] 2.1 Write failing TCP/Unix integration tests for the shared connect_endpoint DNS/connect/describe budget, silent/malformed peer failure, valid legacy discovery, startup and late bootstrap, explicit host namespace opt-in, disconnect without host termination and unknown capabilities from a legacy endpoint.
- [ ] 2.2 Reuse the first-class Client framing and implement opt-in connect_endpoint, connection/bootstrap documentation and capability reporting; preserve ordinary anonymous-module defaults and existing wire behavior. Run named regression tests and just test.

## 3. Launch an owned persistent runtime — red then green
- [ ] 3.1 Write isolated failing tests for project/environment selection, startup timeout from launch entry, dedicated supervisor PID, caller-saturation responsiveness, owner EOF/forced supervisor death (including parent-death setup race), unsupported owner-death backend rejection, readiness, persistent bindings, multiple sessions, IPC corruption/EOF, idempotent close and cleanup without killing another runtime.
- [ ] 3.2 Implement launch/ManagedRuntime and Client(runtime), dedicated supervisor/worker ownership, Linux owner-death setup and bounded IPC; keep session execution/introspection in the worker and ping/capabilities in the supervisor. Include tests in test/runtests.jl and run full regressions.

## 4. Bound managed responses and retire lost state — red then green
- [ ] 4.1 Write externally watched tests for non-yielding Julia/native work, admission/queue deadlines, completion/deadline races, interrupt escalation, other pending request terminals, late-frame rejection, explicit relaunch and no automatic replay. Include cancellation receipt without cessation, repeated interrupt, attached/managed race distinctions, queued/submitted disconnect with duplicate ids across connections, and sibling-client state loss. Test IPC partial-write ambiguity and stalled clients against 16 MiB frames, 32 MiB/128-frame queues and 64 KiB reserved terminal slots.
- [ ] 4.2 Implement atomic generation retirement, connection-scoped cancellation/cessation confirmation, 100 ms escalation and runtime-wide loss. Implement bounded asynchronous writers/queues and terminal reservations without locking control handling around writes; preserve response order and discard terminals for closed peers. Preserve attached lifecycle/accounting behavior where cooperative delivery is possible. Measure 100-trial p99 response/ping <=100 ms with continuously reading local observers and runnable supervisor CPU capacity, separately from reaping; include retained-charge tests for unconfirmed worker exit.

## 5. Report/enforce memory capabilities — red then green
- [ ] 5.1 Write failing tests for attached unsupported controls, managed strict startup rejection, optional unsupported reporting and a capable OS backend's worker/process-tree cap; supervisor stays outside the capped domain.
- [ ] 5.2 Implement capability detection and supported OS enforcement without treating heap hints/RSS polling as a hard cap. Test zero false enforcement reports; record supported-platform evidence and cold-start measurements.

## 6. CLI and MCP user workflows — red then green
- [ ] 6.1 Write failing CLI tests for foreground replyc launch, endpoint publication, signal/close ownership and existing eval/session clients; implement the opt-in command and run CLI regressions.
- [ ] 6.2 Write actual stdio MCP tests for explicit attached/connect/managed configuration, lifecycle dispatch to the selected backend, runtime-loss isError mapping, EOF and forced-owner-death cleanup, state-loss diagnostics after another client disconnects and unchanged defaults; implement without duplicating the dispatcher. Coordinate with 2rv5.13 and uv9y.

## 7. Review and release evidence
- [ ] 7.1 Document connect/launch tutorials, namespace selection, startup prerequisites, shared-worker state loss, timeout response versus termination, honest memory limits, Linux-first managed platform support, owner-death/descendant capability boundaries, slow-reader closure, disconnect-induced sibling loss and no-replay recovery; update status/API/protocol references.
- [ ] 7.2 Exercise the declared lifecycle model through startup, request arbitration, retirement, closing and delayed exit; run Rule-of-5 review, just test, just smoke-test, strict OpenSpec validation, spk lint and ah check with this overlay after adding real contracts; record exact commit/platform/capabilities and before/after measurements for xbb9.1.
- [ ] 7.3 New source files carry Purpose/Responsibilities/Rationale; changed contracts update Rationale. Never weaken assertions, hide failures, add unapproved dependencies or bundle refactoring into a behavior slice. File separate Beads tickets for necessary tidy work and commit separately only after behavior gates pass.

## Authoring check baseline

Strict OpenSpec validation and spk lint pass for this draft. ah check --changes add-managed-execution-modes reported 48 structural findings before review revisions: 31 scenarios lacked executable TOML contracts and 17 existing scenario identities conflicted with the overlay. The revised count is recorded below after validation. Task 7.2 must reconcile overlay contracts/identities and add real failing regressions; do not declare readiness from the authoring checks or suppress these findings with placeholders. Runtime implementation and test execution remain pending approval.

Review-revision baseline (2026-10-06): 62 structural findings — 44 no-toml and 18 overlay-conflict; no runtime contract tests were executed. Canonical ah check remains at zero findings. The added disconnect delta contributes one additional inherited scenario identity conflict; retain coverage while reconciling overlay identities during implementation.
