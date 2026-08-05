## Context

Julia task interruption is cooperative. Native work can remain live after the client deadline, so a timeout response and resource reclamation are separate events. Releasing permits or session identity on response would under-account live work and permit unsafe alias reuse.

## Goals / Non-Goals

- Goals: meet the reference-hardware 100 ms p99 response bound; preserve exact live-work accounting; quarantine affected named sessions; detach close-hidden live objects coherently; reject impossible queued work without lock or task waits; clean up exactly once after real termination.
- Non-goals: forcibly reclaim native work inside the process, restore a quarantined session, or make light sessions a hard isolation boundary.

## Decisions

### Live task owns its accounting until termination

An admitted eval owns exactly one EvalGate permit and one active-task registration from admission through actual task termination. Its session or ephemeral resource charge follows the same lifetime. A single completion path atomically claims cleanup ownership and releases each resource exactly once.

Manual `interrupt` only records and delivers an idempotent cancellation request. Observed task termination determines interrupted completion only when it occurs before the deadline transition. At the deadline, completion observation and timeout classification race through one atomic transition: completed work follows its observed completion, while a task still live becomes a zombie before the timeout response. Ineffective earlier cancellation cannot suppress timeout classification. The eval emits exactly one terminal response; emitting `done` does not release live-work accounting.

### Named zombie sessions are permanently quarantined

Zombie classification irreversibly quarantines the named session object, including after its task terminates. Normal session-targeting operations and `stdin` return `session-quarantined` without acquiring or waiting on `eval_lock`, EvalGate, or task completion and meet the reference-hardware 100 ms p99 response bound. `interrupt` remains best-effort and idempotent. `close` has the same no-wait and response-bound semantics.

### Close separates discovery from reclamation according to task liveness

Close atomically removes the alias/session ID from discovery and returns without acquiring or waiting on `eval_lock`, EvalGate, or task completion. If an `EVAL_RUNNING` or `QUARANTINED` object still owns a live task, close transitions it to internal `DETACHED`; the hidden object remains accounted against `max_sessions`, and actual task termination performs object-identity-keyed cleanup and transitions that object to `DESTROYED` exactly once. If a quarantined object's zombie has already terminated and completion accounting has been released, close performs normal teardown and transitions `QUARANTINED` directly to `DESTROYED` exactly once. It does not enter `DETACHED`, because no future task-completion event remains to trigger deferred teardown. The close decision and lifecycle transition are atomic with respect to the session manager, while both branches preserve the bounded no-wait contract.

In either branch the alias is immediately reusable: lookup may resolve a replacement, the old closed eval is no longer recoverable through the alias, and old or concurrent cleanup cannot inspect, mutate, or remove the replacement. For an `interrupt` request, the `session` field names and resolves the alias; `interrupt-id` is only an eval ID filter within that resolved session. After alias reuse, the request can reach only the replacement session, and an `interrupt-id` matching the old detached eval is an idempotent no-op rather than a route to old work.

### Ephemeral zombies remain visible to accounting only

An ephemeral zombie remains in the active-task registry and retains its EvalGate and `max_sessions` charges until termination. It has no client-discoverable session identity.

### Saturation rejection has explicit wait and latency semantics

If zombie-held permits consume capacity such that queued acquisitions cannot progress, the gate marks those acquisitions rejectable and wakes them. Routing returns `concurrency-limit-reached` for both new and already queued requests without acquiring or waiting on EvalGate, `eval_lock`, or task completion, within 100 ms p99 on reference hardware; requests do not remain stranded behind non-cooperative work.

### Process termination is the hard boundary

Light-session timeout bounds the response, not execution. Only process termination guarantees reclamation of non-cooperative native work; process-isolated heavy sessions are required when a hard execution boundary is needed.

## Risks / Trade-offs

- A zombie can permanently consume eval and session capacity until it terminates or the process exits. No-wait rejection within 100 ms p99 on reference hardware makes this explicit rather than overcommitting resources.
- Permanent quarantine sacrifices session recovery to prevent concurrent reuse of state that may still be mutated.
- Deferred and immediate teardown require identity checks and a shared exactly-once cleanup protocol; race-focused tests are mandatory.

## Migration Plan

Implement behind the existing timeout behavior, replacing release-on-timeout semantics. Existing clients continue receiving the canonical timeout response; clients targeting a quarantined session additionally receive `session-quarantined`.

## Open Questions

None for this proposal.
