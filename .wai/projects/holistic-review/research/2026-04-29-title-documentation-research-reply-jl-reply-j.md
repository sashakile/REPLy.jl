---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

#+title: Documentation Research: REPLy.jl (REPLy_jl-umg.2)
#+date: 2026-04-29

* 1. Executive Summary & Core Assertion

*Core Assertion:* REPLy.jl exposes a Julia REPL-like evaluation service over a socket protocol so editors, tools, and MCP clients can execute code and manage sessions programmatically.

*Status:* The documentation set is structurally usable and all in-scope links resolve except for one external redirect, but the docs architecture has two mixed-intent pages and one major stale surface: =docs/src/status.md= substantially understates the currently implemented feature set.

Primary audience appears split:
- Users integrating a client or editor with REPLy
- Contributors validating protocol / implementation surface

* 2. Diátaxis Matrix

| Quadrant | Existing Topics | Proposed / Missing Topics |
|-
| Tutorial | =docs/src/tutorial-custom-client.md= | Getting started with named sessions end-to-end; MCP quickstart with a real transport |
| How-to | =docs/src/howto-sessions.md=; =docs/src/howto-mcp-adapter.md=; =docs/src/howto-unix-sockets.md= | How to use =describe= for capability discovery; how to use =load-file= safely; how to interrupt or time-box evals |
| Reference | =docs/src/reference-protocol.md=; =docs/src/api.md= | Reference sections for =describe=, =load-file=, =interrupt=, =complete=, =lookup=, =stdin=, multi-listener server entrypoints, resource-limit knobs, audit-log API |
| Explanation | =docs/src/status.md= | Architecture / capability-map page explaining transports, middleware stack, and session model |

* 3. Snowflake Structural Map

- *Macro-Journey:* install REPLy -> run a first eval over TCP -> choose ephemeral vs named sessions -> choose transport (TCP or Unix socket) -> choose integration mode (custom client or MCP adapter) -> consult protocol/API/status reference for exact semantics.
- *Key Components:*
  - =REPLy.serve= / =REPLy.serve_multi=
  - newline-delimited JSON protocol
  - ephemeral and named sessions
  - session lifecycle ops (=new-session=, =ls-sessions=, =close=, =clone=)
  - middleware-backed ops (=describe=, =eval=, =load-file=, =interrupt=, =complete=, =lookup=, =stdin=)
  - MCP adapter helpers
  - resource limits and audit logging

* 4. EPPO & Cognitive Audit

** Frankenbooks Found
- =README.md=
  - Mixes explanation, installation, quickstart tutorial, and contributor workflow.
- =docs/src/index.md=
  - Mixes landing-page explanation, installation, quickstart tutorial, operational notes, and resource-limit reference.
- =docs/src/status.md=
  - Mixes explanation (spec vs implementation status), reference (capability matrices), and coverage inventory.

** EPPO Status
- =README.md= :: Pass, but mixed intent.
- =docs/src/index.md= :: Pass, but mixed intent.
- =docs/src/api.md= :: Borderline pass; self-contained only if the generated autodocs are present. Minimal orienting context.
- =docs/src/howto-mcp-adapter.md= :: Pass.
- =docs/src/howto-sessions.md= :: Pass.
- =docs/src/howto-unix-sockets.md= :: Pass.
- =docs/src/reference-protocol.md= :: Partial pass; internally coherent, but incomplete relative to implemented protocol surface while calling itself the complete reference.
- =docs/src/status.md= :: Fail for freshness / trustworthiness; orientation is clear, but substantive claims are stale.
- =docs/src/tutorial-custom-client.md= :: Pass.

** Cognitive Load Notes
- No severe wall-of-words problem in the task-oriented docs.
- =status.md= is long but well-labeled.
- =api.md= is extremely sparse; it depends on generated content rather than page-level framing.

* 5. Link and Anchor Verification

Scope checked:
- =README.md=
- =docs/src/index.md=
- =docs/src/api.md=
- =docs/src/howto-mcp-adapter.md=
- =docs/src/howto-sessions.md=
- =docs/src/howto-unix-sockets.md=
- =docs/src/reference-protocol.md=
- =docs/src/status.md=
- =docs/src/tutorial-custom-client.md=

Automated results for the in-scope pages:
- 37 link occurrences across the scoped docs pages
- 0 broken links
- 0 missing anchors
- 1 redirect worth noting

Redirects worth updating:
- =docs/src/howto-mcp-adapter.md=, heading "How-to: Use the MCP Adapter"
  - Link text: =Model Context Protocol (MCP)=
  - Current URL: =https://modelcontextprotocol.io/=
  - Redirect target: =https://modelcontextprotocol.io/docs/getting-started/intro=
  - Impact: low; resolves successfully, but canonical target appears to have moved.

Contextual link-check notes:
- Relative links among the docs pages are semantically appropriate.
- GitHub spec links in =docs/src/status.md= resolve and match the surrounding text.
- No suspect anchor text in the scoped set.

* 6. Initial Docs Surface vs Code Surface Mismatch List

** Major mismatch: =docs/src/status.md= is stale
The page says the current implementation covers only a small subset of the specified surface and marks several capabilities as unimplemented. That no longer matches the repo.

Examples:
- Heading: =Capability Status Matrix=
  - Claims *Additional core operations* are not implemented.
  - Repo evidence shows implemented middleware and tests for =describe=, =load-file=, =interrupt=, =complete=, =lookup=, and =stdin=:
    - =src/middleware/describe.jl=
    - =src/middleware/load_file.jl=
    - =src/middleware/interrupt.jl=
    - =src/middleware/complete.jl=
    - =src/middleware/lookup.jl=
    - =src/middleware/stdin.jl=
    - tests: =test/unit/describe_middleware_test.jl=, =test/unit/load_file_middleware_test.jl=, =test/unit/interrupt_middleware_test.jl=, =test/unit/complete_middleware_test.jl=, =test/unit/lookup_middleware_test.jl=, =test/unit/stdin_middleware_test.jl=
- Heading: =Capability Status Matrix=
  - Claims *Session management* lacks named sessions and lifecycle ops.
  - Repo evidence:
    - =src/middleware/session_ops.jl=
    - =test/unit/session_ops_middleware_test.jl=
    - =test/integration/session_ops_test.jl=
    - =test/e2e/named_session_eval_test.jl=
- Heading: =Capability Status Matrix=
  - Claims *Unix socket and multi-listener transport* are not implemented.
  - Repo evidence:
    - =serve(...; socket_path=...)= and =serve_multi(...)= in =src/server.jl=
    - tests: =test/e2e/unix_socket_test.jl= and =test/e2e/multi_listener_test.jl=
- Heading: =Capability Status Matrix=
  - Claims *Security and resource limits* are not implemented.
  - Repo evidence:
    - =src/config/resource_limits.jl=
    - =src/security/audit.jl=
    - tests: =test/unit/resource_limits_test.jl=, =test/unit/resource_enforcement_test.jl=, =test/unit/audit_log_test.jl=
- Heading: =Capability Status Matrix=
  - Claims *MCP adapter* is not started.
  - Repo evidence:
    - =src/mcp_adapter.jl=
    - =test/unit/mcp_adapter_test.jl=
    - user-facing doc already exists at =docs/src/howto-mcp-adapter.md=

This is the highest-severity documentation trust issue in scope.

** Coverage gap: protocol reference calls itself complete but omits implemented operations
- Page: =docs/src/reference-protocol.md=
- Headings affected: =Session Operations= and the page-level opening sentence.
- Problem: the page says it is "the complete reference for the request/response contract" but it only details =eval=, error shape, status flags, and session ops. It does not document implemented ops such as:
  - =describe=
  - =load-file=
  - =interrupt=
  - =complete=
  - =lookup=
  - =stdin=
- Repo evidence:
  - middleware files under =src/middleware/=
  - corresponding unit tests listed above

This is a scope/completeness mismatch, not a broken-link problem.

** Coverage gap: API surface exceeds narrative docs
User-visible or integrator-visible exported APIs are present but not surfaced outside autodocs or not cross-linked from task docs:
- =serve_multi= / =MultiListenerServer= / =server_socket_path=
- audit log API (=AuditLog=, =record_audit!=)
- resource-limit type (=ResourceLimits=)
- session inspection helpers (=session_state=, =session_eval_task=, etc.)
- middleware descriptor / validation API (=MiddlewareDescriptor=, =validate_stack=)

Repo evidence:
- exports in =src/REPLy.jl=
- implementation in =src/server.jl=, =src/security/audit.jl=, =src/config/resource_limits.jl=

This is not necessarily wrong for v1 docs, but it is a concrete surface-gap inventory.

* 7. AI-Readiness Assessment

- [ ] =llms.txt= present
- [x] Explicit semantic page labeling by title / file naming
- [x] MCP-oriented content identified
- [ ] Strong page-level capability index for RAG / retrieval
- [ ] One authoritative reference page for all implemented operations

Notes:
- The page names are semantically useful.
- =status.md= is risky for retrieval because its stale claims can mislead downstream agents.

* 8. Recommended Next Steps

1. Treat =docs/src/status.md= as the highest-priority docs-freshness fix; it currently undermines trust in the rest of the docs.
2. Expand or split =docs/src/reference-protocol.md= so the "complete reference" claim matches the implemented operation surface.
3. Decide whether =README.md= and =docs/src/index.md= should remain mixed landing pages or be slimmed so task docs carry the operational detail.
4. Add an explanation/reference page for multi-listener transport, resource limits, and audit logging if those are intended public surfaces.
5. Update the MCP homepage URL in =docs/src/howto-mcp-adapter.md= to the redirect target when doing the docs cleanup pass.
