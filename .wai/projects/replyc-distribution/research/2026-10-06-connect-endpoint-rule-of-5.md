# Checked endpoint discovery — Rule-of-5 review

Scope: REPLy_jl-q8dz.1 and REPLy_jl-q8dz.2; approved add-managed-execution-modes tasks 1–2. Review was self-performed. No CRITICAL/HIGH findings require TypeSafe verification; MEDIUM/LOW findings below that threshold are UNVERIFIED by TypeSafe and self-checked against code/tests.

## Draft

The additive Client/JSONTransport path preserves ordinary constructors and isolates checked discovery. Approval/successor synchronization and completed timeout adoption are separate from runtime ownership implementation. Existing contract mappings were promoted rather than replaced with placeholder tests.

## Correctness

- CORR-001 (MEDIUM, resolved, self-checked): asynchronous connect initiation alone is insufficient for a completed connection. The final implementation uses Sockets.connect on the allocated socket, which waits for connection establishment and allows the outer budget to close it.
- CORR-002 (MEDIUM, resolved, self-checked): a task completed after its deadline could be accepted by timedwait when polling resumes. Successful discovery now checks the same monotonic budget before returning.
- Failed discovery closes its socket; a late DNS result checks expiry before connecting. Response ids, done status, operation/version objects, encoding and capability types are validated.

## Clarity

- CLAR-001 (LOW, resolved, self-checked): describe now advertises attached/cooperative/unsupported controls and a zero effective memory cap. A valid legacy endpoint reports unknown guarantees. Source headers, API map and a standalone connection guide describe the chosen ownership contract.
- CLAR-002 (LOW, resolved, self-checked): the older Client task incorrectly said length-prefixed framing. It now requires existing NDJSON and documents application order with this change, MCP refactoring and CLI installer documentation.

## Edge cases

Regression coverage includes TCP/Unix endpoints, missing endpoints, host-created Main sessions, default namespace isolation, late DNS completion without socket resurrection, one shared DNS/discovery budget, silent peers, malformed JSON, wrong ids, invalid statuses, done-only responses, invalid capabilities, EOF and invalid timeout values. Real server cold compilation uses an explicit 30-second discovery budget; the shared budget measurements warm the relevant specialization before measuring. Closing the application remains explicit.

## Excellence

The final changes reuse existing transport and discovery operations. No new dependency, wire framing, automatic launch, namespace selection or recovery behavior was introduced. The supervisor/worker, managed memory controls, CLI launch and MCP backend selection remain future slices. Full-suite and smoke outcomes belong in the session handoff.

Convergence: no new CRITICAL/HIGH findings after fixes; no remaining actionable findings in this slice. False-positive estimates are unmeasured. Verdict: suitable to commit after required checks pass; this is not a completed managed-runtime implementation.

## Final gate evidence and remaining work

Focused final helper verification: 50 discovery assertions pass; earlier describe 187/187 and lifecycle 151/151. Smoke passed; canonical ah check zero structural findings; spk lint 34/0; strict OpenSpec passed; Vale and typos passed. The managed overlay now has 58 structural findings (38 no-toml, 20 conflicts) after four executable connect contracts and timeout adoption.

Pretender initially found three new-source functions above metrics. Construction was simplified into focused validation/discovery/wait and fake-peer helpers; explicit --mode gate now exits 0 with no metric violations. Default tiered mode still exits 1 with identical source, tracked under om43; configuration and hooks are unchanged. Source commit is pending this gate resolution and full-suite verification.

Two full suite runs each passed 4562 assertions, zero assertion failures and one consumer setup error. The isolated consumer test uses setenv, dropping the writable depot and offline settings; Pkg.develop then tries the read-only home registry. REPLy_jl-q8dz.3 tracks the proposed addenv fix. The repository stop-after-two-attempts rule requires user input before fixing/retrying. No failing assertions were removed or skipped, and q8dz.2 remains in progress. Managed implementation remains unstarted; approval persists and need not be requested again.

## Resume verification — blockers resolved

Maintainer authorized the consumer fix and retry. Both setenv calls changed to addenv in 17ef104; isolated consumer/CLI tests pass 21/21, full just test passes 4566/4566 with zero failures/errors, and smoke passes. Pretender mode now matches the documented hard gate (58571b5): actual staged source and an isolated docs-only fixture exit 0; a violating Julia fixture exits 1 with four violations. All configured hooks pass without exemptions. Five-pass self-review of these fixes found no new findings. Tasks 2.1/2.2 are complete; managed supervisor/worker implementation remains pending.
