# Rule of 5 Review - Final Report

**Work Reviewed:** Design proposal — openspec/changes/add-managed-execution-modes/ (proposal.md, design.md, tasks.md and four spec deltas), against cc42040 and current source.
**Convergence:** Not established after Stage 5; ESCALATE_TO_HUMAN for four low-confidence verification results.

## Summary

Total candidate issues by severity:
- CRITICAL: 0
- HIGH: 6 — 2 VERIFIED, 4 REVIEW_REQUIRED
- MEDIUM: 2 — UNVERIFIED (excluded from API verification by the invoked skill)
- LOW: 0

TypeSafe was available. Mechanical location/quote checks passed for every submitted finding. All six high-severity findings were sent in one request using the prescribed verification question and choice criteria. CORR-001 and EDGE-002 exceeded the confidence gate. DRAFT-001 received a low-confidence contradicted result (0.18); CLAR-001, EDGE-001 and EDGE-003 received verified results below the gate (0.74, 0.59 and 0.79). Those four remain REVIEW_REQUIRED under the skill's “Any verdict with confidence < CONFIDENCE_GATE” rule and must not be presented as independently verified defects. False-positive rate for these unresolved results is unmeasured.

## Top 3 Critical Findings

No CRITICAL findings. The most consequential candidates are:

1. [CORR-001] HIGH / VERIFIED — unscoped timeout/manual-interrupt collision promises attached zombie behavior in the same delta that requires managed retirement and runtime-lost (specs/security/spec.md:59).
   Impact: The managed race can satisfy one contract and violate another.
   Fix: Scope the existing race to attached execution and add a managed race scenario covering the winner, generation retirement, sibling failures and exactly one terminal.

2. [EDGE-002] HIGH / VERIFIED — disconnect is specified/tested only after completion (specs/execution-management/spec.md:114), leaving the inherited BIZ-008 cancellation behavior unresolved for managed running and queued evals.
   Impact: It is unclear whether a disconnected client leaves work alive, cancels only its requests, or initiates escalation that loses sibling clients' state.
   Fix: Specify queue cancellation and submitted-work policy, including escalation/state loss and cancellation identity; test with a second client using another session.

3. [CLAR-001] HIGH / REVIEW_REQUIRED — cancellation acknowledgement does not distinguish accepted cancellation from confirmed eval cessation (design.md:41).
   Impact: Existing interrupt responses follow scheduling cancellation, rather than confirming termination; native work can outlive that acknowledgement.
   Fix: Define the acknowledgement identity and meaning and add a test where cancellation is accepted but the eval remains live past the 100 ms escalation threshold.

## Stage-by-Stage Quality

- Stage 1 (Draft): FAIR — coherent ownership split; supervisor scheduling boundary and lifecycle model need resolution.
- Stage 2 (Correctness): FAIR — verified cross-mode contract conflict.
- Stage 3 (Clarity): FAIR — acknowledgement and connect/handshake public API need precision.
- Stage 4 (Edge Cases): FAIR — verified disconnect gap; backpressure and abrupt owner death need review.
- Stage 5 (Excellence): FAIR — no new distinct findings; review completed, unresolved verification prevents convergence.

## Recommended Actions

1. Correct the two verified contract gaps before approval: scope timeout races by mode and define managed disconnect cancellation/escalation.
2. Resolve the four REVIEW_REQUIRED questions with the maintainer: supervisor placement/caller scheduling assumptions, interrupt acknowledgement, slow-reader behavior, and abrupt owner death.
3. Replace the nominal lifecycle model with lifecycle states/transitions, and specify the connection timeout/handshake API.
4. Extend the TDD task slices with the resulting race, stalled-reader, mid-eval EOF and owner-death test shapes. Reconcile existing overlay scenario identities while keeping scenario coverage; add executable contracts with their implementation slices.
5. Re-run review and overlay correspondence checks after revision; retain the existing implementation-approval gate.

## Verdict

NEEDS_REVISION

**Rationale:** The architecture is reasonable, but two independently verified contract gaps must be corrected before implementation, and four further design questions require human adjudication under the invoked skill. Neither syntax checks nor this review establishes runtime readiness or implementation approval.

## Validation ledger

Changed — review artifacts and review-ticket state only; draft and runtime source unchanged.
Verified — openspec validate add-managed-execution-modes --strict --no-interactive: valid. spk lint openspec/changes/add-managed-execution-modes: 4 specs, 0 issues. ah check --changes add-managed-execution-modes: 48 structural findings (31 no-toml, 17 overlay-conflict), 0 tests passed/executed; matches the draft baseline. All cited locations/quotes exist; TypeSafe verification used jev-1.13.0, returned by requested jev-latest.
Review — five sequential Rule-of-5 passes, source/spec cross-checks, one conditional TypeSafe verification batch. No subagents used.
Risks — four high findings require human review; two medium findings remain UNVERIFIED; no runtime implementation or tests were run because this is a proposal review.
Next — revise the draft, adjudicate outstanding questions, then re-review before requesting proposal approval.

---

STAGE 1: DRAFT

Assessment: The two ownership modes, explicit loss/no replay, honest memory capabilities and compatibility sequencing form a coherent design. The supervisor placement and the lifecycle model still need explicit treatment.

Major Issues:
[DRAFT-001] HIGH — openspec/changes/add-managed-execution-modes/design.md:33
Validation: REVIEW_REQUIRED. TypeSafe choice=contradicted; confidence=0.18; threshold=0.80.
Description / impact / recommendation: The proposal does not specify whether API launch places the supervisor in the caller process, a dedicated process, or another isolated scheduler. This leaves the advertised supervisor response bound ambiguous when the API caller itself executes non-yielding work. Specify the topology and its scheduling assumptions, then test API caller saturation as well as worker saturation.
Evidence: One supervisor/public endpoint owns one worker process and all sessions inside it.

[DRAFT-002] MEDIUM — openspec/changes/add-managed-execution-modes/specs/execution-management/spec.md:24
Validation: UNVERIFIED. Below API verification severity threshold.
Description / impact / recommendation: The execution-management formal model only contains unconfigured/configured and self-loops; it does not model readiness, generation retirement, lost state or unreaped/closed states, so those central lifecycle contracts cannot be examined through its transition model. Add lifecycle states and guards covering completion/deadline arbitration and confirmed exit.
Evidence: - `unconfigured`
- `configured`

Shape Quality: FAIR


STAGE 2: CORRECTNESS

Issues Found:
[CORR-001] HIGH — openspec/changes/add-managed-execution-modes/specs/security/spec.md:59
Validation: VERIFIED. TypeSafe choice=verified; confidence=0.83; threshold=0.80.
Description / impact / recommendation: The Eval timeout and manual interrupt collision scenario is not scoped to attached mode and requires a zombie and a done/error/timeout terminal without runtime-lost. This conflicts with the managed retirement/runtime-lost contract for a submitted overdue request. Scope the existing scenario to attached mode and add a managed race scenario with runtime-loss and single-terminal semantics.
Evidence: if the deadline transition observes the task live, it classifies the task as a zombie and emits

Correctness Quality: FAIR

Convergence Check
New CRITICAL issues: 0
Total new candidate issues: 1
New issues vs Previous Stage: -50% (1 vs 2)
Estimated false positive rate: unmeasured for unresolved findings; accepted API-verification subset has 0 dropped / 2 verified = 0%.
Status: ESCALATE_TO_HUMAN — four API verdicts are below the required confidence threshold; no overall convergence claim.


STAGE 3: CLARITY

Issues Found:
[CLAR-001] HIGH — openspec/changes/add-managed-execution-modes/design.md:41
Validation: REVIEW_REQUIRED. TypeSafe choice=verified; confidence=0.74; threshold=0.80.
Description / impact / recommendation: Manual interrupt escalation depends on acknowledgement, but acknowledgement is undefined: receipt/cancel-request acceptance versus observed eval termination. Existing interrupt code returns after request_eval_cancel! without observing termination. Accepting a request acknowledgement as sufficient can suppress escalation while native work remains alive. Define acknowledgement as confirmed cessation for the targeted eval identity, and test receipt acknowledged but eval still live.
Evidence: if it is not acknowledged within 100 ms, retire/terminate the runtime

[CLAR-002] MEDIUM — openspec/changes/add-managed-execution-modes/design.md:25
Validation: UNVERIFIED. Below API verification severity threshold.
Description / impact / recommendation: The public surface does not specify a connection/handshake timeout parameter or handshake protocol, despite promising bounded connection/handshake errors and a default five-second connection timeout in the execution-management spec. Specify how the timeout is configured, its covered stages and what identifies a valid legacy or new endpoint.
Evidence: Existing Client(host, port) remains.

Clarity Quality: FAIR

Convergence Check
New CRITICAL issues: 0
Total new candidate issues: 2
New issues vs Previous Stage: +100% (2 vs 1)
Estimated false positive rate: unmeasured for unresolved findings; accepted API-verification subset has 0 dropped / 2 verified = 0%.
Status: ESCALATE_TO_HUMAN — four API verdicts are below the required confidence threshold; no overall convergence claim.


STAGE 4: EDGE CASES

Issues Found:
[EDGE-001] HIGH — openspec/changes/add-managed-execution-modes/design.md:35
Validation: REVIEW_REQUIRED. TypeSafe choice=verified; confidence=0.59; threshold=0.80.
Description / impact / recommendation: Bounded NDJSON limits individual IPC frames, but the proposal leaves outbound buffering limits and slow-client/pipe backpressure policy unspecified while requiring responsive deadlines and ping. Specify bounded queues, asynchronous transport ownership, overflow/disconnect policy and how terminal delivery bounds apply to nonreading clients; test a stalled reader during output and deadline retirement.
Evidence: Private IPC reuses bounded NDJSON on anonymous pipes.

[EDGE-002] HIGH — openspec/changes/add-managed-execution-modes/specs/execution-management/spec.md:114
Validation: VERIFIED. TypeSafe choice=verified; confidence=0.87; threshold=0.80.
Description / impact / recommendation: Disconnect coverage only tests after a request completes. The proposal does not reconcile mid-eval/queued disconnect with inherited BIZ-008 interruption and managed interrupt escalation: a disconnect could either leave work alive or cause runtime-wide loss affecting another connected client. Specify cancellation of queued and submitted work, whether disconnect escalates, and consequences for sibling clients; add both disconnect cases.
Evidence: a client disconnects after completing a request

[EDGE-003] HIGH — openspec/changes/add-managed-execution-modes/specs/mcp-adapter/spec.md:45
Validation: REVIEW_REQUIRED. TypeSafe choice=verified; confidence=0.79; threshold=0.80.
Description / impact / recommendation: Lifecycle cleanup covers explicit close, CLI stop and MCP EOF but does not define abrupt supervisor/owner death. The no-unowned-worker expectation therefore lacks a crash-path contract. Define worker behavior on control-pipe EOF/owner death and platform containment/limits, and test forced owner death without relying on graceful close.
Evidence: it closes its owned runtime and does not leave an unowned worker

Edge Case Coverage: FAIR

Convergence Check
New CRITICAL issues: 0
Total new candidate issues: 3
New issues vs Previous Stage: +50% (3 vs 2)
Estimated false positive rate: unmeasured for unresolved findings; accepted API-verification subset has 0 dropped / 2 verified = 0%.
Status: ESCALATE_TO_HUMAN — four API verdicts are below the required confidence threshold; no overall convergence claim.


STAGE 5: EXCELLENCE

Final Polish Issues:
No additional distinct findings. Rechecked each citation, searched all seven draft files for policies described as absent, and compared cancellation/disconnect behavior with the existing code and canonical security spec. Authoring findings are already recorded by the draft; missing future runtime tests are not treated as a new implementation bug.

Excellence Assessment:
- Structure: FAIR
- Correctness: FAIR
- Clarity: FAIR
- Edge Cases: FAIR
- Overall: FAIR

Production Ready: NO — this is an unimplemented proposal with unresolved contract findings, not a release candidate.
