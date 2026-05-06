---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

#+title: Formal Verification Readiness Evaluation: REPLy.jl (REPLy_jl-umg.10)
#+date: 2026-04-29

* Executive Summary

REPLy.jl exhibits *moderate formal-verification readiness* with clear, bounded state machines and well-defined safety/liveness concerns. The subsystem divides cleanly into two verification domains: session lifecycle (small finite-state model) and per-session FIFO eval ordering (linearizability). However, enforcement is currently *partial* — the intended invariants live in comments, lock conventions, and caller discipline rather than being structurally encoded.

Recommended scope for initial verification: Session lifecycle state machine (INV-3) plus lock-ordering invariant (INV-6) plus FIFO serialization guarantee (INV-5), verified via model checking on a bounded session count (1-3 concurrent sessions). This is tractable, high-impact, and covers the highest-risk failure modes identified in prior research.

Top four candidates for formalization:
1. Named session lifecycle is a 3-state machine with terminal closure (INV-3) — Safety
2. Lock ordering convention manager.lock → session.lock is respected on all paths (INV-6) — Safety
3. Per-session FIFO depends on eval_lock serialization (INV-5) — Safety + Liveness
4. Exactly one terminal done-status per request (from failure-handling pass) — Safety

* Invariant Candidates for Formalization

** INV-3: Session Lifecycle State Machine (3-State, Terminal Closure)

Files: =src/session/module_session.jl= (SessionState enum, transition helpers: begin_eval!, end_eval!, try_begin_eval!), =src/session/manager.jl= (destroy_named_session!, create_named_session! replacement path)

Observable behaviors:
- A NamedSession starts in SessionIdle
- Idle → Running (via begin_eval! or try_begin_eval!)
- Running → Idle (via end_eval!)
- Closed is terminal: reached only via destroy_named_session!; no transitions out

Safety vs Liveness: *SAFETY*. Once a session enters SessionClosed, it must never return to any other state.

Formalizability score: 4/5
- State space is tiny (3 states)
- Transitions are explicit in code
- Entry/exit conditions are locally checkable
- Risk: raw field mutation is possible (bypasses helpers)

Verification paradigm: Model checking (TLA+ or Alloy)

Expected model sketch:
#+begin_example
SessionState ::= Idle | Running | Closed

-- Valid transitions
can_transition(Idle, Running)
can_transition(Running, Idle)
can_transition(_, Closed)   -- one-way terminal

INVARIANT: ALWAYS (state = Closed => NEXT(state) = Closed)
#+end_example

** INV-6: Lock Ordering Convention (manager.lock → session.lock)

Files: =src/session/manager.jl= (destroy_named_session!, sweep_idle_sessions!, clone_named_session!)

Observable behaviors:
- Code that needs both locks must acquire manager.lock first
- session.eval_lock is never acquired while holding session.lock
- All paths in manager.jl that call lock(session_ref.lock) are nested inside lock(manager.lock)

Safety vs Liveness: *SAFETY* (deadlock prevention). Violation enables deadlock and use-after-free.

Formalizability score: 3/5
- Whole-program property (not local to one function)
- Julia's ReentrantLock has no static type-level enforcement
- Documentation exists but code doesn't enforce it

Verification paradigm: Static analysis + type system or SAT solver constraint check

** INV-5: Per-Session FIFO via eval_lock Serialization

Files: =src/session/module_session.jl= (eval_lock field on NamedSession), =src/middleware/eval.jl= (lock(session.eval_lock) wraps try_begin_eval! and eval logic), =src/middleware/load_file.jl=

Observable behaviors:
- Two concurrent eval requests to same NamedSession must serialize
- eval_lock is held for the entire eval's lifetime (including I/O capture and result streaming)
- Ephemeral sessions have no cross-request state, so eval_lock not required

Safety vs Liveness: *SAFETY + LIVENESS*. Safety: no interleaving of two evals' state mutations. Liveness: every queued eval eventually acquires the lock (fairness via ReentrantLock).

Formalizability score: 4/5
- FIFO fairness guaranteed by ReentrantLock semantics
- Critical section boundaries are clear
- Risk: eval_lock scope is not enforced at type level

Verification paradigm: Property-based testing (PropCheck.jl) + TLA+ model checking

Expected property:
#+begin_example
PROPERTY: PerSessionFIFO
For any R1, R2 targeting same session S,
if R1 arrives before R2:
  - R1's eval_task is assigned before R2's
  - observable effect is as if R1 completes fully before R2 begins
#+end_example

** INV-1: Registry Separation (Ephemeral vs Named)

Files: =src/session/manager.jl= (SessionManager fields, create_ephemeral_session!, create_named_session!, list_named_sessions, destroy_session!)

Safety vs Liveness: *SAFETY*. Violation leaks ephemeral sessions into ls-sessions output.

Formalizability score: 5/5 — simple set-membership property, already well-tested.

** INV-4: State/Task/Activity Fields Move Atomically

Files: =src/session/module_session.jl= (begin_eval!, end_eval!, try_begin_eval!)

Invariant: Running ⟺ eval_task ≠ nothing; Idle OR Closed ⟺ eval_task = nothing

Safety vs Liveness: *SAFETY*. Violation allows readers to see partial state.

Formalizability score: 4/5 — simple predicate, enforced by session.lock, expressible as a type invariant.

** Terminal Done-Status Invariant

Files: =src/middleware/eval.jl=, =src/protocol/message.jl=

Safety vs Liveness: *SAFETY + LIVENESS*. Exactly one terminal message per request; every request eventually terminates.

Formalizability score: 5/5 — simple LTL formula, already confirmed by conformance tests.

* Safety vs Liveness Classification

| Invariant               | Property Type     | Justification                                              |
|-------------------------+-------------------+------------------------------------------------------------|
| INV-1: Registry sep.    | Safety            | Ephemeral in named registry → bad side effect              |
| INV-2: Alias/UUID       | Safety            | Wrong session returned or lookup fails unexpectedly        |
| INV-3: Lifecycle SM     | Safety            | Closed session transitions again → undefined behavior      |
| INV-4: Atomic fields    | Safety            | Reader sees Running with eval_task = nothing               |
| INV-5: FIFO eval order  | Safety + Liveness | No interleaving (safety) + all evals execute in order (liveness) |
| INV-6: Lock ordering    | Safety            | Deadlock or use-after-free                                 |
| Terminal done-status    | Safety + Liveness | Exactly one terminal (safety) + terminal always arrives (liveness) |

* Verification Paradigm Recommendations

| Invariant       | Paradigm                         | Tools                  | Effort |
|-----------------+----------------------------------+------------------------+--------|
| INV-3           | Model checking                   | TLA+, Alloy            | Medium |
| INV-6           | Static analysis + type system    | Linter, Z3             | Low-Med |
| INV-5           | PropTest + Model checking        | PropCheck.jl + TLA+    | Medium |
| INV-1           | Unit testing (sufficient)        | Current tests          | Low    |
| INV-2           | Data structure invariant checker | Isabelle/Coq (future)  | High   |
| INV-4           | Runtime monitor + type macros    | Contracts.jl           | Low    |
| Terminal done   | Model checking (confirm)         | TLA+                   | Low    |

* Recommended Verification Scope

Phase 1 (MVP, 2-3 weeks): Formally verify INV-3 + INV-5 using TLA+ on a bounded model:
- Session count: 0–3 concurrent sessions
- Per-session eval queue depth: 0–2
- Operations: create_named, destroy, clone, eval_start, eval_end

LTL invariants to check:
#+begin_example
-- Closed is terminal
ALWAYS (state = Closed => NEXT(state) = Closed)

-- FIFO ordering
ALWAYS (
  (eval_submitted[1] BEFORE eval_submitted[2]) =>
    (eval_completed[1] BEFORE eval_completed[2])
)

-- Mutual exclusion within one session
ALWAYS (NOT (eval_running[s,1] AND eval_running[s,2]))
#+end_example

Phase 2 (follow-up sprint): INV-6 static analysis, INV-2 after bug fixes, runtime monitor for INV-4.

* Risk/Reward Assessment

Reward:
- INV-3 + INV-5 cover ~60% of concurrency risk identified in prior passes
- Formal model becomes authoritative spec and refactoring safety net
- Estimated code coverage boost for race conditions not exercisable by normal tests

Cost:
- TLA+ learning curve: 1-2 weeks for first developer
- Model maintenance overhead if code changes
- Phase 1 MVP: 2-3 weeks; Phase 2: 3-4 additional weeks

Risk of NOT verifying:
- HIGH probability of another lifecycle race (like HAZ-1 close-vs-eval) surfacing in production
- Impact: session state corruption, undefined behavior on closed sessions, potential security incident
- Recovery cost (2-3 weeks debug + audit) likely exceeds formalization cost

Verdict: PROCEED. Positive ROI on Phase 1 MVP.

* Findings Requiring Follow-up Tickets

** [IS-3] Alias Replacement Creates Detached Objects
Files: =src/session/manager.jl:create_named_session!=
Severity: HIGH
Blocks: INV-2 formalization
Summary: Same-alias replacement marks old session Closed and removes from registry, but callers holding references to the old object can still mutate it.
Options: (A) disallow same-name replacement, (B) make explicit destructive, (C) acquire eval_lock before close.
Recommended: Option A or B.

** [IS-7] Clone Registration Before Completeness
Files: =src/session/manager.jl:clone_named_session!=
Severity: HIGH
Blocks: clone safety proof
Summary: Destination clone published to named_sessions before binding-copy loop completes. Exception mid-copy leaves partially-initialized session discoverable.
Recommended: Two-phase pattern — copy privately, publish atomically only on success.

** [IS-6] Active Eval Bookkeeping Leak
Files: =src/middleware/eval.jl:eval_responses=
Severity: HIGH
Blocks: server-state invariant
Summary: When module path is invalid, active_evals decremented but active_eval_tasks not cleaned up. Stale task entries possible.
Recommended: Move module resolution before registration.

** [HAZ-1] Close vs Running Eval Race
Files: =src/middleware/session_ops.jl:handle_close_session=, =src/session/manager.jl:destroy_named_session!=
Severity: HIGH
Blocks: close semantics specification
Summary: close removes session from registry without acquiring eval_lock. In-flight evals may continue on detached object.
Recommended: Acquire eval_lock before transitioning to Closed; document close as blocking until in-flight evals complete.

** [MATH-1] max_sessions Enforcement Is Non-Atomic
Files: =src/middleware/session.jl=, =src/middleware/session_ops.jl=
Severity: MEDIUM
Blocks: resource-limit invariant
Summary: Check total_session_count < max_sessions is not atomic with creation; two concurrent creators can both pass and exceed the limit.
Recommended: Wrap creation and count check in single manager.lock critical section.
