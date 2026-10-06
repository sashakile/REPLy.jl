# Managed execution proposal — Rule-of-5 revisions

The eight findings in the October 6 review are addressed in the design proposal. This revision does not approve or implement managed execution. REPLy_jl-24xd tracks these document changes; nv28/q8dz and the release gate retain their approval dependencies.

## Resolutions

| Finding | Revised decision | Evidence | Review status |
|---|---|---|---|
| DRAFT-001 | Supervisor topology is explicit: the API caller and worker cannot suppress its scheduling by blocking their own Julia tasks. | openspec/changes/add-managed-execution-modes/design.md:54 | VERIFIED |
| DRAFT-002 | The lifecycle model now represents readiness, queued/submitted work, cancellation arbitration, retirement, unreaped cleanup, external owner loss and confirmed exit, with guarded transitions. | openspec/changes/add-managed-execution-modes/specs/execution-management/spec.md:63 | UNVERIFIED (medium; self-checked) |
| CORR-001 | The original timeout/interrupt collision scenario is scoped to attached execution, and a separate managed race specifies runtime-lost and atomic single-terminal outcomes. | openspec/changes/add-managed-execution-modes/specs/security/spec.md:60 | VERIFIED |
| CLAR-001 | Cancellation receipt/scheduling is distinguished from confirmed identity-matched cessation; grace expires at 100 ms without confirmed cessation and shares terminal arbitration with completion/deadline. | openspec/changes/add-managed-execution-modes/design.md:68 | VERIFIED |
| CLAR-002 | Opt-in connect_endpoint has an explicit timeout API and one DNS/connect/describe budget, validates protocol fields and matching terminal, and classifies valid legacy capabilities unknown while preserving existing Client constructors. | openspec/changes/add-managed-execution-modes/design.md:42 | UNVERIFIED (medium; self-checked) |
| EDGE-001 | Transport frame and queue ceilings, nonblocking control ownership, partial-write retirement, slow-reader closure and the limitation of delivery bounds to reading local peers are explicit and have future regression shapes. | openspec/changes/add-managed-execution-modes/design.md:60 | VERIFIED |
| EDGE-002 | Disconnect specifies connection-scoped queue cancellation, submitted cancellation and escalation after 100 ms, discarded terminal behavior, sibling state loss and inherited cooperative attached behavior; regression shapes cover duplicate ids across clients. | openspec/changes/add-managed-execution-modes/design.md:76 | VERIFIED |
| EDGE-003 | Owner EOF and abrupt supervisor death have explicit direct-worker cleanup contracts, scheduler-independent OS-backed setup and startup race checks, unsupported-platform rejection, descendant capability limits and forced-death test shapes. | openspec/changes/add-managed-execution-modes/design.md:78 | VERIFIED |

The six original high findings now have TypeSafe-supported resolution claims above the 0.80 gate (0.91–0.99 confidence). The two medium findings remain UNVERIFIED under the skill's severity policy; their changes were self-checked. Supplemental TypeSafe answers also support those changes, but they are not counted as verified findings under that policy. Evidence here verifies the written decisions, not runtime performance or cleanup.

## Five-pass re-review

1. Draft: dedicated supervisor topology, API ownership and Linux-first owner-death support are explicit; the runtime model now contains 13 states and guarded paths for readiness, request arbitration, retirement, cleanup and external supervisor loss.
2. Correctness: attached races are scoped; managed races use atomic terminal arbitration and runtime-lost. Partial IPC submission counts as submitted work. Closed-peer terminals are selected once and discarded.
3. Clarity: connect_endpoint has an opt-in shared timeout/describe contract; cancellation acknowledgement means matching observed cessation; old constructors preserve compatibility.
4. Edge cases: stalled readers have numeric queue bounds and closure behavior; duplicate request ids are scoped by connection; mid-request disconnect may lose siblings; owner EOF, supervisor death and startup races have test shapes. Descendant cleanup is separately advertised, not implied by direct-worker parent-death delivery.
5. Excellence: mirrored Requirements were rebuilt and checked by the spec linter. All eight findings map to future red/green implementation test slices. No placeholder contract or runtime implementation was added.

No additional unresolved review findings remain in this revision. The proposal is ready for maintainer design review; the separate approval gate and implementation correspondence backlog remain.

## Validation ledger

Changed — proposal.md, design.md, tasks.md and execution-management/security/MCP deltas. The resource-limits delta is unchanged but validated with the set. Historical review preserved.
Verified — strict OpenSpec validation passes. spk lint: 4 specs, 0 issues. spk graph: 91 nodes, 0 dangling references, 0 typing violations, 0 supersedes cycles. Canonical ah check: 0 findings; runtime contract tests skipped. Overlay ah check: 62 structural findings (44 no-toml, 18 overlay-conflict), 0 runtime tests run. These findings are recorded in tasks.md for implementation; no tests were weakened or hidden.
Review — self-review in five passes, mechanical citation checks and one TypeSafe resolution batch. Linux parent-death behavior checked against https://man7.org/linux/man-pages/man2/PR_SET_PDEATHSIG.2const.html; process-tree containment checked against https://docs.kernel.org/admin-guide/cgroup-v2.html. Runtime source was not changed.
Risks — initial managed support targets Linux; submitted-work disconnect can retire a shared runtime; stalled clients cannot be guaranteed terminal delivery. These are explicit pending approval decisions. OS-backed controls remain unimplemented and untested.
Next — maintainer reviews the revised approval scope. After approval, synchronize nv28/q8dz/xbb9/xbb9.1 and create/claim the TDD slices; reconcile overlay identities and provide executable contracts during implementation.

Commit gate note — newline findings were corrected. Pretender 0.7.0 check --staged (including --mode gate) returned ok:true/files:[] but exited 1 for the Markdown/JSONL-only staged set. No Julia files are staged. Tool failure tracked as REPLy_jl-om43; the documentation commit excludes only that inapplicable Pretender hook, retains its configuration, and runs the remaining hooks. No runtime tests or complexity findings were suppressed for changed code.
