## MODIFIED Requirements

### Requirement: Ephemeral Sessions
For session-bearing execution operations that omit the `session` field (for v1.0: `eval` and `load-file`), the server SHALL trigger ephemeral session handling: a transient light session is created, used, and destroyed after the eval task actually terminates. A terminal timeout response SHALL NOT destroy a still-live ephemeral session. The ephemeral session ID is NOT returned to the client. (REQ-RPL-035)

#### Scenario: Ephemeral eval leaves no persistent session
- **WHEN** `eval` is sent without a `session` field and completes
- **THEN** `ls-sessions` does not include that session after completion

#### Scenario: Ephemeral sessions count against max_sessions
- **WHEN** `max_sessions` is reached by persistent sessions
- **THEN** ephemeral requests are rejected with `{"status":["done","error","session-limit-reached"],"err":"Session limit reached"}` (REQ-RPL-035b)

#### Scenario: Ephemeral evals count against max_concurrent_evals
- **WHEN** `max_concurrent_evals` is reached and the bounded queue is full
- **THEN** new ephemeral evals are rejected with `{"status":["done","error","concurrency-limit-reached"],"err":"Too many concurrent evals"}` (REQ-RPL-035c)

#### Scenario: Ephemeral evals are not interruptible
- **WHEN** an ephemeral eval is running
- **THEN** there is no mechanism to interrupt it because the session ID is not returned to the client. The eval terminates only via completion, timeout cancellation, client disconnect cancellation, or process termination.

#### Scenario: Ephemeral zombie remains accounted
- **WHEN** an ephemeral eval returns a timeout response while its task remains live
- **THEN** its hidden session, active-task registration, EvalGate permit, and `max_sessions` charge remain until actual task termination

#### Scenario: Ephemeral zombie eventually cleans up
- **WHEN** an ephemeral zombie later terminates
- **THEN** completion cleanup deregisters it, releases its permit and session charge, and tears down its module exactly once

### Requirement: Session Lifecycle State Machine
Every named session object SHALL occupy exactly one of `CREATED`, `ACTIVE`, `EVAL_RUNNING`, `QUARANTINED`, internal `DETACHED`, or `DESTROYED`. Zombie classification SHALL transition the object irreversibly to `QUARANTINED`; task termination SHALL NOT restore it to `ACTIVE`. Close of an `EVAL_RUNNING` or `QUARANTINED` object with a live task SHALL transition it to `DETACHED`, atomically remove its alias from discovery, and retain its accounting. Actual task termination SHALL perform object-identity-keyed teardown and transition `DETACHED` to `DESTROYED` exactly once. Close of a `QUARANTINED` object whose zombie has already terminated SHALL atomically remove its alias, perform normal teardown exactly once, and transition directly to `DESTROYED` without entering `DETACHED`. All transitions SHALL be atomic with respect to `SessionManager.lock`. (REQ-RPL-038)

#### Scenario: State transitions are atomic
- **WHEN** `close` and `clone` (same parent) race
- **THEN** exactly one wins; the other receives `session-not-found`

#### Scenario: Close removes discovery without eval lock
- **WHEN** `close` targets a session with a running or queued eval
- **THEN** close transitions the live object to `DETACHED`, atomically removes it from discovery, and returns within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion
- **AND** queued operations wake and return `session-not-found` without executing

#### Scenario: Close tears down a terminated quarantined session immediately
- **WHEN** `close` targets a quarantined session whose zombie task has already terminated and whose completion accounting has been released
- **THEN** close atomically removes the session from discovery, performs normal teardown exactly once, and transitions `QUARANTINED` directly to `DESTROYED`
- **AND** it does not enter `DETACHED` or wait for another task-completion event
- **AND** it returns within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion

#### Scenario: Close timeout and interrupt resolve one eval response
- **WHEN** `close`, timeout, and `interrupt` race against the same running eval
- **THEN** close only detaches discovery and interrupt only requests cancellation; neither determines the eval terminal result
- **AND** observed task termination determines interrupted completion only if it precedes the deadline, otherwise a task live at the deadline becomes a zombie and yields timeout
- **AND** exactly one eval terminal response is emitted and completion cleanup runs exactly once

#### Scenario: Timeout and close retain hidden accounting
- **WHEN** timeout quarantines a live eval while close concurrently removes its named session from discovery
- **THEN** the hidden session continues to count against `max_sessions` until actual task termination
- **AND** close does not acquire or wait on `eval_lock`, EvalGate, or task completion

#### Scenario: Alias reuse is safe from late cleanup
- **WHEN** a closed session alias is reused for a new session before the old hidden task terminates
- **THEN** alias lookup resolves the replacement and the old closed eval is not recoverable through the alias
- **AND** old-task cleanup is keyed by old object identity and cannot inspect, remove, or mutate the replacement

#### Scenario: Interrupt request follows current alias resolution
- **WHEN** an `interrupt` request's `session` field names an alias that was reused after the old session became `DETACHED`
- **THEN** the `session` field resolves only to the replacement session and the request cannot reach the old detached object
- **AND** if the request's `interrupt-id` eval ID filter matches the old detached eval rather than an eval in the replacement session, the request is an idempotent no-op

## ADDED Requirements

### Requirement: Permanent Named-Session Quarantine
A named session object whose eval becomes a zombie SHALL remain permanently quarantined unless close transitions it to `DETACHED`, including after the eval task terminates. Normal session-targeting operations and `stdin` SHALL return `session-quarantined` within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion. Best-effort idempotent `interrupt` and close with the same no-wait response bound SHALL remain allowed.

#### Scenario: Normal operation rejects quarantined session without waits
- **WHEN** an eval, load-file, complete, lookup, clone-from, or other normal session-targeting operation targets a quarantined session
- **THEN** it returns `session-quarantined` within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion

#### Scenario: Stdin rejects quarantined session without waits
- **WHEN** `stdin` targets a quarantined session
- **THEN** it returns `session-quarantined` within 100 ms p99 on reference hardware without buffering input or acquiring or waiting on `eval_lock`, EvalGate, or task completion

#### Scenario: Interrupt remains best-effort and idempotent
- **WHEN** `interrupt` targets a quarantined session before or after its zombie terminates
- **THEN** it returns within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion, attempts cancellation only if the task remains live, and repeated requests have no additional effect

#### Scenario: Quarantine persists after termination
- **WHEN** a named zombie task terminates and completion accounting is released
- **THEN** its named session remains quarantined until close removes it from discovery under the no-wait 100 ms p99 response contract

#### Scenario: Queued session operation observes quarantine
- **WHEN** an operation queued before timeout wakes after the session becomes quarantined
- **THEN** it returns `session-quarantined` within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion, and does not execute

#### Scenario: Close is bounded and idempotent
- **WHEN** `close` targets a quarantined session one or more times
- **THEN** the first call atomically removes discovery and returns within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion
- **AND** if the zombie remains live, it transitions the object to `DETACHED` and leaves object-identity-keyed cleanup deferred until termination
- **AND** if the zombie already terminated, it performs normal teardown exactly once and transitions the object directly to `DESTROYED`
- **AND** later calls return `session-not-found` within the same bound without disturbing completed or deferred cleanup
